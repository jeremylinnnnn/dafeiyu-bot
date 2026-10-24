#!/usr/bin/env bash
# 从备份恢复。危险操作：先停整个栈，恢复期间旧数据只改名不删除。
# 用法：ops/restore.sh <备份目录>（相对或绝对路径均可）
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
source ops/common.sh

BACKUP=${1:?用法：ops/restore.sh <备份目录>}
[[ -d $BACKUP ]] || fail "备份目录不存在：$BACKUP"
# 统一解析成绝对路径：直接拿相对路径拼 $PWD 会挂载到错误位置，
# 而且此时旧 data 已经改名，出错即进退两难。
BACKUP=$(cd -- "$BACKUP" && pwd)
[[ -f $BACKUP/data.tar.gz ]] || fail "备份目录里没有 data.tar.gz"
require_deploy_layout
IMG="dafeiyu-backend:$(current_backend_tag)"

RUNNING=$(compose ps --status running -q 2>/dev/null | wc -l)
(( RUNNING == 0 )) || fail "栈仍在运行（$RUNNING 个容器）。先 docker compose stop 再恢复。"

TS=$(date -u +%Y%m%dT%H%M%SZ)
TAG_OLD=$(current_backend_tag)

echo "== 恢复 data/（旧的改名为 data.pre-restore-$TS，不删除） =="
[[ -e data.pre-restore-$TS ]] && fail "同名暂存目录已存在：data.pre-restore-$TS"
[[ -d data ]] && mv data "data.pre-restore-$TS"
mkdir data
"${DOCKER_CMD[@]}" run --rm -u 0 --entrypoint sh \
    -v "$PWD:/rootfs" -v "$BACKUP:/backup:ro" \
    "$IMG" -c 'tar xzf /backup/data.tar.gz -C /rootfs/data --numeric-owner && chown 10001:10001 /rootfs/data'

if [[ -f $BACKUP/config.tar.gz ]]; then
    echo "== 恢复 config/ =="
    [[ -d config && -n $(ls -A config 2>/dev/null) ]] && mv config "config.pre-restore-$TS"
    mkdir -p config
    "${DOCKER_CMD[@]}" run --rm -u 0 --entrypoint tar \
        -v "$PWD:/rootfs" -v "$BACKUP:/backup:ro" \
        "$IMG" xzf /backup/config.tar.gz -C /rootfs/config --numeric-owner
fi

if [[ -f $BACKUP/qq-ai-data.tar.gz ]]; then
    PROJECT=$(compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' 2>/dev/null || basename "$(pwd)")
    VOL="${PROJECT}_qq-ai-data"
    if ! "${DOCKER_CMD[@]}" volume inspect "$VOL" >/dev/null 2>&1; then
        echo "卷 $VOL 不存在，创建"
        "${DOCKER_CMD[@]}" volume create "$VOL" >/dev/null
    fi
    # 清空不可逆，先把当前卷完整快照到 backups/：解压失败可整卷重来，
    # 误恢复也能从快照找回登录态。快照失败就拒绝继续。
    echo "== 快照当前登录卷到 backups/pre-restore-$TS-qq-ai-data.tar.gz =="
    "${DOCKER_CMD[@]}" run --rm -u 0 --entrypoint tar \
        -v "$VOL:/source:ro" -v "$PWD/backups:/target" \
        "$IMG" czf "/target/pre-restore-$TS-qq-ai-data.tar.gz" -C /source .
    [[ -s "backups/pre-restore-$TS-qq-ai-data.tar.gz" ]] || fail "登录卷快照失败，拒绝清空卷"
    echo "== 恢复 QQ 登录卷 $VOL（清空后解压；原件已快照） =="
    "${DOCKER_CMD[@]}" run --rm -u 0 --entrypoint sh \
        -v "$VOL:/dest" -v "$BACKUP:/backup:ro" \
        "$IMG" -c 'rm -rf /dest/* /dest/.[!.]* /dest/..?* ; exec tar xzf /backup/qq-ai-data.tar.gz -C /dest --numeric-owner'
else
    echo "备份里没有 QQ 登录卷，保持现状（恢复后可能需要重新扫码）"
fi

echo
echo "恢复完成。旧数据保留在 *.pre-restore-$TS；原登录卷快照：backups/pre-restore-$TS-qq-ai-data.tar.gz"
echo "后续步骤：ops/init-check.sh 校验，再 docker compose up -d 启动。"
echo "提示：若恢复到旧版本数据，请用与数据配对的镜像标签（当前 compose 标签 $TAG_OLD）。"
