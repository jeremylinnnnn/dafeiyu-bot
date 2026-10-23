# Linux 云端运行与验证

Linux 后端与 QQ/NapCat 都运行在 Linux 主机，浏览器和 SSH 隧道只用于管理。
核心回复逻辑继续与 macOS 共享；文件凭证与自动恢复必须显式启用。

## 构建

在原生 amd64 Linux 上执行：

```bash
docker build --platform linux/amd64 \
  -f deploy/cloud/Dockerfile.backend -t dafeiyu-backend:0.1.0 .
docker image inspect dafeiyu-backend:0.1.0 --format '{{.Os}}/{{.Architecture}}'
```

结果应为 `linux/amd64`。ARM64 Linux 可以原生验证 Linux 行为，但原生产物是
`linux/arm64`。跨架构模拟也是可选方式；GitHub Actions 使用原生 amd64 runner
构建并运行合成容器验证，避免模拟编译的额外开销。

## 数据与凭证

部署目录包含 Compose 文件、QQ entrypoint 脚本、私人 NapCat 配置目录及持久数据：

- `data/`：绑定到后端 `/data`，由 `DAFEIYU_DATA_DIR` 指定，保存配置、记忆、
  调用/发送额度及运行意图。宿主目录应属于容器 UID 10001，并允许该用户写入。
- QQ 登录数据使用命名卷 `qq-ai-data`；备份时分别保存登录卷和后端数据。
- API Key 和 OneBot token 不在状态 JSON、镜像或仓库中。默认仍由面板提供临时凭证。
- 选择云端文件凭证时，使用独立的 `secrets/onebot-token`、`secrets/deepseek-key`，
  文件属主为 UID 10001，权限为 `0400` 或 `0600`，包含对应的一行凭证。
  父目录也应限制访问。容器只读挂载；文件缺失、为空、权限或属主不符时拒绝自动连接。

默认手动模式：

```bash
docker compose -f docker-compose.yml up -d
```

显式启用文件凭证和按授权恢复：

```bash
docker compose -f docker-compose.yml -f docker-compose.credentials.yml up -d
```

文件凭证模式下，后续启停、升级也必须保留两个 `-f` 参数。首次启动没有运行授权时，
仍需在面板保存连接配置、核对账号和会话、由用户选择开始。关闭面板或 SSH 隧道不会暂停引擎。

手动暂停或断开会撤销运行授权；网络故障可以有限重连，只处理新消息，不能重放旧队列。
截止时间应跨断线和重建保留。账号或存储错误需要人工处理。
停止授权写盘失败时，面板显示残余风险；如果旧授权文件也无法删除，必须先修复存储并
人工撤销旧授权，不能假定后续重启会保持停止。

控制面板目前仍使用随机回环端口，入口从私人容器日志读取。不要公开控制 URL 或 Token。
3001、6099 和控制面板端口不向公网开放，通过 SSH 隧道访问。

## 合成验证

```bash
bash scripts/test.sh
bash scripts/build-linux.sh
python3 scripts/verify-cloud-container.py \
  --image dafeiyu-backend:0.1.0 --workdir /tmp/dafeiyu-cloud-synthetic
```

如果 Docker 需要 sudo，可设置 `DOCKER="sudo docker"`。验证需要 Python 3；
测试使用动态本机端口、独立数据目录、带合成测试标签的容器和假凭证，不使用真实 QQ。
非空工作目录必须有本脚本的标记文件，脚本不会清理未标记的目录或其他容器。

容器验证覆盖运行 UID、只读凭证挂载、初始停止、配置保存、授权落盘、删除并重建后恢复、
网络断开和恢复、手动暂停后重建仍停止、过宽权限与错误属主拒绝。
它不发送真实消息，不验证实际 QQ 登录、模型回复质量、服务器重启或 Mac 关机后的可用性。
上述真实验收需另行由用户触发并记录实际结果。

## 更新

普通人设、范围、额度等设置通过面板暂停、修改、保存、再开始，无需重建镜像。
修改代码后构建独立版本标签，备份状态与登录数据，再只替换后端：

```bash
docker compose -f docker-compose.yml -f docker-compose.credentials.yml \
  up -d --no-deps --force-recreate backend
```

此命令假定 Compose 中已选好新镜像标签。更新前保留旧镜像和兼容的数据备份。
更换凭证文件后也重新创建后端，保证原子替换的文件重新挂载生效。
不要用删除数据卷的方式升级或排查登录问题。
