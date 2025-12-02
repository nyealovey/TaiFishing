# Repository Guidelines

## 项目结构与模块划分
仓库按运行时划分目录：`bash/` 存放常用运维脚本，其中 `bash/doris_backup/` 集中 Doris 备份脚本及 `env.example`，`bash/mysql_backup/` 提供 MySQL 5/8 通用备份脚本与 `.mysql_backup.env` 示例；`python/` 保存跨平台工具，`powershell/` 针对 Windows 自动化，长篇说明与故障手册集中在 `docs/`（例如 `docs/doris_backup_troubleshooting.md`）。新增脚本时请在对应语言目录创建文件，并在 `docs/` 内放置与脚本同名的详细指南或示例。

## 构建、测试与开发命令
Bash 脚本可通过 `bash bash/<script>.sh`（若放在子目录则写全路径，如 `bash bash/doris_backup/doris_backup_prd.sh`、`bash bash/mysql_backup/mysql_backup_unified.sh`）或赋予可执行权限后在仓库根目录直接运行，提交前执行 `shellcheck bash/<path>/<script>.sh` 之类的 lint。Python 工具用 `python3 python/<script>.py`，建议在脚本头部注明虚拟环境或依赖。PowerShell 工具用 `pwsh powershell/<script>.ps1`。需要定时任务时，请把 cron/Task Scheduler 命令写入脚本头并在 `docs/` 留存同样的运行示例。

## 编码风格与命名约定
Bash 采用两空格缩进，默认 `set -euo pipefail` 并优先使用 POSIX 语法；Python 与 PowerShell 使用四空格缩进并遵循 `black`/PSSA 风格。文件名保持小写加下划线（例如 `backup_database.sh`），外部依赖在文件顶部用注释列出，如有需要在旁建立 `requirements.txt` 或 `.psd1`。所有脚本应为变量、函数、日志或配置名选择能体现脚本用途的统一前缀（例如 Doris 备份脚本用 `DORIS_`，MySQL 备份脚本用 `MYSQL_`，ODS 相关脚本可用 `ODS_`），以便快速识别业务域并避免命名冲突。编写注释、README、env 示例等文档时统一使用中文，确保不同贡献者能快速理解背景与操作步骤。

## 测试指南
Python 首选 `pytest`，PowerShell 使用 Pester，Bash 则在 README 或 docs 中提供样例输入输出与快速冒烟命令。请把复现步骤、预期结果与任意测试数据置于 `docs/fixtures/` 或脚本相邻目录，确保关键分支获得验证，并在 PR 中说明尚未覆盖的场景。

## 提交与 PR 规范
提交信息保持祈使句并简短，参考现有 `init` 历史，如 `add doris backup helper`；同一提交只包含紧密相关的脚本。PR 需链接关联 issue 或说明动机，列出执行过的命令、日志或截图，若脚本涉及共享凭据、备份计划或调度策略，请 @ 相关维护者并描述风险缓解措施。

## 安全与配置提示
严禁提交真实凭据，所有敏感参数通过环境变量传入，并在脚本头部列出所需变量名。示例配置以 `<name>.example` 命名放在脚本旁。涉及备份或账号的脚本要记录最小权限角色、日志脱敏步骤及必要的清理命令，防止泄露。
