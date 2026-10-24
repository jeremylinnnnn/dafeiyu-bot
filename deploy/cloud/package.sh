#!/usr/bin/env bash
# 组装版本化部署包：镜像压缩包 + 标签匹配的 Compose + 运维入口 + 清单与校验。
# 用法：
#   deploy/cloud/package.sh --image dafeiyu-backend:<tag> --out <目录> \
#       [--platform linux/amd64] [--commit <sha>] [--ci-url <url>] [--force]
# 交付 amd64 包用 --platform linux/amd64（CI 默认）；
# 本机演练可显式传 linux/arm64，产出的包只能用于合成演练，不得对外交付。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE=""; OUT=""; PLATFORM="linux/amd64"; COMMIT=""; CI_URL=""; FORCE=0
while (( $# )); do
    case "$1" in
        --image) shift; IMAGE=${1:?--image 需要镜像标签} ;;
        --out) shift; OUT=${1:?--out 需要目录} ;;
        --platform) shift; PLATFORM=${1:?--platform 需要平台} ;;
        --commit) shift; COMMIT=$1 ;;
        --ci-url) shift; CI_URL=$1 ;;
        --force) FORCE=1 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done
[[ $IMAGE == *:* ]] || { echo "--image 需要 name:tag 形式" >&2; exit 2; }
TAG=${IMAGE##*:}
[[ -n $OUT && $OUT != / ]] || { echo "--out 需要一个安全的目标目录" >&2; exit 2; }

# 与 ops/ 脚本一致：DOCKER="sudo docker" 可用
read -ra DOCKER_CMD <<< "${DOCKER:-docker}"
command -v "${DOCKER_CMD[0]}" >/dev/null 2>&1 || { echo "找不到 docker（可尝试 DOCKER=\"sudo docker\"）" >&2; exit 1; }
"${DOCKER_CMD[@]}" image inspect "$IMAGE" >/dev/null 2>&1 || { echo "镜像不存在：$IMAGE" >&2; exit 1; }
IMG_PLATFORM=$("${DOCKER_CMD[@]}" image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')
[[ $IMG_PLATFORM == "$PLATFORM" ]] || { echo "镜像平台 $IMG_PLATFORM 与期望 $PLATFORM 不一致，拒绝打包" >&2; exit 1; }
IMAGE_ID=$("${DOCKER_CMD[@]}" image inspect "$IMAGE" --format '{{.Id}}')

if [[ -e $OUT ]] && (( ! FORCE )); then
    [[ -d $OUT && -z $(ls -A "$OUT") ]] || { echo "输出目录 $OUT 非空（用 --force 覆盖）" >&2; exit 1; }
fi
rm -rf "$OUT"
mkdir -p "$OUT"

echo "== 导出镜像（docker save | gzip） =="
"${DOCKER_CMD[@]}" save "$IMAGE" | gzip > "$OUT/backend-image.tar.gz"

echo "== 复制部署文件并把后端标签固化为 $TAG =="
sed -E "s|(image:[[:space:]]*)dafeiyu-backend:[^[:space:]]+|\1dafeiyu-backend:$TAG|" \
    "$REPO_ROOT/deploy/cloud/docker-compose.yml" > "$OUT/docker-compose.yml"
grep -q "dafeiyu-backend:$TAG" "$OUT/docker-compose.yml" || { echo "compose 标签替换失败" >&2; exit 1; }
# NapCat 镜像摘要保持固定，不在打包时改动
grep -q "mlikiowa/napcat-docker@sha256:" "$OUT/docker-compose.yml" \
    || { echo "compose 里找不到固定的 NapCat 摘要" >&2; exit 1; }

cp "$REPO_ROOT/deploy/cloud/docker-compose.credentials.yml" "$OUT/"
cp "$REPO_ROOT/deploy/qq-container-entrypoint.sh" "$OUT/"
cp "$REPO_ROOT/scripts/init-qq-config.py" "$OUT/"
cp "$REPO_ROOT/deploy/cloud/SERVER_README.md" "$OUT/"
mkdir -p "$OUT/ops"
cp "$REPO_ROOT"/deploy/cloud/ops/*.sh "$OUT/ops/"
chmod +x "$OUT"/ops/*.sh "$OUT/qq-container-entrypoint.sh"

# 首次启动前 data/ 必须存在且属主为 10001，解包后即带空目录。
# 放占位文件：artifact 的 zip 不保留空目录，没文件这些目录会消失。
mkdir -p "$OUT/data" "$OUT/config" "$OUT/backups"
touch "$OUT/data/.gitkeep" "$OUT/config/.gitkeep" "$OUT/backups/.gitkeep"

echo "== 生成版本清单 =="
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    echo "package_image=dafeiyu-backend:$TAG"
    echo "image_id=$IMAGE_ID"
    echo "platform=$PLATFORM"
    echo "code_commit=${COMMIT:-未提供}"
    echo "ci_run_url=${CI_URL:-本地打包，无 CI 运行链接}"
    echo "created_utc=$CREATED"
    echo "napcat_digest=$(awk '/napcat-docker/ {print $2; exit}' "$OUT/docker-compose.yml")"
    echo
    echo "来源文件（仓库内路径）："
    echo "  deploy/cloud/docker-compose.yml        -> docker-compose.yml（仅 image 标签固化为交付标签）"
    echo "  deploy/cloud/docker-compose.credentials.yml -> docker-compose.credentials.yml"
    echo "  deploy/qq-container-entrypoint.sh      -> qq-container-entrypoint.sh"
    echo "  scripts/init-qq-config.py              -> init-qq-config.py"
    echo "  deploy/cloud/ops/*.sh                  -> ops/"
    echo "  deploy/cloud/SERVER_README.md          -> SERVER_README.md"
    echo
    echo "校验：sha256sum -c SHA256SUMS"
    echo "加载：docker load -i backend-image.tar.gz"
    echo "该包不含任何真实凭证、账号、群号或会话数据。"
} > "$OUT/VERSION.txt"

echo "== 生成 SHA256SUMS =="
# 自检不得在清单生成后往包里写文件（上一版的 py_compile 就这样把
# __pycache__ 带进了交付包，且不在 SHA256SUMS 里）。语法检查用 ast.parse。
rm -rf "$OUT/__pycache__"
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum > SHA256SUMS )

echo "== 包内自检 =="
( cd "$OUT" && for sh in ops/*.sh qq-container-entrypoint.sh; do bash -n "$sh"; done )
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$OUT/init-qq-config.py"
( cd "$OUT" && "${DOCKER_CMD[@]}" compose -f docker-compose.yml config --quiet )
# compose 引用的文件必须都在包内
( cd "$OUT" && for f in qq-container-entrypoint.sh docker-compose.credentials.yml; do
    [[ -f $f ]] || { echo "包内缺 $f" >&2; exit 1; }
done )

echo
echo "打包完成：$OUT"
du -sh "$OUT" "$OUT/backend-image.tar.gz"
head -4 "$OUT/SHA256SUMS"
