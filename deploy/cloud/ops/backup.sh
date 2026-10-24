#!/usr/bin/env bash
# 备份运行数据。输出到 backups/<label>-<UTC时间>/。
# 用法：ops/backup.sh [--stop] [--data-only] [--label <名称>]
#   --stop       备份 QQ 登录卷前先停整个栈（登录卷热备份可能不一致）
#   --data-only  只备 data/ 与配置，不碰 QQ 登录卷（升级脚本用）
# 默认不停服；QQ 登录卷建议停服备份。
#
# 备份不含 secrets/：凭证与运行数据是不同权限模型，
# 离机备份请单独处理并加密，不要和运行数据放在一起。
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
source ops/common.sh
require_deploy_layout

STOP=0; DATA_ONLY=0; LABEL=manual
while (( $# )); do
    case "$1" in
        --stop) STOP=1 ;;
        --data-only) DATA_ONLY=1 ;;
        --label) shift; LABEL=${1:?--label 需要名称} ;;
        *) fail "未知参数：$1" ;;
    esac
    shift
done

[[ $LABEL =~ ^[A-Za-z0-9._-]+$ ]] || fail "label 只允许字母数字._-"
IMG="dafeiyu-backend:$(current_backend_tag)"
TS=$(date -u +%Y%m%dT%H%M%SZ)
DEST="backups/$LABEL-$TS"
mkdir -p "$DEST"
chmod 700 "$DEST"

STACK_RUNNING=0
compose ps --status running -q 2>/dev/null | grep -q . && STACK_RUNNING=1

if (( STOP )); then
    echo "== 停止整个栈以备份 QQ 登录卷 =="
    compose stop
fi
# 只在备份前栈本来就在运行时才恢复启动
trap '(( STOP && STACK_RUNNING )) && compose start >/dev/null 2>&1 || true' EXIT

echo "== 备份 data/ =="
img_tar "$PWD/$DEST" "$PWD/data" data.tar.gz

if [[ -d config ]] && [[ -n $(ls -A config 2>/dev/null) ]]; then
    echo "== 备份 config/（NapCat 私有配置） =="
    img_tar "$PWD/$DEST" "$PWD/config" config.tar.gz
else
    echo "config/ 为空或不存在，跳过"
fi

if (( ! DATA_ONLY )); then
    PROJECT=$(compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' 2>/dev/null || basename "$(pwd)")
    VOL=""
    while IFS= read -r v; do
        VP=$("${DOCKER_CMD[@]}" volume inspect "$v" --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null || true)
        [[ $VP == "$PROJECT" && $v == *qq-ai-data ]] && VOL=$v
    done < <("${DOCKER_CMD[@]}" volume ls --format '{{.Name}}')
    if [[ -n $VOL ]]; then
        if (( STACK_RUNNING && ! STOP )); then
            warn "QQ 登录卷在运行中备份，可能不一致；重要备份请加 --stop"
        fi
        echo "== 备份 QQ 登录卷 $VOL =="
        "${DOCKER_CMD[@]}" run --rm -u 0 --entrypoint tar \
            -v "$VOL:/source:ro" -v "$PWD/$DEST:/target" \
            "$IMG" czf /target/qq-ai-data.tar.gz -C /source .
    else
        warn "未找到项目 $PROJECT 的 qq-ai-data 卷（NapCat 尚未运行过），跳过登录卷"
    fi
fi

echo "== 记录版本信息 =="
cp docker-compose.yml "$DEST/docker-compose.yml"
[[ -f VERSION.txt ]] && cp VERSION.txt "$DEST/VERSION.txt"
{
    echo "label=$LABEL"
    echo "utc=$TS"
    echo "backend_tag=$(current_backend_tag)"
    echo "stack_was_running=$STACK_RUNNING"
    echo "contains_qq_login_volume=$(( DATA_ONLY ? 0 : 1 ))"
    echo "注意：QQ 登录卷与 NapCat 配置属于敏感数据，离机保存需加密"
} > "$DEST/info.txt"

# 容器以 root 写文件，把备份属主交还给当前用户。
# 必须显式 --entrypoint chown：镜像入口是 /app/dafeiyu，漏掉会把机器人跑起来永不退出。
"${DOCKER_CMD[@]}" run --rm -u 0 --entrypoint chown -v "$PWD/$DEST:/t" "$IMG" \
    -R "$(id -u):$(id -g)" /t

# 备份含 QQ 登录数据：目录 0700，tar 一律 0600
chmod 700 "$DEST"
for t in "$DEST"/*.tar.gz; do
    [[ -e $t ]] && chmod 600 "$t"
done

echo "备份完成：$DEST"
ls -lh "$DEST"
