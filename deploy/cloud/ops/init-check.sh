#!/usr/bin/env bash
# 初始化检查：在部署目录内运行，逐项确认环境与目录就绪。
# 用法：ops/init-check.sh
# 任何 FAIL 都以非零退出；WARN 只提示。不修改任何文件。
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
source ops/common.sh

PASS=0; WARN=0; FAIL=0
ok()   { echo "PASS  $*"; PASS=$((PASS+1)); }
warn_(){ echo "WARN  $*"; WARN=$((WARN+1)); }
bad()  { echo "FAIL  $*"; FAIL=$((FAIL+1)); }

echo "==== 部署目录：$(pwd) ===="

# --- 基础工具 ---
"${DOCKER_CMD[@]}" version --format '{{.Server.Version}}' >/dev/null 2>&1 \
    && ok "docker 可用（server $("${DOCKER_CMD[@]}" version --format '{{.Server.Version}}' 2>/dev/null)）" \
    || bad "docker 不可用"
if "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
    ok "docker compose v2 可用（$("${DOCKER_CMD[@]}" compose version --short 2>/dev/null)）"
else
    bad "缺 docker compose v2 插件"
fi

# --- 部署目录结构 ---
for f in docker-compose.yml docker-compose.credentials.yml qq-container-entrypoint.sh init-qq-config.py ops/init-check.sh; do
    [[ -f $f ]] && ok "存在 $f" || bad "缺 $f"
done
for d in data config backups; do
    if [[ -d $d ]]; then ok "存在目录 $d/"; else warn_ "缺目录 $d/（mkdir -p $d 后重跑）"; fi
done

require_deploy_layout || true
TAG="$(current_backend_tag 2>/dev/null || true)"
if [[ -n $TAG ]]; then ok "compose 后端标签 dafeiyu-backend:$TAG"; else bad "compose 里没有 dafeiyu-backend 标签"; fi

# --- compose 可解析 ---
if [[ -n $TAG ]] && compose config --quiet 2>/dev/null; then
    ok "docker compose config 解析通过"
else
    bad "docker compose config 解析失败"
fi

# --- 镜像已加载且平台与本机一致 ---
case "$(uname -m)" in
    x86_64) HOST_PLATFORM="linux/amd64" ;;
    aarch64|arm64) HOST_PLATFORM="linux/arm64" ;;
    *) HOST_PLATFORM="unknown/$(uname -m)" ;;
esac
if [[ -n $TAG ]]; then
    if IMG_PLATFORM="$("${DOCKER_CMD[@]}" image inspect "dafeiyu-backend:$TAG" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null)"; then
        if [[ $IMG_PLATFORM == "$HOST_PLATFORM" ]]; then
            ok "镜像平台 $IMG_PLATFORM 与主机 $(uname -m) 一致"
        else
            bad "镜像平台 $IMG_PLATFORM 与主机 $HOST_PLATFORM 不一致（下载了错误架构的包）"
        fi
    else
        bad "镜像 dafeiyu-backend:$TAG 未加载（先 docker load -i backend-image.tar.gz）"
    fi
fi

# --- 磁盘与内存 ---
AVAIL_MB=$(df -Pm . | awk 'NR==2 {print $4}')
if (( AVAIL_MB >= 20000 )); then ok "磁盘可用 ${AVAIL_MB}MB（≥20GB）"
elif (( AVAIL_MB >= 10000 )); then warn_ "磁盘可用 ${AVAIL_MB}MB（建议 ≥20GB）"
else bad "磁盘可用 ${AVAIL_MB}MB，不足以容纳镜像与数据"; fi

if [[ -r /proc/meminfo ]]; then
    AVAIL_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
    if (( AVAIL_GB >= 3 )); then ok "可用内存约 ${AVAIL_GB}GB"
    else bad "可用内存约 ${AVAIL_GB}GB（<3GB，OOM 风险高）"; fi
else
    warn_ "读不到 /proc/meminfo，跳过内存检查"
fi

# --- data/ 属主：容器以 UID 10001 运行，目录必须对它可写 ---
if [[ -d data ]]; then
    OWNER=$(stat -c %u data 2>/dev/null || echo "?")
    if [[ $OWNER == 10001 ]]; then ok "data/ 属主为 UID 10001"
    else bad "data/ 属主是 UID $OWNER，应为 10001（sudo chown -R 10001:10001 data）"; fi
fi

# --- 凭证（可选模式）：要么不启用，要么两把齐全且权限/属主正确 ---
# secrets/ 可能是 0700、属主 10001，普通用户读不到；用 path_exists/stat_secret 判定，
# 读不到状态按 FAIL 处理，绝不把「读不到」当成「配置正确」。
if path_exists secrets/onebot-token || path_exists secrets/deepseek-key; then
    for f in secrets/onebot-token secrets/deepseek-key; do
        if ! path_exists "$f"; then bad "缺 $f（两把必须成对提供）"; continue; fi
        MODE=$(stat_secret "$f" %a); OWNER=$(stat_secret "$f" %u)
        if [[ -z $MODE || -z $OWNER ]]; then
            bad "$f 无法读取权限/属主（0700 目录且免密 sudo 不可用？）；请用 sudo 重跑本检查"
            continue
        fi
        if [[ $MODE == 400 || $MODE == 600 ]]; then ok "$f 权限 $MODE"
        else bad "$f 权限 $MODE 过宽，需 0400 或 0600（sudo chmod $f）"; fi
        if [[ $OWNER == 10001 ]]; then ok "$f 属主 UID 10001"
        else bad "$f 属主 UID $OWNER，应为 10001（sudo chown 10001:10001 $f）"; fi
    done
else
    ok "未启用文件凭证模式（默认：面板临时凭证，仅本次运行）"
fi

# --- NapCat 私人配置 ---
for f in config/onebot11.json config/webui.json config/napcat.json; do
    [[ -f $f ]] && ok "存在 $f" || warn_ "缺 $f（首次部署先跑：python3 init-qq-config.py --directory ./config）"
done

# --- 管理端口必须只听回环 ---
if command -v ss >/dev/null 2>&1; then
    LEAK=$(ss -tln 2>/dev/null | awk '$1=="LISTEN" && ($4 ~ /:(3001|6099)$/) && $4 !~ /^127\.0\.0\.1:/ {print $4}')
    if [[ -z $LEAK ]]; then ok "3001/6099 无非回环监听"
    else bad "以下端口在非回环地址监听：$LEAK"; fi
else
    warn_ "无 ss 命令，跳过端口检查"
fi

echo
echo "汇总：$PASS 通过，$WARN 警告，$FAIL 失败"
(( FAIL == 0 )) || exit 1
