# Bash 脚本

## 脚本列表

### bash_script_template.sh
通用 Bash 脚本模板，包含：
- 严格模式配置
- 日志记录功能
- 错误处理和告警
- 配置文件支持

### doris_backup/
Doris 数据库备份脚本集合，包含：

#### doris_backup_prd.sh
生产环境备份脚本，增强 crontab 兼容性：
- 串行全量备份多个数据库
- 自动轮询备份状态
- 自动检测 MySQL 客户端路径
- 使用 MYSQL_PWD 避免交互式密码提示
- 自动计算绝对路径，不依赖工作目录
- 完整的环境检查和错误诊断
- 详细的日志输出

#### verify_env.sh
环境验证脚本，快速检查：
- MySQL 客户端是否可用
- .env 配置是否完整
- 数据库连接是否正常
- 备份仓库是否存在
- 日志目录权限是否正确

#### env.example
环境变量配置模板，包含所有可配置项

**使用方法：**
```bash
# 1. 复制配置模板
cp bash/doris_backup/env.example bash/doris_backup/.env

# 2. 编辑配置（填入真实密码）
vim bash/doris_backup/.env

# 3. 验证环境
bash bash/doris_backup/verify_env.sh

# 4. 手动测试
bash bash/doris_backup/doris_backup_prd.sh

# 5. 配置 crontab
crontab -e
# 添加：30 0 * * * cd /path/to/repo && bash bash/doris_backup/doris_backup_prd.sh >> /var/log/doris_backup.log 2>&1
```

**相关文档：**
- Crontab 问题修复：`docs/doris_backup_crontab_fix.md`
- 重构文档：`docs/doris_backup_refactor.md`
- 故障排查：`docs/doris_backup_troubleshooting.md`
