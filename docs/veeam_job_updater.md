# veeam_job_updater 使用说明

本文档说明如何利用 `python/veeam_job_updater.py` 通过 Veeam Backup & Replication (VBR) REST API 批量更新作业保留策略与合成全备计划。

## 适用场景
- 批量统一 Job 的保留天数或还原点数。
- 调整是否启用合成全备及其执行星期，避免在界面逐个修改。
- 需要“干跑(dry-run)”先审阅即将提交的 payload。

## 前置依赖
- Python 3.8+。
- 依赖库：`requests`、`pyyaml`。
  ```bash
  pip install requests pyyaml
  ```
- 环境变量（均以 `VEEAM_` 前缀）：
  - `VEEAM_SERVER`：VBR 服务器地址（必填）。
  - `VEEAM_PORT`：REST 端口，默认 9419。
  - `VEEAM_USERNAME` / `VEEAM_PASSWORD`：账号与密码（必填）。
  - `VEEAM_VERIFY_SSL`：是否校验证书，`true`/`false`，默认 `true`。

> 权限提示：账号至少需要对目标 Job 拥有编辑权限；建议使用专用最小权限账户。

## 配置文件格式
示例位于 `docs/fixtures/veeam_job_updates.example.yaml`：
```yaml
jobs:
  - name: "每日文件备份"
    retention_policy:
      type: "days"              # 可选: days / restore_points
      value: 14                  # days 对应保留天数，restore_points 对应还原点数量
    synthetic_full:
      enabled: true
      days_of_week: ["Saturday"]

  - name: "数据库周末备份"
    retention_policy:
      type: "restore_points"
      value: 30
    synthetic_full:
      enabled: false
```
- `type: days` 生成 `RetainLimitType=Days`；`restore_points` 生成 `RetainLimitType=Cycles`。
- `days_of_week` 不填时仅切换开关，不调整星期。

## 运行示例
1. 先做干跑确认 payload：
   ```bash
   VEEAM_SERVER=10.0.0.8 \
   VEEAM_USERNAME=svc_veeam \
   VEEAM_PASSWORD='***' \
   python3 python/veeam_job_updater.py --config docs/fixtures/veeam_job_updates.example.yaml --dry-run
   ```
2. 确认无误后执行实际更新：
   ```bash
   python3 python/veeam_job_updater.py --config docs/fixtures/veeam_job_updates.example.yaml
   ```

脚本会按 `name` 精确匹配 Job，找到后向 `/v1/jobs/{id}?action=edit` 发送 JSON：
- `SimpleRetentionPolicy` 内部字段来自 `retention_policy`。
- `BackupTargetOptions.TransformFullToSyntethic` / `TransformToSyntethicDays` 对应 `synthetic_full`。

## 常见问题
- **返回 401**：检查账号密码或是否允许密码模式获取 token；必要时改用 API Token 并调整 `authenticate` 函数。
- **找不到 Job**：名称需与 VBR 中完全一致；可先用 REST `GET /v1/jobs` 确认大小写。
- **字段不兼容**：不同 VBR 版本字段可能有差异，如需增加 GFS 或副本链路，可在 `JobPatch` 类中拓展字段再映射到 payload。

## 后续扩展建议
- 支持 API Token/OAuth client credentials。
- 增加 GFS 周/月底保留策略与备份存储迁移设置。
- 在 dry-run 阶段输出对比（当前值 -> 目标值）。
- 添加 `pytest` 基于假 REST 服务器的集成测试。
