#!/usr/bin/env bash
# 升级后端：加载新包镜像 → 停后端 → 数据备份 → 换 compose 标签 → 只重建后端。
# 用法：ops/upgrade.sh <新包目录>
# NapCat 与 QQ 登录卷不动；凭证与 data/ 留在部署目录，不随包覆盖。
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
source ops/common.sh
require_deploy_layout

NEW=${1:?用法：ops/upgrade.sh <新包目录>}
[[ -d $NEW ]] || fail "新包目录不存在：$NEW"
for f in VERSION.txt SHA256SUMS docker-compose.yml backend-image.tar.gz; do
    [[ -f $NEW/$f ]] || fail "新包缺 $f"
done

echo "== 校验新包 SHA256 =="
( cd "$NEW" && sha256sum --quiet -c SHA256SUMS ) || fail "新包校验失败，拒绝升级"

NEW_TAG=$(awk '/image:[[:space:]]*dafeiyu-backend:/ {sub(/.*dafeiyu-backend:/, "", $0); print; exit}' "$NEW/docker-compose.yml")
[[ -n $NEW_TAG ]] || fail "新包 compose 里没有 dafeiyu-backend 标签"
OLD_TAG=$(current_backend_tag)
if [[ $NEW_TAG == "$OLD_TAG" ]]; then
    fail "新包标签与当前相同（dafeiyu-backend:$NEW_TAG），无需升级"
fi

echo "== 加载新镜像 =="
"${DOCKER_CMD[@]}" load -i "$NEW/backend-image.tar.gz"

case "$(uname -m)" in
    x86_64) HOST_PLATFORM="linux/amd64" ;;
    aarch64|arm64) HOST_PLATFORM="linux/arm64" ;;
    *) HOST_PLATFORM="unknown" ;;
esac
IMG_PLATFORM=$("${DOCKER_CMD[@]}" image inspect "dafeiyu-backend:$NEW_TAG" --format '{{.Os}}/{{.Architecture}}')
[[ $IMG_PLATFORM == "$HOST_PLATFORM" ]] || fail "新镜像平台 $IMG_PLATFORM 与主机 $HOST_PLATFORM 不一致"

echo "== 升级前备份（仅数据，后端将停止） =="
compose stop backend
bash ops/backup.sh --data-only --label pre-upgrade
BACKUP_DIR=$(ls -dt backups/pre-upgrade-* | head -1)

echo "== 换 compose 标签：$OLD_TAG → $NEW_TAG =="
sed -E "s|(image:[[:space:]]*)dafeiyu-backend:[^[:space:]]+|\1dafeiyu-backend:$NEW_TAG|" \
    docker-compose.yml > docker-compose.yml.new
grep -q "dafeiyu-backend:$NEW_TAG" docker-compose.yml.new || fail "标签替换失败，放弃"
mv docker-compose.yml.new docker-compose.yml

echo "== 只重建后端 =="
compose up -d --no-deps --force-recreate backend

sleep 3
STATE=$("${DOCKER_CMD[@]}" inspect dafeiyu-backend --format '{{.State.Status}}' 2>/dev/null || echo missing)
[[ $STATE == running ]] || fail "后端未进入 running（当前 $STATE）。回滚：bash ops/rollback.sh"

echo
echo "升级完成：$OLD_TAG → $NEW_TAG"
echo "升级前数据备份：$BACKUP_DIR"
echo "下一步：打开面板做单次验收（由真实会话 @ 触发一次并自动暂停），确认后再继续运行。"
