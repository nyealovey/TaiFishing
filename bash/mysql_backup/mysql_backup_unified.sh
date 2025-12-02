#!/bin/bash
# =====================================================
# MySQL 5/8 通用备份脚本（Percona XtraBackup）
# 通过 env 文件配置，自动判定全量/增量，日志风格与 Doris 备份脚本一致
# =====================================================
#
# 使用前：复制 bash/mysql_backup/env.example 为 .mysql_backup.env 或自定义路径，
#         修改其中的 MYSQL_BACKUP_* 变量。
# =====================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ==================== 自动加载 env 配置 ====================
MYSQL_BACKUP_ENV_FILE_PATH=${MYSQL_BACKUP_ENV_FILE:-".mysql_backup.env"}
if [[ -f "$MYSQL_BACKUP_ENV_FILE_PATH" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$MYSQL_BACKUP_ENV_FILE_PATH"
  set +a
fi
readonly MYSQL_BACKUP_ENV_FILE=${MYSQL_BACKUP_ENV_FILE:-$MYSQL_BACKUP_ENV_FILE_PATH}

# ==================== 配置变量 ====================
readonly MYSQL_BACKUP_MODE=${MYSQL_BACKUP_MODE:-"mysql8"}               # mysql5 或 mysql8
readonly MYSQL_BACKUP_USER=${MYSQL_BACKUP_USER:-"backup"}
readonly MYSQL_BACKUP_PASSWORD=${MYSQL_BACKUP_PASSWORD:-"ChangeMe!"}
readonly MYSQL_BACKUP_HOST=${MYSQL_BACKUP_HOST:-"127.0.0.1"}
readonly MYSQL_BACKUP_PORT=${MYSQL_BACKUP_PORT:-3306}
readonly MYSQL_BACKUP_CONF_FILE=${MYSQL_BACKUP_CONF_FILE:-"/etc/my.cnf"}
readonly MYSQL_BACKUP_TOOL_HOME=${MYSQL_BACKUP_TOOL_HOME:-"/usr"}
readonly MYSQL_BACKUP_TOOL_BIN=${MYSQL_BACKUP_TOOL_BIN:-"$MYSQL_BACKUP_TOOL_HOME/bin"}
readonly MYSQL_BACKUP_TARGET_DIR=${MYSQL_BACKUP_TARGET_DIR:-"/backup"}
readonly MYSQL_BACKUP_FULL_PREFIX=${MYSQL_BACKUP_FULL_PREFIX:-"full"}
readonly MYSQL_BACKUP_INCREMENT_PREFIX=${MYSQL_BACKUP_INCREMENT_PREFIX:-"incr"}
readonly MYSQL_BACKUP_FULL_WEEKDAY=${MYSQL_BACKUP_FULL_WEEKDAY:-7}       # 1-7
readonly MYSQL_BACKUP_FORCE_FULL=${MYSQL_BACKUP_FORCE_FULL:-"false"}
readonly MYSQL_BACKUP_DATA_DIR=${MYSQL_BACKUP_DATA_DIR:-"$SCRIPT_DIR/runtime"}
readonly MYSQL_BACKUP_LOG_DIR=${MYSQL_BACKUP_LOG_DIR:-"$MYSQL_BACKUP_DATA_DIR/log"}
readonly MYSQL_BACKUP_VAR_DIR=${MYSQL_BACKUP_VAR_DIR:-"$MYSQL_BACKUP_DATA_DIR/var"}
readonly MYSQL_BACKUP_INDEX_FILE=${MYSQL_BACKUP_INDEX_FILE:-"$MYSQL_BACKUP_VAR_DIR/mysql_increment.index"}
readonly MYSQL_BACKUP_ERROR_FILE=${MYSQL_BACKUP_ERROR_FILE:-"$MYSQL_BACKUP_VAR_DIR/mysql_increment.err"}
readonly MYSQL_BACKUP_INDEX_BACKUP=${MYSQL_BACKUP_INDEX_BACKUP:-"true"}
readonly MYSQL_BACKUP_LOG_RETENTION=${MYSQL_BACKUP_LOG_RETENTION:-30}

readonly MYSQL_BACKUP_DATE=$(date +%F)
readonly MYSQL_BACKUP_TIME=$(date +%H-%M-%S)
readonly MYSQL_BACKUP_WEEKDAY=$(date +%u)
readonly MYSQL_BACKUP_LABEL_SUFFIX="${MYSQL_BACKUP_DATE}_${MYSQL_BACKUP_TIME}_${MYSQL_BACKUP_WEEKDAY}"
readonly MYSQL_BACKUP_LOG_FILE="$MYSQL_BACKUP_LOG_DIR/mysql_backup_${MYSQL_BACKUP_LABEL_SUFFIX}.log"

mkdir -p "$MYSQL_BACKUP_LOG_DIR" "$MYSQL_BACKUP_VAR_DIR" "$MYSQL_BACKUP_TARGET_DIR"
touch "$MYSQL_BACKUP_INDEX_FILE" "$MYSQL_BACKUP_ERROR_FILE"

# ==================== 辅助函数 ====================
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$MYSQL_BACKUP_LOG_FILE"
}

fail() {
  log "【错误】$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$MYSQL_BACKUP_ERROR_FILE"
}

backup_index_file() {
  [[ "$MYSQL_BACKUP_INDEX_BACKUP" != "true" ]] && return 0
  local snapshot="$MYSQL_BACKUP_INDEX_FILE.$(date +%Y%m%d_%H%M%S)"
  cp "$MYSQL_BACKUP_INDEX_FILE" "$snapshot"
  log "索引文件已备份到 $snapshot"
}

parse_last_backup_dir() {
  if [[ ! -s "$MYSQL_BACKUP_INDEX_FILE" ]]; then
    echo ""
    return 0
  fi
  tail -n 1 "$MYSQL_BACKUP_INDEX_FILE" | awk -F',' '{print $3}'
}

append_index() {
  local type=$1
  local label=$2
  printf "%s,%s,%s,%s\n" "$MYSQL_BACKUP_WEEKDAY" "$type" "$label" "$MYSQL_BACKUP_DATE" >> "$MYSQL_BACKUP_INDEX_FILE"
}

clear_index() {
  : > "$MYSQL_BACKUP_INDEX_FILE"
}

cleanup_previous_backups() {
  while IFS=',' read -r _ type label _; do
    [[ -z "$label" ]] && continue
    local path="$MYSQL_BACKUP_TARGET_DIR/$label"
    if [[ -d "$path" ]]; then
      rm -rf "$path"
      log "已删除旧备份目录 $path"
    fi
    local log_path="$MYSQL_BACKUP_LOG_DIR/${label}.log"
    [[ -f "$log_path" ]] && rm -f "$log_path"
  done < "$MYSQL_BACKUP_INDEX_FILE"
}

keep_recent_logs() {
  find "$MYSQL_BACKUP_LOG_DIR" -type f -name 'mysql_backup_*.log' -mtime +"$MYSQL_BACKUP_LOG_RETENTION" -delete || true
}

build_backup_cmd() {
  local target=$1
  local mode=$2 # full or incremental
  local incr_base=${3:-}
  BACKUP_CMD=()
  case "$MYSQL_BACKUP_MODE" in
    mysql5)
      BACKUP_CMD=("$MYSQL_BACKUP_TOOL_BIN/innobackupex"
        "--defaults-file=$MYSQL_BACKUP_CONF_FILE"
        "--user=$MYSQL_BACKUP_USER"
        "--password=$MYSQL_BACKUP_PASSWORD"
        "--host=$MYSQL_BACKUP_HOST"
        "--port=$MYSQL_BACKUP_PORT"
        "--no-timestamp")
      [[ "$mode" == "incremental" ]] && BACKUP_CMD+=("--incremental" "--incremental-basedir=$incr_base")
      BACKUP_CMD+=("$target")
      ;;
    mysql8)
      BACKUP_CMD=("$MYSQL_BACKUP_TOOL_BIN/xtrabackup"
        "--defaults-file=$MYSQL_BACKUP_CONF_FILE"
        "--user=$MYSQL_BACKUP_USER"
        "--password=$MYSQL_BACKUP_PASSWORD"
        "--host=$MYSQL_BACKUP_HOST"
        "--port=$MYSQL_BACKUP_PORT"
        "--backup"
        "--target-dir=$target")
      [[ "$mode" == "incremental" ]] && BACKUP_CMD+=("--incremental-basedir=$incr_base")
      ;;
    *)
      fail "未知的 MYSQL_BACKUP_MODE=$MYSQL_BACKUP_MODE (支持 mysql5/mysql8)"
      exit 1
      ;;
  esac
}

run_backup() {
  local type=$1
  local label=$2
  local target_dir="$MYSQL_BACKUP_TARGET_DIR/$label"
  mkdir -p "$target_dir"

  local incr_base=""
  [[ "$type" == "incremental" ]] && incr_base=$(parse_last_backup_dir)
  if [[ "$type" == "incremental" && -z "$incr_base" ]]; then
    log "未找到增量基线，将回退为全量备份"
    type="full"
  fi

  local base_path=""
  [[ -n "$incr_base" ]] && base_path="$MYSQL_BACKUP_TARGET_DIR/$incr_base"

  local BACKUP_CMD=()
  build_backup_cmd "$target_dir" "$type" "$base_path"
  log "执行备份命令：${BACKUP_CMD[*]}"
  if "${BACKUP_CMD[@]}" >> "$MYSQL_BACKUP_LOG_FILE" 2>&1; then
    return 0
  else
    return 1
  fi
}

log_backup_result() {
  local type=$1
  local label=$2
  local status=$3
  if [[ "$status" -eq 0 ]]; then
    log "✓ ${type^^} 备份成功：$label"
    if [[ "$type" == "full" ]]; then
      backup_index_file
      cleanup_previous_backups
      clear_index
    fi
    append_index "$type" "$label"
  else
    fail "${type^^} 备份失败：$label"
    rm -rf "$MYSQL_BACKUP_TARGET_DIR/$label"
  fi
}

select_backup_type() {
  if [[ "$MYSQL_BACKUP_FORCE_FULL" == "true" ]]; then
    echo "full"; return
  fi
  if [[ ! -s "$MYSQL_BACKUP_INDEX_FILE" ]]; then
    echo "full"; return
  fi
  if [[ "$MYSQL_BACKUP_FULL_WEEKDAY" -eq "$MYSQL_BACKUP_WEEKDAY" ]]; then
    echo "full"; return
  fi
  echo "incremental"
}

validate_required() {
  local missing=()
  [[ -z "$MYSQL_BACKUP_USER" ]] && missing+=(MYSQL_BACKUP_USER)
  [[ -z "$MYSQL_BACKUP_PASSWORD" ]] && missing+=(MYSQL_BACKUP_PASSWORD)
  [[ -z "$MYSQL_BACKUP_CONF_FILE" ]] && missing+=(MYSQL_BACKUP_CONF_FILE)
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '缺少必要变量: %s\n' "${missing[*]}" >&2
    exit 2
  fi
}

# ==================== 主流程 ====================
validate_required
keep_recent_logs

log "========================================================"
log "MySQL 备份开始，模式=$MYSQL_BACKUP_MODE，目标目录=$MYSQL_BACKUP_TARGET_DIR"
log "使用配置文件：$MYSQL_BACKUP_CONF_FILE；日志：$MYSQL_BACKUP_LOG_FILE"

backup_type=$(select_backup_type)
case "$backup_type" in
  full)
    label="${MYSQL_BACKUP_FULL_PREFIX}_${MYSQL_BACKUP_LABEL_SUFFIX}"
    if run_backup "full" "$label"; then
      log_backup_result "full" "$label" 0
    else
      log_backup_result "full" "$label" 1
      exit 1
    fi
    ;;
  incremental)
    label="${MYSQL_BACKUP_INCREMENT_PREFIX}_${MYSQL_BACKUP_LABEL_SUFFIX}"
    if run_backup "incremental" "$label"; then
      log_backup_result "incremental" "$label" 0
    else
      log_backup_result "incremental" "$label" 1
      exit 1
    fi
    ;;
  *)
    fail "无法识别的备份类型：$backup_type"
    exit 1
    ;;
 esac

log "所有步骤完成，索引文件：$MYSQL_BACKUP_INDEX_FILE"
