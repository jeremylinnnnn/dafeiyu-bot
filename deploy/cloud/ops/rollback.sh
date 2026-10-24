#!/usr/bin/env bash
# 回滚后端到最近一次升级前的版本。只换镜像与 compose，不自动回滚数据。
# 用法：ops/rollback.sh
# 数据格式如与新镜像不兼容，先 ops/restore.sh 恢复配对的 pre-upgrade 数据备份。
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
source ops/common.sh
require_deploy_layout

BACKUP_DIR=$(ls -dt backups/pre-upgrade-* 2>/dev/null | head -1 || true)
[[ -n $BACKUP_DIR && -f $BACKUP_DIR/docker-compose.yml ]] || fail "找不到升级前备份（backups/pre-upgrade-*/docker-compose.yml）"

OLD_TAG=$(awk '/image:[[:space:]]*dafeiyu-backend:/ {sub(/.*dafeiyu-backend:/, "", $0); print; exit}' "$BACKUP_DIR/docker-compose.yml")
[[ -n $OLD_TAG ]] || fail "$BACKUP_DIR/docker-compose.yml 里没有后端标签"
CUR_TAG=$(current_backend_tag)
if [[ $OLD_TAG == "$CUR_TAG" ]]; then
    fail "当前标签与升级前相同（dafeiyu-backend:$CUR_TAG），没有可回滚的升级"
fi
"${DOCKER_CMD[@]}" image inspect "dafeiyu-backend:$OLD_TAG" >/dev/null 2>&1 \
    || fail "旧镜像 dafeiyu-backend:$OLD_TAG 不在本机（升级未删除镜像；若已被清理则无法回滚）"

if [[ -f $BACKUP_DIR/info.txt ]] && grep -q 'backend_tag='"$OLD_TAG" "$BACKUP_DIR/info.txt"; then
    : # 记录与 compose 一致
else
    warn "$BACKUP_DIR/info.txt 缺失或与 compose 标签不一致，继续前请人工确认该备份确属版本 $OLD_TAG"
fi

echo "== 回滚前留底（数据 + 当前 compose） =="
compose stop backend
bash ops/backup.sh --data-only --label pre-rollback

echo "== 停后端，恢复 $BACKUP_DIR 的 compose（标签 ${CUR_TAG} → ${OLD_TAG}） =="
compose stop backend
cp "$BACKUP_DIR/docker-compose.yml" docker-compose.yml
compose up -d --no-deps --force-recreate backend

sleep 3
STATE=$("${DOCKER_CMD[@]}" inspect dafeiyu-backend --format '{{.State.Status}}' 2>/dev/null || echo missing)
[[ $STATE == running ]] || fail "后端未进入 running（当前 $STATE）"

echo
echo "回滚完成：$CUR_TAG → $OLD_TAG"
echo "注意：只回滚了镜像。若新版写过数据，必要时用 ops/restore.sh 恢复配对数据备份：$BACKUP_DIR"
echo "下一步：面板确认连接与授权状态，再做单次验收。"
