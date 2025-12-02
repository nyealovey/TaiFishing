#!/bin/bash
# =====================================================
# Doris 备份流程冒烟脚本（单库）
# 专门用于在测试/演练环境验证备份流程，仅备份指定数据库
# 默认数据库：ODS_PC_test，可通过 DORIS_TEST_DB 覆盖
# =====================================================
#
# 环境变量说明及示例请参考 `bash/doris_backup/env.example`，复制为 `.env` 后根据测试场景调整（如 `DORIS_TEST_DB`、`DORIS_TEST_PREFIX`）。
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

# ==================== 配置变量 ====================
readonly DORIS_FE_HOST=${DORIS_FE_HOST:-"127.0.0.1"}
readonly DORIS_FE_QUERY_PORT=${DORIS_FE_QUERY_PORT:-"9030"}
readonly DORIS_MYSQL_BIN=${DORIS_MYSQL_BIN:-"/usr/bin/mysql"}
readonly DORIS_USER=${DORIS_USER:-"backup_user"}
readonly DORIS_PASSWORD=${DORIS_PASSWORD:-"Bkup!2025StrongPass"}
readonly DORIS_REPO=${DORIS_REPO:-"minio_repo"}
readonly DORIS_POLL_INTERVAL=${DORIS_POLL_INTERVAL:-15}
readonly DORIS_BACKUP_TIMEOUT=${DORIS_BACKUP_TIMEOUT:-3600}
readonly DORIS_LOG_DIR=${DORIS_LOG_DIR:-"/home/doris/backup_logs/test"}
readonly DORIS_TEST_DB=${DORIS_TEST_DB:-"ODS_PC_test"}
readonly DORIS_TEST_PREFIX=${DORIS_TEST_PREFIX:-"smoke"}
readonly DORIS_TODAY_SUFFIX=$(date +%Y%m%d_%H%M%S)
readonly DORIS_LOG_FILE="${DORIS_LOG_DIR}/doris_backup_test_${DORIS_TODAY_SUFFIX}.log"
readonly DORIS_LABEL_NAME="${DORIS_TEST_PREFIX}_${DORIS_TEST_DB}_${DORIS_TODAY_SUFFIX}"

# ==================== 工具函数 ====================
run_mysql() {
  "$DORIS_MYSQL_BIN" \
    -h"$DORIS_FE_HOST" \
    -P"$DORIS_FE_QUERY_PORT" \
    -u"$DORIS_USER" \
    -p"$DORIS_PASSWORD" \
    "$@"
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$DORIS_LOG_FILE"
}

check_repository() {
  log "检查仓库 [$DORIS_REPO]..."
  if ! REPO_INFO=$(run_mysql -N -s -e "SHOW REPOSITORIES;" 2>&1); then
    log "【错误】SHOW REPOSITORIES 失败"
    return 1
  fi
  if ! echo "$REPO_INFO" | grep -q "$DORIS_REPO"; then
    log "【错误】仓库 [$DORIS_REPO] 不存在"
    return 1
  fi
  log "仓库 [$DORIS_REPO] 可用"
}

cancel_running_backup() {
  log "检查 [$DORIS_TEST_DB] 现有备份..."
  if BACKUP_STATUS=$(run_mysql -N -s -e "SHOW BACKUP FROM \`$DORIS_TEST_DB\`;" 2>&1); then
    if echo "$BACKUP_STATUS" | grep -qE "PENDING|RUNNING|UPLOADING"; then
      log "【警告】检测到运行中的备份，执行取消命令"
      run_mysql -e "CANCEL BACKUP FROM \`$DORIS_TEST_DB\`;" 2>&1 || true
      sleep 5
    fi
  fi
}

submit_backup() {
  log "提交数据库 [$DORIS_TEST_DB] 的冒烟备份，Label=$DORIS_LABEL_NAME"
  if ! BACKUP_OUTPUT=$(run_mysql -e "
    BACKUP SNAPSHOT \`$DORIS_TEST_DB\`.\`$DORIS_LABEL_NAME\`
    TO \`$DORIS_REPO\`
    PROPERTIES ('type'='full', 'timeout'='$DORIS_BACKUP_TIMEOUT');
  " 2>&1); then
    log "【严重错误】备份提交失败：$BACKUP_OUTPUT"
    exit 1
  fi
}

monitor_backup() {
  local start_ts=$(date +%s)
  local last_status=""
  log "开始轮询 SHOW SNAPSHOT ON \`$DORIS_REPO\`，每 ${DORIS_POLL_INTERVAL}s 一次"
  while true; do
    sleep "$DORIS_POLL_INTERVAL"
    if ! SNAPSHOT_RESULT=$(run_mysql -N -s -e "SHOW SNAPSHOT ON \`$DORIS_REPO\` WHERE SNAPSHOT = '$DORIS_LABEL_NAME';" 2>&1); then
      log "【警告】SHOW SNAPSHOT 查询失败，稍后重试"
      continue
    fi

    if [[ -z "$SNAPSHOT_RESULT" ]]; then
      log "【提示】仓库 [$DORIS_REPO] 尚未出现快照 [$DORIS_LABEL_NAME]"
    else
      local status timestamp
      status=$(echo "$SNAPSHOT_RESULT" | awk '{print $NF}')
      timestamp=$(echo "$SNAPSHOT_RESULT" | awk '{print $(NF-1)}')
      if [[ "$status" != "$last_status" ]]; then
        log "状态变更：$last_status -> $status (Timestamp=$timestamp)"
        last_status="$status"
      fi
      if [[ "$status" == "OK" ]]; then
        log "✓ SHOW SNAPSHOT 返回 OK，备份完成"
        return 0
      fi
      if [[ "$status" == "FAILED" || "$status" == "CANCELLED" ]]; then
        log "✗ SHOW SNAPSHOT 返回失败状态：$status"
        log "原始输出：$SNAPSHOT_RESULT"
        exit 1
      fi
    fi

    if [ $(($(date +%s) - start_ts)) -gt "$DORIS_BACKUP_TIMEOUT" ]; then
      log "【严重错误】备份超时，最后状态=$last_status"
      exit 1
    fi
  done
}

# ==================== 主流程 ====================
mkdir -p "$DORIS_LOG_DIR"
log "========================================================"
log "Doris 单库冒烟备份开始，数据库=$DORIS_TEST_DB，Label=$DORIS_LABEL_NAME"
check_repository
cancel_running_backup
submit_backup
monitor_backup
log "所有步骤完成，日志文件：$DORIS_LOG_FILE"
