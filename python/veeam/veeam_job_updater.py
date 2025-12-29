#!/usr/bin/env python3
"""
依赖: requests, pyyaml
用法: python3 python/veeam_job_updater.py --config docs/fixtures/veeam_job_updates.example.yaml

环境变量(全部采用 VEEAM_ 前缀):
  VEEAM_SERVER        Veeam Backup & Replication 服务器地址(必填)
  VEEAM_PORT          端口, 默认为 9419
  VEEAM_USERNAME      登录用户名(必填)
  VEEAM_PASSWORD      登录密码(必填)
  VEEAM_VERIFY_SSL    校验证书, "true"/"false", 默认为 true

脚本目标: 从 YAML 批量读取 Job 配置, 通过 VBR REST API 更新保留策略与合成全备计划, 为后续扩展奠定基础。
"""

from __future__ import annotations

import argparse
import dataclasses
import logging
import os
import sys
from typing import Dict, List, Optional

import requests
import yaml


@dataclasses.dataclass
class RetentionPolicy:
    """简单保留策略描述."""

    mode: str  # days|restore_points
    value: int

    @classmethod
    def from_dict(cls, data: Dict) -> "RetentionPolicy":
        mode = data.get("type")
        value = int(data.get("value", 0))
        if mode not in {"days", "restore_points"}:
            raise ValueError("retention_policy.type 仅支持 days 或 restore_points")
        if value <= 0:
            raise ValueError("retention_policy.value 必须大于 0")
        return cls(mode=mode, value=value)

    def to_api_payload(self) -> Dict:
        """生成 VBR REST 兼容的 SimpleRetentionPolicy 字段."""

        if self.mode == "days":
            return {
                "RetainLimitType": "Days",
                "RetainDaysToKeep": self.value,
                "RetainCycles": None,
            }
        return {
            "RetainLimitType": "Cycles",
            "RetainCycles": self.value,
            "RetainDaysToKeep": None,
        }


@dataclasses.dataclass
class SyntheticFullPlan:
    """合成全备计划."""

    enabled: bool
    days_of_week: Optional[List[str]] = None

    @classmethod
    def from_dict(cls, data: Dict) -> "SyntheticFullPlan":
        enabled = bool(data.get("enabled", False))
        days = data.get("days_of_week")
        if days is not None:
            days = [d.capitalize() for d in days]
        return cls(enabled=enabled, days_of_week=days)

    def to_api_payload(self) -> Dict:
        """返回 BackupTargetOptions 相关字段."""

        return {
            "TransformFullToSyntethic": self.enabled,
            "TransformToSyntethicDays": self.days_of_week or [],
        }


@dataclasses.dataclass
class JobPatch:
    name: str
    retention: Optional[RetentionPolicy] = None
    synthetic_full: Optional[SyntheticFullPlan] = None

    @classmethod
    def from_dict(cls, data: Dict) -> "JobPatch":
        name = data.get("name")
        if not name:
            raise ValueError("每个 job 需要 name")
        retention = None
        if data.get("retention_policy"):
            retention = RetentionPolicy.from_dict(data["retention_policy"])
        synthetic = None
        if data.get("synthetic_full"):
            synthetic = SyntheticFullPlan.from_dict(data["synthetic_full"])
        return cls(name=name, retention=retention, synthetic_full=synthetic)


class VeeamRestClient:
    """与 VBR REST API 交互的轻量客户端."""

    def __init__(
        self,
        server: str,
        username: str,
        password: str,
        port: int = 9419,
        verify_ssl: bool = True,
    ) -> None:
        self.base_url = f"https://{server}:{port}/api"
        self.username = username
        self.password = password
        self.session = requests.Session()
        self.session.verify = verify_ssl
        self._token: Optional[str] = None

    def authenticate(self) -> None:
        """获取 access token 并写入会话头."""

        url = f"{self.base_url}/oauth2/token"
        payload = {
            "grant_type": "password",
            "username": self.username,
            "password": self.password,
        }
        resp = self.session.post(url, data=payload, headers={"Accept": "application/json"})
        resp.raise_for_status()
        token = resp.json().get("access_token")
        if not token:
            raise RuntimeError("未从鉴权响应中找到 access_token")
        self._token = token
        self.session.headers.update({"Authorization": f"Bearer {token}"})

    def find_job(self, name: str) -> Optional[Dict]:
        """按名称查询 Job 信息, 返回原始 JSON."""

        url = f"{self.base_url}/v1/jobs"
        resp = self.session.get(url, params={"name": name})
        resp.raise_for_status()
        items = resp.json().get("data") or resp.json()
        if isinstance(items, dict) and items.get("name") == name:
            return items
        if isinstance(items, list):
            for job in items:
                if job.get("name") == name:
                    return job
        return None

    def patch_job(self, job_id: str, payload: Dict) -> None:
        """调用 REST 接口更新 Job 部分字段."""

        url = f"{self.base_url}/v1/jobs/{job_id}"
        # VBR 11/12 在编辑 Job 时需要 action=edit 参数
        resp = self.session.put(url, params={"action": "edit"}, json=payload)
        resp.raise_for_status()


class JobUpdater:
    """核心调度器, 将 YAML 配置映射到 VBR API."""

    def __init__(self, client: VeeamRestClient, dry_run: bool = False) -> None:
        self.client = client
        self.dry_run = dry_run

    def apply_patch(self, patch: JobPatch) -> None:
        job = self.client.find_job(patch.name)
        if not job:
            logging.error("未找到名为 %s 的 Job", patch.name)
            return

        job_id = job.get("id") or job.get("Uid") or job.get("jobId")
        if not job_id:
            logging.error("Job %s 未返回 id 字段, 无法更新", patch.name)
            return

        payload: Dict[str, Dict] = {}
        if patch.retention:
            payload.setdefault("SimpleRetentionPolicy", {}).update(
                patch.retention.to_api_payload()
            )
        if patch.synthetic_full:
            payload.setdefault("BackupTargetOptions", {}).update(
                patch.synthetic_full.to_api_payload()
            )

        if not payload:
            logging.info("Job %s 未提供可更新字段, 跳过", patch.name)
            return

        if self.dry_run:
            logging.info("[dry-run] Job %s 将提交 payload: %s", patch.name, payload)
            return

        logging.info("正在更新 Job %s (id=%s)", patch.name, job_id)
        self.client.patch_job(job_id, payload)
        logging.info("Job %s 更新完成", patch.name)


def load_patches(config_path: str) -> List[JobPatch]:
    with open(config_path, "r", encoding="utf-8") as f:
        raw = yaml.safe_load(f)
    jobs = raw.get("jobs") if isinstance(raw, dict) else None
    if not jobs:
        raise ValueError("配置文件缺少 jobs 列表")
    return [JobPatch.from_dict(item) for item in jobs]


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="批量更新 Veeam Job 属性")
    parser.add_argument(
        "--config", required=True, help="YAML 配置文件路径"
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="仅打印将要提交的 payload, 不调用 API"
    )
    parser.add_argument(
        "--log-level", default="INFO", help="日志级别, 默认 INFO"
    )
    return parser.parse_args(argv)


def build_client_from_env() -> VeeamRestClient:
    server = os.getenv("VEEAM_SERVER")
    username = os.getenv("VEEAM_USERNAME")
    password = os.getenv("VEEAM_PASSWORD")
    port = int(os.getenv("VEEAM_PORT", "9419"))
    verify_ssl = os.getenv("VEEAM_VERIFY_SSL", "true").lower() == "true"

    missing = [k for k, v in {
        "VEEAM_SERVER": server,
        "VEEAM_USERNAME": username,
        "VEEAM_PASSWORD": password,
    }.items() if not v]
    if missing:
        raise EnvironmentError(f"缺少环境变量: {', '.join(missing)}")

    return VeeamRestClient(server, username, password, port=port, verify_ssl=verify_ssl)


def main(argv: Optional[List[str]] = None) -> None:
    args = parse_args(argv or sys.argv[1:])
    logging.basicConfig(
        level=args.log_level.upper(),
        format="%(asctime)s %(levelname)s %(message)s",
    )

    patches = load_patches(args.config)
    client = build_client_from_env()

    if not args.dry_run:
        client.authenticate()

    updater = JobUpdater(client, dry_run=args.dry_run)
    for patch in patches:
        updater.apply_patch(patch)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        logging.error("执行失败: %s", exc)
        sys.exit(1)
