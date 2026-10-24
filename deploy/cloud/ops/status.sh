#!/usr/bin/env bash
# 状态检查：容器、QQ 连接、资源概况。只读操作。
# 面板令牌只用于本机查询 /api/status，绝不回显控制 URL。
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
source ops/common.sh
require_deploy_layout

echo "==== Compose 服务 ===="
compose ps

for name in dafeiyu-backend dafeiyu-napcat; do
    echo
    echo "==== $name ===="
    if ! "${DOCKER_CMD[@]}" inspect "$name" >/dev/null 2>&1; then
        echo "容器不存在"
        continue
    fi
    "${DOCKER_CMD[@]}" inspect "$name" \
        --format '镜像: {{.Config.Image}}
启动: {{.State.StartedAt}}
状态: {{.State.Status}}（重启 {{.RestartCount}} 次）'
done

echo
echo "==== QQ 连接状态（来自面板，URL 不回显） ===="
PANEL_URL="$("${DOCKER_CMD[@]}" logs dafeiyu-backend 2>&1 | sed -n 's/^QQ_CONTROL_URL=//p' | tail -1)"
if [[ -z $PANEL_URL ]]; then
    echo "日志里没有 QQ_CONTROL_URL（后端未运行或未打印）"
else
    PORT=$(echo "$PANEL_URL" | sed -E 's|.*:([0-9]+)/.*|\1|')
    TOKEN=$(echo "$PANEL_URL" | sed -n 's/.*#//p')
    STATE=$(curl -sf -H "x-qq-control: $TOKEN" -H "origin: http://127.0.0.1:$PORT" \
        "http://127.0.0.1:$PORT/api/status" 2>/dev/null || true)
    if [[ -n $STATE ]]; then
        echo "$STATE" | python3 -c 'import json,sys; s=json.load(sys.stdin); print("connected:", s.get("connected"), " running:", s.get("running")); print("status:", s.get("status"))' 2>/dev/null \
            || echo "面板返回无法解析（详见面板）"
    else
        echo "面板不可达（后端可能刚重启，稍后重试）"
    fi
fi

echo
echo "==== 资源快照（单次采样，不是峰值） ===="
"${DOCKER_CMD[@]}" stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' \
    dafeiyu-backend dafeiyu-napcat 2>/dev/null || true
df -h . | awk 'NR==1 || NR==2'

echo
echo "==== 后端最近日志（已滤除控制 URL 行） ===="
"${DOCKER_CMD[@]}" logs dafeiyu-backend --tail 40 2>&1 | grep -v '^QQ_CONTROL_URL=' | tail -15 || true
