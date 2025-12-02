# Doris Backup Troubleshooting Guide

## Issue: Snapshots Never Appear (Timeout After 240 Minutes)

### Symptoms
- Backup task submits successfully
- Script polls for snapshot status but snapshot never appears
- Each database times out after 4 hours
- Log shows: "【提示】快照 [DB_20251201] 尚未出现"

### Root Causes & Solutions

#### 1. Check Repository Connectivity
```sql
-- Verify repository exists and is accessible
SHOW REPOSITORIES;

-- Check repository status
SHOW SNAPSHOT ON minio_repo;
```

#### 2. Check Backup Job Status
The script should check `SHOW BACKUP` instead of just `SHOW SNAPSHOT`:

```sql
-- Check active backup jobs
SHOW BACKUP FROM database_name;

-- This shows the actual backup progress, not just snapshots
```

#### 3. Common Issues

**A. Repository Not Accessible**
- MinIO credentials expired
- Network connectivity issues
- S3 bucket permissions

**B. Backup Job Stuck**
- Previous backup jobs not cleaned up
- FE/BE nodes overloaded
- Insufficient resources

**C. Syntax Issue**
- The BACKUP SNAPSHOT syntax might need adjustment for Doris 2.1

### Recommended Script Fixes

1. **Add backup job status check** before polling snapshots
2. **Check for existing running backups** before starting new one
3. **Add repository health check** at script start
4. **Improve error detection** from BACKUP command output

### Immediate Actions

```bash
# 1. Check if backups are actually running
mysql -h127.0.0.1 -P9030 -ubackup_user -p -e "SHOW BACKUP FROM ADS;"

# 2. Check repository
mysql -h127.0.0.1 -P9030 -ubackup_user -p -e "SHOW REPOSITORIES;"

# 3. Check for stuck jobs
mysql -h127.0.0.1 -P9030 -ubackup_user -p -e "SHOW PROC '/jobs/backup';"

# 4. Cancel stuck backup if needed
mysql -h127.0.0.1 -P9030 -ubackup_user -p -e "CANCEL BACKUP FROM ADS;"
```

### Prevention

- Add pre-flight checks before starting backup
- Monitor backup job status, not just snapshot status
- Set up alerts for backup failures
- Implement backup job cleanup routine
