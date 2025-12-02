-- Doris 2.1 备份最小权限示例
-- 官方文档（Backup & Restore for 2.1）指出：仅 ADMIN_PRIV 用户可以执行 BACKUP/RESTORE。
-- 参考：https://doris.apache.org/docs/2.1/admin-manual/data-admin/backup-restore/backup/

-- 1. 创建专用备份用户（如已有可跳过）
CREATE USER IF NOT EXISTS 'doris_backup'@'%' IDENTIFIED BY 'ChangeMe!2025';

-- 2. 授予全局 ADMIN_PRIV（允许备份、恢复、仓库管理等必要操作）
GRANT ADMIN_PRIV ON *.*.* TO 'doris_backup'@'%';

-- 3. （可选）针对需要访问的资源仓库授予 USAGE 权限，便于限制到特定仓库
GRANT USAGE_PRIV ON RESOURCE 'minio_repo' TO 'doris_backup'@'%';

-- 4. 刷新权限
FLUSH PRIVILEGES;
