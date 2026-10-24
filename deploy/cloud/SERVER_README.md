# 服务器部署速查（解包后从本目录开始）

本包是版本化交付：`VERSION.txt` 记录镜像标签、代码提交、平台与 CI 链接；`SHA256SUMS` 覆盖包内全部文件。运行约定详见仓库 `docs/CLOUD_RUNTIME.md`。本包不含任何真实凭证、账号或会话数据。

## 首次部署

```bash
# 1. 校验并加载镜像（确认 VERSION.txt 里 platform 与服务器架构一致）
sha256sum -c SHA256SUMS
docker load -i backend-image.tar.gz

# 2. 生成 NapCat 私人配置（已有配置则跳过；脚本拒绝覆盖，token 自己从文件里读）
python3 init-qq-config.py --directory ./config

# 3. 数据目录属主必须是容器用户 10001，否则 state.json 写不进去
#    （目录里的 keep 是占位文件，留着或删掉都行）
sudo chown -R 10001:10001 data

# 4.（可选）文件凭证模式：两把都放 secrets/，0400 或 0600，属主 10001
#    不启用则跳过——后端保持「凭证仅本次运行」，在面板里填。
sudo install -d -m 700 -o 10001 -g 10001 secrets
sudo install -m 400 -o 10001 -g 10001 /dev/null secrets/onebot-token
sudo install -m 400 -o 10001 -g 10001 /dev/null secrets/deepseek-key
#    用编辑器写入内容，不要用 echo 留 shell 历史。

# 5. 初始化检查（全部 PASS 才继续）
ops/init-check.sh

# 6. 启动。默认手动模式（后端默认停止，不会自动回复）：
docker compose -f docker-compose.yml up -d
#    启用了第 4 步则始终保留两个 -f：
docker compose -f docker-compose.yml -f docker-compose.credentials.yml up -d

# 7. 管理入口：SSH 隧道 + 私人日志里的控制地址（不要公开）
ssh -L 6099:127.0.0.1:6099 -L 3001:127.0.0.1:3001 -L <面板端口>:127.0.0.1:<面板端口> <server>
docker logs dafeiyu-backend 2>&1 | grep QQ_CONTROL_URL
```

面板里：保存连接配置 → 核对账号与白名单 → 由用户选择开始。关浏览器、断隧道不会停引擎。

## 日常运维（都在部署目录内运行）

| 目的 | 命令 |
| --- | --- |
| 状态（容器 / QQ 连接 / 资源快照） | `ops/status.sh` |
| 备份（含 QQ 登录卷，建议停服备份） | `ops/backup.sh --stop` |
| 只备配置与额度（升级前自动执行） | `ops/backup.sh --data-only` |
| 恢复（先 `docker compose stop`；清空登录卷前自动快照原件到 `backups/pre-restore-*`） | `ops/restore.sh backups/<目录>`（相对/绝对路径均可） |
| 升级（校验新包 → 备份 → 只重建后端） | `ops/upgrade.sh <新包目录>` |
| 回滚（回到最近一次升级前） | `ops/rollback.sh` |
| 初始化复查 | `ops/init-check.sh` |

升级/回滚只动后端镜像与 compose 标签；NapCat、QQ 登录卷、`data/`、`secrets/` 不受影响。数据格式若随版本变化，回滚后按提示用 `ops/restore.sh` 恢复配对的数据备份。

## 硬边界

- 3001、6099、控制面板端口不向公网开放，只走 SSH 隧道；不公开控制 URL 或 Token。
- 每次升级前自动备份；删除数据卷不作为排障手段。
- 备份含 QQ 登录态与聊天配置，离机保存需加密，不进 Git。
- 默认手动模式重启后不自动回复；只有授权运行且未过期才恢复。
