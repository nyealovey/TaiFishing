#!/usr/bin/env bash
# =====================================================
# Bash 通用脚本模版
# Features: 严格模式、配置文件 + 环境变量覆盖、结构化日志、告警钩子、依赖检查
# 使用方法：
#   1. 复制本模版重命名，例如 my_job.sh
#   2. 根据业务修改 DEFAULT_* 配置 & main() 中的核心逻辑
#   3. 如需持久配置，创建同名 .conf（见 CONFIG_FILE 默认路径）并写 KEY=value
# =====================================================

set -euo pipefail
IFS=$'\n\t'
set +H                     # 禁用 history expansion，避免密码中的 ! 被展开

# ------------------ 默认配置，可被环境变量 / conf 覆盖 ------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
SCRIPT_NAME=$(basename "$0")
CONFIG_FILE=${CONFIG_FILE:-"$SCRIPT_DIR/${SCRIPT_NAME%.*}.conf"}

: "${DEFAULT_TASK_NAME:=demo_task}"
: "${LOG_DIR:=/var/log/${SCRIPT_NAME%.*}}"
: "${LOG_BASENAME:=script}"
: "${ALERT_WEBHOOK:=}"                           # 可填钉钉/企微等 Webhook

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${LOG_BASENAME}_$(date '+%Y%m%d').log"

# ------------------ 读取配置文件（如果存在） ------------------
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

# ------------------ 日志与工具函数 ------------------
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log_details() {
    local block="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        log "    $line"
    done <<<"$block"
}

fatal() {
    log "【致命错误】$*"
    send_alert "失败：$*"
    exit 1
}

send_alert() {
    local msg="$1"
    [[ -z "$ALERT_WEBHOOK" ]] && return 0
    curl -sS -X POST "$ALERT_WEBHOOK" \
        -H 'Content-Type: application/json' \
        -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"[$SCRIPT_NAME] $msg\"}}" >/dev/null || true
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || fatal "缺少必要命令：$cmd"
}

run_cmd() {
    local desc="$1"; shift
    if ! OUTPUT=$("$@" 2>&1); then
        log "【错误】执行失败：$desc"
        log_details "$OUTPUT"
        return 1
    fi
    log "【成功】$desc"
    [[ -n "$OUTPUT" ]] && log_details "$OUTPUT"
    return 0
}

cleanup() {
    # TODO: 根据业务需要在脚本退出、被中断时执行收尾工作
    :
}

trap cleanup EXIT INT TERM

# ------------------ 核心逻辑（示例） ------------------
main() {
    require_cmd date

    local task_name=${TASK_NAME:-$DEFAULT_TASK_NAME}
    log "========================================================"
    log "任务 [$task_name] 开始 $(date '+%Y-%m-%d %H:%M:%S')"

    # 示例：执行一段命令并捕获输出
    if ! run_cmd "打印系统信息" uname -a; then
        fatal "任务 [$task_name] 因执行 uname 失败"
    fi

    log "任务 [$task_name] 正常完成"
    log "日志文件：$LOG_FILE"
}

main "$@"
