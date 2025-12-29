#!/usr/bin/env python3
"""
依赖: requests
用法: python3 python/veeam_job_exporter.py --output veeam_jobs.csv

环境变量(全部采用 VEEAM_ 前缀):
  VEEAM_SERVER        Veeam Backup & Replication 服务器地址(必填)
  VEEAM_PORT          端口, 默认为 9419
  VEEAM_USERNAME      登录用户名(必填)
  VEEAM_PASSWORD      登录密码(必填)
  VEEAM_VERIFY_SSL    校验证书, "true"/"false", 默认为 true

脚本目标: 通过 VBR REST API 拉取全部 Job 列表并导出为 CSV，便于审计或批量变更前备份清单。
"""

from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from pathlib import Path
from typing import Dict, List, Optional

import requests


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
        """函数: authenticate
        说明: 使用密码模式获取 access token 并写入请求头，符合 VBR 1.2-rev1+ 要求。
        参数: 无
        返回: None，如失败抛出带错误信息的异常
        """

        url = f"{self.base_url}/oauth2/token"
        api_version = os.getenv("VEEAM_API_VERSION", "1.2-rev1")
        payload = {
            "grant_type": "password",
            "username": self.username,
            "password": self.password,
        }
        headers = {
            "accept": "application/json",
            "x-api-version": api_version,
            "Content-Type": "application/x-www-form-urlencoded",
        }
        resp = self.session.post(url, data=payload, headers=headers)

        if resp.status_code != 200:
            msg = resp.text
            try:
                msg_json = resp.json()
                msg = msg_json.get("message") or msg
            except Exception:  # noqa: BLE001
                pass
            raise RuntimeError(f"鉴权失败 HTTP {resp.status_code}: {msg}")

        token = resp.json().get("access_token")
        if not token:
            raise RuntimeError("未从鉴权响应中找到 access_token")
        self._token = token
        self.session.headers.update({"Authorization": f"Bearer {token}", "x-api-version": api_version})

    def list_jobs_flat(self, limit: Optional[int] = None) -> List[Dict]:
        """函数: list_jobs_flat
        说明: 按单页 limit 直接取，服务端若支持大 limit（如 500/1000）可一次拉全。
        参数: limit 返回条数上限
        返回: Job 字典列表
        """

        url = f"{self.base_url}/v1/jobs"
        params = {"limit": limit} if limit else None
        resp = self.session.get(url, params=params)
        resp.raise_for_status()
        data = resp.json().get("data") or resp.json()
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict) and item]
        if isinstance(data, dict):
            return [data]
        return []

    def list_extra_collection(self, endpoint: str, limit: Optional[int]) -> List[Dict]:
        """拉取其他作业集合(复制/复制作业/NAS等), endpoint 形如 backupCopyJobs。"""

        url = f"{self.base_url}/v1/{endpoint}"
        params = {"limit": limit} if limit else None
        resp = self.session.get(url, params=params)
        if resp.status_code == 404:
            return []
        resp.raise_for_status()
        data = resp.json().get("data") or resp.json()
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict) and item]
        if isinstance(data, dict):
            return [data]
        return []


DEFAULT_FIELDS = ["id", "name", "type", "platform", "state", "description"]


def extract_field(job: Dict, field: str) -> str:
    """将字段名映射到 Job 字典，缺失则返回空字符串。"""

    if field == "id":
        return str(job.get("id") or job.get("Uid") or job.get("jobId") or "")
    value = job.get(field)
    if value is None:
        return ""
    return str(value)


def write_csv(jobs: List[Dict], fields: List[str], output: str) -> None:
    """函数: write_csv
    说明: 将 Job 列表按指定字段写入 CSV 文件。
    参数: jobs(Job 列表), fields(字段列表), output(输出文件路径)
    返回: None
    """

    with open(output, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for job in jobs:
            writer.writerow({field: extract_field(job, field) for field in fields})


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="导出 Veeam Job 清单为 CSV")
    parser.add_argument(
        "--output",
        default=None,
        help="输出 CSV 文件路径；未指定时写入脚本目录下的 veeam_jobs.csv",
    )
    parser.add_argument(
        "--fields",
        default=",".join(DEFAULT_FIELDS),
        help="以逗号分隔的字段列表, 默认: id,name,type,platform,state,description",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="API 返回的 Job 数量上限, 例如 500; 默认读取环境变量 VEEAM_JOB_LIMIT 或由服务器决定",
    )
    parser.add_argument(
        "--page-size",
        type=int,
        default=None,
        help="单次请求的条数，默认 min(limit,1000) 或服务器默认，最大 1000；可用环境变量 VEEAM_JOB_PAGE_SIZE 设置",
    )
    parser.add_argument(
        "--include-extra",
        action="store_true",
        help="同时抓取 backupCopyJobs/replicationJobs/fileShareBackupJobs 等附加集合",
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


def load_dotenv_from_script_dir() -> None:
    """函数: load_dotenv_from_script_dir
    说明: 从脚本同级目录加载 .env（key=value），未覆盖已存在的环境变量。
    参数: 无
    返回: None
    """

    env_path = Path(__file__).resolve().parent / ".env"
    if not env_path.exists():
        return

    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if (value.startswith("\"") and value.endswith("\"")) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        os.environ.setdefault(key, value)


def main(argv: Optional[List[str]] = None) -> None:
    args = parse_args(argv or sys.argv[1:])
    logging.basicConfig(
        level=args.log_level.upper(), format="%(asctime)s %(levelname)s %(message)s"
    )

    load_dotenv_from_script_dir()

    fields = [f.strip() for f in args.fields.split(",") if f.strip()]
    if not fields:
        raise ValueError("字段列表不能为空")

    script_dir = Path(__file__).resolve().parent
    if args.output:
        output_path = Path(args.output)
        if not output_path.is_absolute() and not output_path.parent.parts:
            # 仅提供文件名时，写到脚本目录
            output_path = script_dir / output_path
    else:
        output_path = script_dir / "veeam_jobs.csv"

    client = build_client_from_env()
    client.authenticate()
    env_limit = os.getenv("VEEAM_JOB_LIMIT")
    env_page = os.getenv("VEEAM_JOB_PAGE_SIZE")

    limit_val = args.limit
    if limit_val is None and env_limit:
        try:
            limit_val = int(env_limit)
        except ValueError:
            raise ValueError("环境变量 VEEAM_JOB_LIMIT 必须是整数")

    page_size_val = args.page_size
    if page_size_val is None and env_page:
        try:
            page_size_val = int(env_page)
        except ValueError:
            raise ValueError("环境变量 VEEAM_JOB_PAGE_SIZE 必须是整数")

    # 主集合：jobs（一次大 limit 获取）
    jobs = client.list_jobs_flat(limit=limit_val)

    # 附加集合（可选）
    if args.include_extra:
        extra_endpoints = [
            "backupCopyJobs",
            "replicationJobs",
            "fileShareBackupJobs",
        ]
        for ep in extra_endpoints:
            jobs.extend(client.list_extra_collection(ep, limit_val))

    logging.info(
        "获取到 %d 个 Job (limit=%s), 正在写入 %s",
        len(jobs),
        limit_val if limit_val is not None else "server-default",
        output_path,
    )
    write_csv(jobs, fields, output_path)
    logging.info("写入完成")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        logging.error("执行失败: %s", exc)
        sys.exit(1)
