#!/bin/bash
# =====================================================
# Doris 2.1 改进版备份脚本
# 监控：使用 SHOW SNAPSHOT ON <repo> 判断备份状态，避免遗漏进行中的任务
# =====================================================
#
# 环境变量说明及示例请查看 `bash/doris_backup/env.example`，复制为 `.env` 后按需覆盖默认值。
#
# 运行示例：
#   bash bash/doris_backup/doris_backup_prd.sh
#   DORIS_USER=admin DORIS_PASSWORD=pass bash bash/doris_backup/doris_backup_prd.sh
#
# 定时任务示例（每天凌晨 2 点）：
#   0 2 * * * cd /path/to/repo && bash bash/doris_backup/doris_backup_prd.sh >> /var/log/doris_backup_cron.log 2>&1
# =====================================================

set -euo pipefail

# ==================== 自动加载 .env 配置 ====================
DORIS_ENV_FILE_PATH=${DORIS_ENV_FILE:-".env"}
if [[ -f "$DORIS_ENV_FILE_PATH" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$DORIS_ENV_FILE_PATH"
  set +a
fi
readonly DORIS_ENV_FILE=${DORIS_ENV_FILE:-$DORIS_ENV_FILE_PATH}

# ==================== 配置变量（所有变量集中定义） ====================
readonly DORIS_FE_HOST=${DORIS_FE_HOST:-"127.0.0.1"}
readonly DORIS_FE_QUERY_PORT=${DORIS_FE_QUERY_PORT:-"9030"}
readonly DORIS_MYSQL_BIN=${DORIS_MYSQL_BIN:-"/usr/bin/mysql"}

readonly DORIS_USER=${DORIS_USER:-"backup_user"}
readonly DORIS_PASSWORD=${DORIS_PASSWORD:-"Bkup!2025StrongPass"}
readonly DORIS_REPO=${DORIS_REPO:-"minio_repo"}

readonly DORIS_POLL_INTERVAL=${DORIS_POLL_INTERVAL:-30}
readonly DORIS_BACKUP_TIMEOUT=${DORIS_BACKUP_TIMEOUT:-14400}
readonly DORIS_DB_INTERVAL=${DORIS_DB_INTERVAL:-60}

readonly DORIS_LOG_DIR=${DORIS_LOG_DIR:-"/home/doris/backup_logs"}
readonly DORIS_TODAY_SUFFIX=$(date +%Y%m%d)
readonly DORIS_LOG_FILE="${DORIS_LOG_DIR}/doris_backup_${DORIS_TODAY_SUFFIX}.log"

# ==================== 工具函数 ====================

# 执行 MySQL 命令
run_mysql() {
  "$DORIS_MYSQL_BIN" \
    -h"$DORIS_FE_HOST" \
    -P"$DORIS_FE_QUERY_PORT" \
    -u"$DORIS_USER" \
    -p"$DORIS_PASSWORD" \
    "$@"
}

# 日志函数
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$DORIS_LOG_FILE"
}

# 检查仓库是否可用
check_repository() {
  log "检查备份仓库 [$DORIS_REPO] 状态..."
  if ! REPO_INFO=$(run_mysql -N -s -e "SHOW REPOSITORIES;" 2>&1); then
    log "【错误】无法查询仓库列表"
    return 1
  fi

  if ! echo "$REPO_INFO" | grep -q "$DORIS_REPO"; then
    log "【错误】仓库 [$DORIS_REPO] 不存在"
    return 1
  fi

  log "仓库 [$DORIS_REPO] 检查通过"
  return 0
}

# 取消数据库中可能存在的运行中备份
cancel_running_backup() {
  local db=$1
  log "检查数据库 [$db] 是否有运行中的备份任务..."

  if BACKUP_STATUS=$(run_mysql -N -s -e "SHOW BACKUP FROM \`$db\`;" 2>&1); then
    # 检查是否有 PENDING 或 RUNNING 状态的任务
    if echo "$BACKUP_STATUS" | grep -qE "PENDING|RUNNING|UPLOADING"; then
      log "【警告】发现运行中的备份任务，尝试取消..."
      run_mysql -e "CANCEL BACKUP FROM \`$db\`;" 2>&1 || true
      sleep 10
    fi
  fi
}

# ==================== 主逻辑 ====================

# 创建日志目录
mkdir -p "$DORIS_LOG_DIR"

# 获取数据库列表
DATABASES=$(run_mysql -Nse "
  SELECT SCHEMA_NAME
  FROM information_schema.SCHEMATA
  WHERE SCHEMA_NAME NOT IN (
    'information_schema','__internal_schema','mysql','ctl','sys'
  )
  AND SCHEMA_NAME NOT LIKE 'tmp_%'
  AND SCHEMA_NAME NOT LIKE 'test_%'
  AND SCHEMA_NAME NOT LIKE 'backup_%'
  ORDER BY SCHEMA_NAME;
")

log "========================================================"
log "Doris 改进版备份开始 $(date '+%Y-%m-%d %H:%M:%S')"
log "待备份数据库：$DATABASES"

# 预检查
if ! check_repository; then
  log "【严重错误】仓库检查失败，退出备份"
  exit 1
fi

# 遍历每个数据库进行备份
for DB in $DATABASES; do
  LABEL_NAME="${DB}_${DORIS_TODAY_SUFFIX}"

  log "-------------------------------------------------------"
  log "开始备份数据库 [$DB]，Label = $LABEL_NAME"

  # 清理可能存在的旧任务
  cancel_running_backup "$DB"

  # 提交备份任务
  if ! BACKUP_OUTPUT=$(run_mysql -e "
    BACKUP SNAPSHOT \`$DB\`.\`${LABEL_NAME}\`
    TO \`$DORIS_REPO\`
    PROPERTIES (
      'type' = 'full',
      'timeout' = '$DORIS_BACKUP_TIMEOUT'
    );
  " 2>&1); then
    log "【严重错误】数据库 [$DB] 备份任务提交失败："
    log "$BACKUP_OUTPUT"
    continue
  fi

  log "数据库 [$DB] 备份任务已提交，开始监控进度..."

  START_TIME=$(date +%s)
  LAST_STATUS=""

  while true; do
    sleep "$DORIS_POLL_INTERVAL"

    if ! SNAPSHOT_RESULT=$(run_mysql -N -s -e "SHOW SNAPSHOT ON \`$DORIS_REPO\` WHERE SNAPSHOT = '$LABEL_NAME';" 2>&1); then
      log "【警告】SHOW SNAPSHOT 查询失败，稍后重试"
      continue
    fi

    if [ -z "$SNAPSHOT_RESULT" ]; then
      ELAPSED_MIN=$((($(date +%s) - START_TIME)/60))
      log "【提示】仓库 [$DORIS_REPO] 尚未出现快照 [$LABEL_NAME]，已等待 ${ELAPSED_MIN} 分钟"
    else
      STATUS=$(echo "$SNAPSHOT_RESULT" | awk '{print $NF}')
      TIMESTAMP=$(echo "$SNAPSHOT_RESULT" | awk '{print $(NF-1)}')
      if [ "$STATUS" != "$LAST_STATUS" ]; then
        log "数据库 [$DB] 备份状态变更：$LAST_STATUS -> $STATUS (Timestamp=$TIMESTAMP)"
        LAST_STATUS="$STATUS"
      fi

      case "$STATUS" in
        "OK")
          log "✓ 数据库 [$DB] 备份成功，SHOW SNAPSHOT 状态 OK"
          break
          ;;
        "FAILED"|"CANCELLED")
          log "✗ 数据库 [$DB] 备份失败，SHOW SNAPSHOT 状态=$STATUS"
          log "原始输出：$SNAPSHOT_RESULT"
          break
          ;;
        *)
          ELAPSED_MIN=$((($(date +%s) - START_TIME)/60))
          log "数据库 [$DB] 备份进行中... SHOW SNAPSHOT 状态=$STATUS，已运行 ${ELAPSED_MIN} 分钟"
          ;;
      esac
    fi

    if [ $(($(date +%s) - START_TIME)) -gt "$DORIS_BACKUP_TIMEOUT" ]; then
      log "【严重错误】数据库 [$DB] 备份超时（超过 $((DORIS_BACKUP_TIMEOUT/3600)) 小时），最后状态=$LAST_STATUS"
      break
    fi
  done

  log "数据库 [$DB] 本次备份流程结束，等待 ${DORIS_DB_INTERVAL} 秒后开始下一个库"
  sleep "$DORIS_DB_INTERVAL"
done

log "========================================================"
log "所有数据库备份流程全部结束 $(date '+%Y-%m-%d %H:%M:%S')"
log "日志文件：$DORIS_LOG_FILE"
