#!/bin/bash
# =====================================================
# Doris 2.1 生产每日串行全量备份脚本（一个库一个库来，等完成再下一个）
# 特点：绝不并发、日志完整、失败可告警、支持任意数量数据库
# 核心：用 SHOW SNAPSHOT 轮询完成状态（等待 Status=OK，4 小时超时）
# 优化：BACKUP 语法用 db.`label` 前缀，省略 ON 子句（更简洁）
# =====================================================

# ------------------ 配置区（请修改） ------------------
# 支持通过环境变量覆盖，方便在不同机器或 pipeline 里复用脚本
DORIS_FE_HOST=${DORIS_FE_HOST:-"127.0.0.1"}
DORIS_FE_QUERY_PORT=${DORIS_FE_QUERY_PORT:-"9030"}     # Doris 2.1 MySQL 客户端端口
MYSQL_BIN=${MYSQL_BIN:-"/usr/bin/mysql"}

DORIS_USER=${DORIS_USER:-"backup_user"}
DORIS_PASSWORD=${DORIS_PASSWORD:-"Bkup!2025StrongPass"}
REPO=${REPO:-"minio_repo"}

POLL_INTERVAL=${POLL_INTERVAL:-30}                     # SHOW SNAPSHOT 轮询间隔（秒）
BACKUP_TIMEOUT=${BACKUP_TIMEOUT:-14400}                # 备份超时（秒）
DB_INTERVAL=${DB_INTERVAL:-60}                         # 库之间的延迟（秒）

set -o pipefail

run_mysql() {
    "$MYSQL_BIN" \
        -h"$DORIS_FE_HOST" \
        -P"$DORIS_FE_QUERY_PORT" \
        -u"$DORIS_USER" \
        -p"$DORIS_PASSWORD" \
        "$@"
}

# 自动获取需要备份的数据库（排除系统库 + 临时库，一行搞定）
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



# 日志目录
LOG_DIR="/home/doris/backup_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/doris_backup_$(date +%Y%m%d).log"

# ------------------ 日志函数 ------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_details() {
    local block="$1"
    while IFS= read -r line || [ -n "$line" ]; do
        log "    $line"
    done <<<"$block"
}

# ------------------ 主逻辑 ------------------
log "========================================================"
log "Doris 每日串行备份开始 $(date '+%Y-%m-%d %H:%M:%S')"
log "待备份数据库顺序：$DATABASES"

TODAY_SUFFIX=$(date +%Y%m%d)

for DB in $DATABASES; do
    LABEL_NAME="${DB}_${TODAY_SUFFIX}"
    SNAPSHOT_NAME="${DB}.\`${LABEL_NAME}\`"        # 完整 snapshot: db.`db_YYYYMMDD`

    log "-------------------------------------------------------"
    log "开始备份数据库 [$DB]，Snapshot = $SNAPSHOT_NAME"

    if ! BACKUP_OUTPUT=$(run_mysql -e "
        BACKUP SNAPSHOT $SNAPSHOT_NAME
        TO $REPO
        PROPERTIES (
            'type' = 'full',
            'timeout' = '$BACKUP_TIMEOUT'
        );
    " 2>&1); then
        log "【严重错误】数据库 [$DB] 备份任务提交失败，Doris 返回如下："
        log_details "$BACKUP_OUTPUT"
        # 这里可以加告警：curl 企业微信/钉钉 webhook
        continue
    fi

    log "数据库 [$DB] 备份任务提交成功，开始轮询仓库快照状态..."

    START_TIME=$(date +%s)
    while true; do
        sleep "$POLL_INTERVAL"

        if ! SNAPSHOT_INFO=$(run_mysql -N -s -e "
            SHOW SNAPSHOT ON $REPO WHERE Snapshot LIKE '%$LABEL_NAME%'\G
        " 2>&1); then
            log "【警告】获取仓库快照状态失败，稍后重试，Doris 输出："
            log_details "$SNAPSHOT_INFO"
            continue
        fi

        STATUS=$(echo "$SNAPSHOT_INFO" | awk -F': ' '/Status/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}')
        HAS_SNAPSHOT=$(echo "$SNAPSHOT_INFO" | grep -c "Snapshot:")

        if [ "$HAS_SNAPSHOT" -gt 0 ] && [[ "$STATUS" == "OK" ]]; then
            log "数据库 [$DB] 备份成功完成！仓库快照 Status=OK"
            break
        elif [ "$HAS_SNAPSHOT" -gt 0 ] && [[ "$STATUS" =~ ^(ERROR|CANCELLED)$ ]]; then
            ERROR_MSG=$(echo "$SNAPSHOT_INFO" | awk -F': ' '/ErrMsg/ {print $2; exit}')
            log "【严重错误】数据库 [$DB] 备份失败，Status=$STATUS，ErrMsg=${ERROR_MSG:-无}"
            break
        elif [ $(($(date +%s) - START_TIME)) -gt "$BACKUP_TIMEOUT" ]; then
            log "【严重错误】数据库 [$DB] 备份超时（超过 $((BACKUP_TIMEOUT/3600)) 小时）！"
            # 这里可以加告警
            break
        else
            ELAPSED_MIN=$((($(date +%s) - START_TIME)/60))
            log "数据库 [$DB] 备份进行中... 已运行 ${ELAPSED_MIN} 分钟，快照尚未 OK"
        fi
    done

    log "数据库 [$DB] 本次备份流程结束，准备 ${DB_INTERVAL} 秒后开始下一个库"
    sleep "$DB_INTERVAL"   # 库之间留点喘息时间，防止 FE 压力过大
done

log "========================================================"
log "所有数据库备份流程全部结束 $(date '+%Y-%m-%d %H:%M:%S')"
log "日志文件：$LOG_FILE"
