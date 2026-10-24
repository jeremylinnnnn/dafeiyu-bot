# 云端运行验证记录

更新日期：2026-10-24。最新交付代码：`062b0a576787bcce3ec8b67849c1fc232e5c0058`。原始引擎验证基线：`a7a4fb3775901f63d1110a44f0ef7ff5aed3823f`。
部署与维护说明见 [CLOUD_RUNTIME.md](CLOUD_RUNTIME.md)。

## 全量失败的原因

原始提交 `282f7d0`、失败版本和修复版本均使用同一 Linux ARM64 虚拟机、
同一 `swift:6.1.3-noble` 镜像、Python 3/Pillow、相同容器资源上限。

诊断只在源码临时副本增加清理耗时与子进程信号屏蔽记录：
`QQRecoveryTests` 的延迟服务清理在 MainActor 上同步等待了 **52.036 秒**。
该 Python 子进程的 `SigBlk` 为 `fffffffe3bfbea27`，包含 SIGTERM。
因此 `Process.terminate()` 未能及时结束子进程，`waitUntilExit()` 占住 MainActor，
其他引擎测试的计时窗口被耗尽。`await Task.sleep` 本身会让出执行器。
此次失败没有证明共享模型静态状态被改写，也没有证据要求继续扩容。

最小修复：仅对本套件自己创建、没有持久状态的 Linux 合成服务使用 SIGKILL，
随后回收子进程；保留原断言、默认并发和全部套件。新增测试直接约束清理耗时。

## 本机对照

| 对照 | 结果 |
| --- | --- |
| 原始提交 Linux 全量 | 157 项通过，45.535 秒 |
| 当前性格回复流水线单独运行（含全部参数） | 通过，29.990 秒 |
| 当前生成取消/队列测试单独运行（含全部参数） | 通过，35.013 秒 |
| 修复前诊断全量 | 183 项中出现 8 个失败断言，96.250 秒；记录到上述 52 秒清理阻塞 |
| 修复后 Linux 全量，第 1 次 | 184 项通过，46.139 秒 |
| 临时回退清理修复的反向验证 | 新增清理测试实际启动后未完成，20 秒外部限时退出 124；随后自动还原源码 |
| 修复后 Linux 完整测试脚本，第 2 次 | 184 项通过，47.591 秒；含存储保留脚本检查 |
| macOS 完整测试脚本 | 96 项引擎测试和 74 项核心测试通过 |
| macOS 发布构建及签名检查 | 通过，在独立临时源码副本打包 |
| 已提交文件隐私检查 | 代码提交时 150 个文件，findings=0；本记录另经提交前检查 |

## 镜像与 CI

ARM64 最终发布镜像 `dafeiyu-backend:verified-a7a4fb3` 构建通过，架构确认 `linux/arm64`，合成容器验证 **19 项全通过**。原生 amd64 CI 使用同一提交，也完成相同的 **19 项检查**。

- [原生 amd64 镜像构建及合成容器验证](https://github.com/jeremylinnnnn/dafeiyu-bot/actions/runs/39933232029)：通过（最终镜像确认 `linux/amd64`，19 项容器检查全通过）。
- [原生 amd64 Linux 全量及发布/传输验证](https://github.com/jeremylinnnnn/dafeiyu-bot/actions/runs/39933231954)：通过（完整测试、Linux 图片边界、release 构建、HTTP 控制面板和合成 WebSocket 传输）。
- [macOS CI](https://github.com/jeremylinnnnn/dafeiyu-bot/actions/runs/39933231967)：通过。

## 历史部署包验收（2026-10-24，`912c389`，已被后续修复替代）

提交 `912c389` 的 [amd64 工作流](https://github.com/jeremylinnnnn/dafeiyu-bot/actions/runs/40066223287) 全绿：构建、平台确认、19 项容器验收、版本化打包、tar load 证明、包级演练（加载、升级保留 data/、暂停不被覆盖、回滚、恢复含登录卷快照）。本机 lima（arm64 演练包）同一脚本 A–F 全部通过，含资源隔离与权限断言。

对**实际下载的 artifact** `dafeiyu-deploy-912c389a7382a87ba7320504e43ae09063b74192` 的验收：

- `sha256sum -c SHA256SUMS`：17 项全部 OK；
- `docker load -i backend-image.tar.gz`：成功（`Loaded image: dafeiyu-backend:912c389`）；
- 镜像平台确认 `linux/amd64`；
- `data/ config/ backups/` 经占位文件 `keep` 保留（upload-artifact v4 默认丢弃隐藏文件与空目录），包内无清单外残留。

第 18 轮补强的两项演练保证（本机 A–F 断言 + CI 同脚本）：

- **资源隔离**：演练副本的 Compose 项目名改写为随机后缀（`dafeiyu-rehearsal-*`），登录卷名不再解析为固定的 `dafeiyu_qq-ai-data`；清理只删除属本次演练项目的卷（按项目标签/前缀判定），绝不触碰生产卷。
- **备份权限**：备份目录 0700、含 QQ 登录数据的 tar 一律 0600（快照以 `umask 077` 创建，无 0644 窗口），演练中逐项断言。

边界：以上全部为合成验证，不调用真实模型、不发送真实 QQ 消息；服务器上的真实部署与 T1–T4 尚未开始。

## 最新部署包与运维回归验收（2026-10-24，`062b0a5`）

[amd64 工作流 40068467766](https://github.com/jeremylinnnnn/dafeiyu-bot/actions/runs/40068467766) 实际成功：四项运维回归、原生镜像构建、19 项容器检查、打包、镜像加载、交付 tar 归档与解包、对解包副本执行 A–F、artifact 上传。另有 [Linux CI](https://github.com/jeremylinnnnn/dafeiyu-bot/actions/runs/40068467804) 与 [macOS CI](https://github.com/jeremylinnnnn/dafeiyu-bot/actions/runs/40068467765)，状态以各运行记录为准，不由镜像工作流代替。

本轮没有修改 Swift 引擎，修复的是部署脚本的四个实证问题：

- 停服备份只恢复原先正在运行的服务，不会启动先前人工停止的后端；服务恢复失败返回失败状态。
- 回滚在读取备份数据前停止后端，避免把热备份当作一致快照。
- 同一秒同一标签的备份使用独立随机目录，旧备份不被覆盖。
- 演练子进程不继承宿主 COMPOSE_PROJECT_NAME；第一次启动前核对有效项目名，清卷同时核对随机前缀和项目标签。

`python3 scripts/test-cloud-ops.py` 在 macOS 和 Linux 上四项通过。临时副本切回旧部署脚本后，四项均按预期断言失败（0 个测试错误），不修改工作树。真实 Linux ARM64 演练使用保留镜像重新打包，归档并解包后在故意设置外部项目名、DOCKER="sudo docker" 的环境下 A–F 全通过；清理后只剩原始 qq-ai-data 卷。测试不读取该原始卷内容。

本机 `bash scripts/test.sh`：引擎 96 项（46.681 秒）与核心 74 项通过；`bash scripts/build.sh` 发布构建和签名检查通过。

对 Actions **实际下载**的交付产物进行了以下验收：

- artifact 内是 `.tar` 和 `.tar.sha256`，外层校验通过；tar 封装保留执行权限，避免 artifact ZIP 抹掉执行位。
- 解包后的 `SHA256SUMS` 17 项全部通过，无清单外文件，三个骨架目录均存在。
- `ops/` 下全部脚本及 QQ entrypoint 解包后有执行权限，不靠事后 chmod 修补。
- 在 ARM64 VM 中实际 `docker load` 成功，镜像为 `dafeiyu-backend:062b0a5`，inspect 为 `linux/amd64`；只加载和检查，不在 ARM64 上运行该镜像。

最后核对中，CI 清单的 image_id 为 OCI 配置摘要，VM 的 Docker inspect.Id 为 OCI manifest 摘要，两者不是同一层级。已校验归档中两份元数据的 SHA256，并确认加载镜像的 manifest.config.digest 等于清单记录的配置摘要，且配置平台为 linux/amd64；不是镜像内容不一致。跨 Docker 存储后端不要盲目比较不同层级的 ID。

本轮限于合成验证；真实 QQ、模型、云端重启和 Mac 关机验收仍待服务器采购后执行。

## 验证边界

合成容器验证使用动态回环端口、独立标记目录、独立容器、假凭证和合成联系人。
包括配置与授权保存、重建恢复、服务断开后恢复、手动暂停后重建仍保持停止、
凭证只读挂载、错误权限与属主拒绝。它不调用真实模型，不发送真实 QQ 消息。

没有购买云服务器，没有验证真实 QQ/NapCat 的平台登录恢复、真实模型回复、
服务器重启或 Mac 关机后手机触发回复。现有 QQ 数据与登录卷未用于这些测试；
UTM 实验虚拟机没有参与。
