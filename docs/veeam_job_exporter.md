# veeam_job_exporter 使用说明

本工具通过 Veeam Backup & Replication (VBR) REST API 导出全部 Job 清单为 CSV，便于审计、盘点或批量调整前留档。

## 依赖与准备
- Python 3.8+
- 依赖库：`requests`
  ```bash
  pip install requests
  ```
- 环境变量（均以 `VEEAM_` 前缀）：
  - `VEEAM_SERVER`：VBR 服务器地址（必填）。
  - `VEEAM_PORT`：REST 端口，默认 9419。
  - `VEEAM_USERNAME` / `VEEAM_PASSWORD`：账号与密码（必填）。
  - `VEEAM_VERIFY_SSL`：是否校验证书，`true`/`false`，默认 `true`。
  - `VEEAM_API_VERSION`：REST API 版本，默认 `1.2-rev1`。
  - 若在脚本目录 `python/veeam/.env` 提供同名变量，会在启动时自动加载（不会覆盖已有环境变量）。

## 运行示例
```bash
VEEAM_SERVER=10.0.0.8 \
VEEAM_USERNAME=svc_veeam \
VEEAM_PASSWORD='***' \
python3 python/veeam/veeam_job_exporter.py --output /tmp/veeam_jobs.csv
```

## 可选参数
- `--output`：输出 CSV 路径，默认写入脚本目录 `python/veeam/veeam_jobs.csv`；仅给文件名时也会落在脚本目录。
- `--fields`：以逗号分隔的字段列表，默认 `id,name,type,platform,state,description`。
- `--limit`：API 返回 Job 的数量上限，例如 `--limit 500`；不指定时读取环境变量 `VEEAM_JOB_LIMIT`，若为空则使用服务器默认限制。
- `--page-size`：单次请求的条数，默认 `min(limit,1000)` 或服务器默认，最大 1000；可用环境变量 `VEEAM_JOB_PAGE_SIZE` 设置。
- `--include-extra`：同时抓取 `backupCopyJobs`、`replicationJobs`、`fileShareBackupJobs` 等附加集合（若接口存在会合并到 CSV）。
  - `id` 字段会自动兼容 `id`/`Uid`/`jobId`。

## 输出说明
CSV 采用 UTF-8 编码，首行是列名，其余每行对应一个 Job。未知或缺失字段写为空字符串。

## 常见问题
- **401 鉴权失败**：检查账号密码或 REST API 是否启用密码模式；必要时改为 API Token 并调整 `authenticate`。
- **字段缺失**：不同 VBR 版本字段命名略有差异，可通过 `--fields name,description,jobType` 等方式自定义导出。
- **证书校验错误**：将 `VEEAM_VERIFY_SSL=false`（仅限受控环境）或导入正确的根证书。

## 后续扩展建议
- 支持分页/筛选（如按 `type` 过滤）。
- 导出 Job 内部的备份对象、存储库信息。
- 与 `veeam_job_updater` 结合，实现“先导出后批量更新”的闭环流程。
