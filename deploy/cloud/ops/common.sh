# 运维脚本共享辅助。ops/ 下的脚本先 cd 到部署根，再 source 本文件。
# 部署根 = 包解包目录（含 docker-compose.yml 与 data/）。

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "错误：$*" >&2; exit 1; }
warn() { echo "警告：$*" >&2; }

# docker 命令支持 "sudo docker" 形式：DOCKER="sudo docker" ops/status.sh
read -ra DOCKER_CMD <<< "${DOCKER:-docker}"
command -v "${DOCKER_CMD[0]}" >/dev/null 2>&1 || fail "找不到 docker（可尝试 DOCKER=\"sudo docker\" 运行）"

# 凭证模式判定：credentials 覆盖文件与两把钥匙都齐才算启用。
# 只有一把 = 半配置状态，直接报错，不许静默退回「仅本次运行」。
detect_compose_files() {
    COMPOSE_FILES=(-f docker-compose.yml)
    local override=docker-compose.credentials.yml
    [[ -f $override ]] || return 0
    local token=secrets/onebot-token key=secrets/deepseek-key
    local has_token=0 has_key=0
    path_exists "$token" && has_token=1
    path_exists "$key" && has_key=1
    if (( has_token && has_key )); then
        COMPOSE_FILES+=(-f "$override")
    elif (( has_token || has_key )); then
        fail "$override 存在，但 $token 与 $key 只有一把；请补齐或移除覆盖文件"
    fi
}

# 判断部署目录内路径是否存在。secrets/ 按手册是 0700、属主 UID 10001，
# 普通管理用户连 stat 都做不了；把「看不到」当成「不存在」会让凭证覆盖被
# 静默跳过、重启后退回临时凭证模式。因此：只有父目录对我们可遍历时才允许
# 直接判定；否则用免密 sudo 复判；sudo 也不可用就报错，绝不静默降级。
path_exists() {
    local p=$1 dir
    [[ -e $p ]] && return 0
    dir=$(dirname -- "$p")
    if [[ ! -e $dir || ( -r $dir && -x $dir ) ]]; then
        return 1
    fi
    if sudo -n test -e "$p" 2>/dev/null; then return 0; fi
    if sudo -n true 2>/dev/null; then return 1; fi
    fail "无法判断 $p 是否存在（目录不可读且免密 sudo 不可用）；请用 sudo 运行本脚本"
}

# 读取受限路径（如 0700 secrets/）的 stat 字段：%a 权限、%u 属主。
# 直接读与免密 sudo 都失败时返回空串，由调用方按「无法验证」处理。
stat_secret() {
    stat -c "$2" -- "$1" 2>/dev/null || sudo -n stat -c "$2" -- "$1" 2>/dev/null || true
}

compose() {
    "${DOCKER_CMD[@]}" compose "${COMPOSE_FILES[@]}" "$@"
}

# 当前部署 compose 里的后端标签（dafeiyu-backend:<tag>）
current_backend_tag() {
    awk '/image:[[:space:]]*dafeiyu-backend:/ {sub(/.*dafeiyu-backend:/, "", $0); print; exit}' docker-compose.yml
}

require_deploy_layout() {
    [[ -f docker-compose.yml ]] || fail "此处不是部署目录（缺 docker-compose.yml）；请在包解包目录内运行 ops/ 脚本"
    [[ -f qq-container-entrypoint.sh ]] || fail "缺 qq-container-entrypoint.sh，部署目录不完整"
    detect_compose_files
    [[ -n $(current_backend_tag) ]] || fail "docker-compose.yml 里找不到 dafeiyu-backend 镜像标签"
}

# 数据目录/配置目录里的文件属主是容器用户 10001、权限 0600，
# 普通用户读不了；涉及读取的步骤用只读根容器执行，避免要求宿主机 root。
img_tar() {
    local target="$1" src="$2" out="$3"
    "${DOCKER_CMD[@]}" run --rm -u 0 --entrypoint tar \
        -v "$target:/target" -v "$src:/source:ro" \
        "dafeiyu-backend:$(current_backend_tag)" czf "/target/$out" -C /source .
}
