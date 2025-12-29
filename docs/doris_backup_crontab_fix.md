# Doris 备份脚本 Crontab 执行问题修复文档

## 问题现象
脚本手动执行正常，但在 crontab 中卡在"正在查询待备份数据库列表..."步骤，无后续输出。

---

## 根本原因

### 1. PATH 环境变量缺失
crontab 的 PATH 极简（`/usr/bin:/bin`），无法找到 MySQL 客户端或其他依赖工具。

### 2. 工作目录不一致
crontab 默认在 `$HOME` 执行，脚本中的相对路径 `.env` 无法正确加载。

### 3. 环境变量未传递
crontab 不加载 shell 配置文件（`.bashrc`/`.bash_profile`），导致环境变量丢失。

### 4. MySQL 客户端交互式提示
`-p` 参数在某些场景下可能触发密码输入提示，导致脚本挂起。

### 5. 日志目录权限
`/home/doris/backup_logs` 可能不存在或 cron 用户无写权限。

---

## 修复方案：脚本内部增强

重构后的 `doris_backup_prd.sh` 已内置环境检测与自动修复，无需额外配置。

### 核心改进

| 改进项 | 原实现 | 新实现 | 效果 |
|-------|--------|--------|------|
| **MySQL 客户端查找** | 固定 `/usr/bin/mysql` | 自动搜索多个路径 | 适配不同安装方式 |
| **密码传递方式** | `-p"$DORIS_PASSWORD"` | `MYSQL_PWD` 环境变量 | 避免交互式提示 |
| **路径处理** | 相对路径 `.env` | 自动计算绝对路径 | 不依赖工作目录 |
| **环境检查** | 无 | `check_prerequisites()` | 提前发现配置问题 |
| **错误诊断** | 简单输出 | 详细日志 + 错误提示 | 快速定位问题 |
| **连接测试** | 无 | 执行 `SELECT 1` 测试 | 验证数据库连通性 |

### Crontab 配置

只需在 crontab 中添加一行，脚本会自动处理所有环境问题：

```bash
# 编辑 crontab
crontab -e

# 添加以下内容（每天凌晨 00:30 执行）
30 0 * * * cd /path/to/repo && bash bash/doris_backup/doris_backup_prd.sh >> /var/log/doris_backup.log 2>&1
```

**关键点：**
- `cd /path/to/repo`：切换到仓库根目录（脚本会自动定位 `.env` 文件）
- 日志重定向：`>> /var/log/doris_backup.log 2>&1`

---

## 使用步骤

### 1. 配置环境变量
```bash
# 复制配置模板
cp bash/doris_backup/env.example bash/doris_backup/.env

# 编辑配置（填入真实密码）
vim bash/doris_backup/.env
```

### 2. 验证环境
```bash
# 运行环境验证脚本
bash bash/doris_backup/verify_env.sh
```

### 3. 手动测试
```bash
# 在仓库根目录执行
cd /path/to/repo
bash bash/doris_backup/doris_backup_prd.sh
```

### 4. 配置 Crontab
```bash
crontab -e
# 添加：
30 0 * * * cd /path/to/repo && bash bash/doris_backup/doris_backup_prd.sh >> /var/log/doris_backup.log 2>&1
```

### 5. 验证定时任务
```bash
# 临时设置为每分钟执行一次测试
* * * * * cd /path/to/repo && bash bash/doris_backup/doris_backup_prd.sh >> /tmp/doris_test.log 2>&1

# 等待 2 分钟后检查日志
tail -f /tmp/doris_test.log

# 确认无误后恢复正常时间
```

---

## 调试步骤

### 1. 确认 MySQL 客户端路径
```bash
which mysql
# 输出示例：/usr/local/mysql/bin/mysql
```

### 2. 测试数据库连接
```bash
source bash/doris_backup/.env
mysql -h"$DORIS_FE_HOST" -P"$DORIS_FE_QUERY_PORT" -u"$DORIS_USER" -p"$DORIS_PASSWORD" -e "SELECT 1;"
```

### 3. 手动模拟 crontab 环境
```bash
env -i HOME=$HOME SHELL=/bin/bash PATH=/usr/bin:/bin \
  bash -c "cd /path/to/repo && bash bash/doris_backup/doris_backup_prd.sh"
```

### 4. 检查日志权限
```bash
sudo mkdir -p /home/doris/backup_logs
sudo chown $(whoami):$(whoami) /home/doris/backup_logs
sudo chmod 755 /home/doris/backup_logs
```

---

## 验证清单

- [ ] `.env` 文件已创建并填写正确配置
- [ ] `verify_env.sh` 验证通过
- [ ] 手动执行脚本成功
- [ ] 模拟 crontab 环境测试通过
- [ ] crontab 中包含 `cd /path/to/repo`
- [ ] 日志文件正常生成且无错误

---

## 相关文件
- 备份脚本：`bash/doris_backup/doris_backup_prd.sh`
- 环境验证：`bash/doris_backup/verify_env.sh`
- 环境配置：`bash/doris_backup/.env`（从 `env.example` 复制）
- 重构文档：`docs/doris_backup_refactor.md`
- 故障排查：`docs/doris_backup_troubleshooting.md`
