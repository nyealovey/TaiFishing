#!/bin/bash
# =====================================================
# Doris 备份环境验证脚本
# 用途：快速检查 crontab 执行环境是否满足要求
# =====================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

echo "=========================================="
echo "Doris 备份环境验证"
echo "=========================================="
echo ""

# 1. 检查 MySQL 客户端
echo "【1/7】检查 MySQL 客户端..."
MYSQL_FOUND=0
for MYSQL_PATH in \
  /usr/bin/mysql \
  /usr/local/mysql/bin/mysql \
  /usr/local/bin/mysql \
  /opt/mysql/bin/mysql; do
  if [[ -x "$MYSQL_PATH" ]]; then
    echo "  ✓ 找到 MySQL 客户端: $MYSQL_PATH"
    MYSQL_BIN="$MYSQL_PATH"
    MYSQL_FOUND=1
    break
  fi
done

if [[ $MYSQL_FOUND -eq 0 ]]; then
  echo "  ✗ 未找到 MySQL 客户端"
  echo "    请安装 MySQL 客户端或设置 DORIS_MYSQL_BIN 环境变量"
  exit 1
fi

# 2. 检查 .env 文件
echo ""
echo "【2/7】检查 .env 配置文件..."
if [[ ! -f "$ENV_FILE" ]]; then
  echo "  ✗ .env 文件不存在: $ENV_FILE"
  echo "    请复制 env.example 为 .env 并填写配置"
  exit 1
fi
echo "  ✓ .env 文件存在: $ENV_FILE"

# 3. 加载环境变量
echo ""
echo "【3/7】加载环境变量..."
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

REQUIRED_VARS=(
  "DORIS_USER"
  "DORIS_PASSWORD"
  "DORIS_FE_HOST"
  "DORIS_FE_QUERY_PORT"
  "DORIS_REPO"
)

for VAR in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!VAR:-}" ]]; then
    echo "  ✗ 缺少必需变量: $VAR"
    exit 1
  fi
  # 隐藏密码
  if [[ "$VAR" == "DORIS_PASSWORD" ]]; then
    echo "  ✓ $VAR = [已隐藏]"
  else
    echo "  ✓ $VAR = ${!VAR}"
  fi
done

# 4. 测试数据库连接
echo ""
echo "【4/7】测试 Doris FE 连接..."
if MYSQL_PWD="$DORIS_PASSWORD" "$MYSQL_BIN" \
  -h"$DORIS_FE_HOST" \
  -P"$DORIS_FE_QUERY_PORT" \
  -u"$DORIS_USER" \
  --connect-timeout=10 \
  -e "SELECT 1;" >/dev/null 2>&1; then
  echo "  ✓ 数据库连接成功"
else
  echo "  ✗ 数据库连接失败"
  echo "    请检查："
  echo "    - 主机地址: $DORIS_FE_HOST"
  echo "    - 端口: $DORIS_FE_QUERY_PORT"
  echo "    - 用户名: $DORIS_USER"
  echo "    - 密码是否正确"
  echo "    - 网络连通性"
  exit 1
fi

# 5. 检查备份仓库
echo ""
echo "【5/7】检查备份仓库..."
if REPO_INFO=$(MYSQL_PWD="$DORIS_PASSWORD" "$MYSQL_BIN" \
  -h"$DORIS_FE_HOST" \
  -P"$DORIS_FE_QUERY_PORT" \
  -u"$DORIS_USER" \
  -N -s -e "SHOW REPOSITORIES;" 2>&1); then
  
  if echo "$REPO_INFO" | grep -q "$DORIS_REPO"; then
    echo "  ✓ 仓库 [$DORIS_REPO] 存在"
  else
    echo "  ✗ 仓库 [$DORIS_REPO] 不存在"
    echo "    当前可用仓库:"
    echo "$REPO_INFO" | while read -r line; do
      echo "      - $line"
    done
    exit 1
  fi
else
  echo "  ✗ 无法查询仓库列表"
  echo "    错误信息: $REPO_INFO"
  exit 1
fi

# 6. 检查日志目录
echo ""
echo "【6/7】检查日志目录..."
DORIS_LOG_DIR="${DORIS_LOG_DIR:-/home/doris/backup_logs}"
if mkdir -p "$DORIS_LOG_DIR" 2>/dev/null; then
  if touch "$DORIS_LOG_DIR/test_write.tmp" 2>/dev/null; then
    rm -f "$DORIS_LOG_DIR/test_write.tmp"
    echo "  ✓ 日志目录可写: $DORIS_LOG_DIR"
  else
    echo "  ✗ 日志目录无写权限: $DORIS_LOG_DIR"
    exit 1
  fi
else
  echo "  ✗ 无法创建日志目录: $DORIS_LOG_DIR"
  exit 1
fi

# 7. 检查脚本文件
echo ""
echo "【7/7】检查脚本文件..."
SCRIPTS=(
  "$SCRIPT_DIR/doris_backup_prd.sh"
  "$SCRIPT_DIR/cron_wrapper.sh"
)

for SCRIPT in "${SCRIPTS[@]}"; do
  if [[ -f "$SCRIPT" ]]; then
    if [[ -x "$SCRIPT" ]]; then
      echo "  ✓ $(basename "$SCRIPT") 存在且可执行"
    else
      echo "  ⚠ $(basename "$SCRIPT") 存在但不可执行"
      echo "    运行: chmod +x $SCRIPT"
    fi
  else
    echo "  ✗ $(basename "$SCRIPT") 不存在"
  fi
done

# 总结
echo ""
echo "=========================================="
echo "✓ 环境验证通过！"
echo "=========================================="
echo ""
echo "下一步操作："
echo "  1. 手动测试脚本:"
echo "     bash $SCRIPT_DIR/doris_backup_prd.sh"
echo ""
echo "  2. 模拟 crontab 环境测试:"
echo "     env -i HOME=\$HOME SHELL=/bin/bash PATH=/usr/bin:/bin \\"
echo "       bash $SCRIPT_DIR/cron_wrapper.sh"
echo ""
echo "  3. 配置 crontab:"
echo "     crontab -e"
echo "     # 添加："
echo "     30 0 * * * $SCRIPT_DIR/cron_wrapper.sh >> /var/log/doris_backup_cron.log 2>&1"
echo ""
