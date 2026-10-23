#if os(Linux)
import Foundation

/// 运行意图的落盘表示。
///
/// **只记"用户是否授权运行"这一件事**，不记队列、不记消息、不记任务。
/// 断线前排队中的回复、生成任务、发送结果未知的消息一律不恢复——恢复后只处理
/// 新到达的消息。这是刻意的：重放旧队列会重复发言，而"发送结果未知"的消息
/// 重放等于重复打扰。
struct LinuxRunIntent: Codable {
    var enabled: Bool
    var singleReply: Bool
    var deadline: Date?
}

/// 与 `state.json` 放在同一个数据目录，但用独立文件，便于单独清理而不影响配置。
struct LinuxRunIntentStore {
    private static let fileName = "run-intent.json"

    static func directory() -> URL {
        if let path = ProcessInfo.processInfo.environment["DAFEIYU_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/dafeiyu", isDirectory: true)
    }

    private var url: URL { Self.directory().appendingPathComponent(Self.fileName) }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load() -> LinuxRunIntent {
        guard let data = try? Data(contentsOf: url),
              let intent = try? Self.decoder.decode(LinuxRunIntent.self, from: data) else {
            return LinuxRunIntent(enabled: false, singleReply: false, deadline: nil)
        }
        return intent
    }

    /// 返回是否成功落盘。调用方必须处理 false：撤销授权失败时，磁盘上的旧文件
    /// 可能还写着 `enabled=true`，重启后会误恢复。
    @discardableResult
    func save(_ intent: LinuxRunIntent) -> Bool {
        do {
            try FileManager.default.createDirectory(at: Self.directory(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Self.encoder.encode(intent).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            print("运行意图保存失败：\(error.localizedDescription)")
            // 撤销授权却写不进去时，绝不能把旧的 enabled=true 留在盘上。
            // 删掉它，让磁盘状态退回"未授权"（fail-closed）。
            if !intent.enabled {
                do {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    print("已删除旧的运行意图文件，重启后不会误恢复。")
                } catch {
                    print("严重：旧运行意图文件无法删除（\(error.localizedDescription)），重启后可能误恢复，请人工删除 \(url.path)")
                }
            }
            return false
        }
    }

    func clear() {
        save(LinuxRunIntent(enabled: false, singleReply: false, deadline: nil))
    }
}

/// 云端启动流程：文件凭证 → 核对账号 → 恢复已授权的运行状态。
///
/// 三条硬规则：
/// 1. 没显式设置凭证文件变量时什么都不做，保持"仅本次运行"的原有行为；
/// 2. 凭证缺失、为空、权限不对时**明确跳过自动连接**并打印原因，不静默降级；
/// 3. 只恢复"已授权运行"，不重放断线前的队列。
enum CloudStartup {
    @MainActor
    static func run(engine: QQEngine) async {
        let store = LinuxRunIntentStore()

        do {
            // 顺序要紧：先确认"确实配置了文件凭证"，再装钩子。
            // 否则没配置凭证的用户也会被写上 run-intent.json、也会开自动重连，
            // 那就不是"默认行为不变"了。
            guard let credentials = try LinuxCredentialFile.loadIfConfigured() else {
                print("未设置文件凭证，保持仅本次运行模式；请通过本机面板填写凭证。")
                return
            }
            engine.autoReconnectEnabled = true
            engine.onRunIntentChange = { [weak engine] in
                guard let engine else { return }
                let snapshot = engine.currentRunIntent
                let saved = store.save(LinuxRunIntent(enabled: snapshot.enabled,
                                                      singleReply: snapshot.singleReply,
                                                      deadline: snapshot.deadline))
                guard !saved else { return }
                // 写盘失败时不能只 print：面板上"已暂停"看起来是成功的，
                // 但磁盘上可能还留着 enabled=true，重启后会自己跑起来。
                if snapshot.enabled {
                    engine.reportRunIntentPersistenceFailure(
                        "已开始运行，但运行状态未能保存：重启后不会自动恢复，需要人工重新开始。")
                } else {
                    engine.reportRunIntentPersistenceFailure(
                        "已暂停，但停止状态未保存到磁盘：重启后可能恢复自动回复，需要人工处理（检查数据目录是否可写）。")
                }
            }
            guard engine.useTemporaryCredentials(token: credentials.oneBotToken, key: credentials.deepSeekKey) else {
                print("文件凭证未通过校验：\(engine.error ?? "未知原因")；已跳过自动连接。")
                return
            }
            let intent = store.load()
            guard intent.enabled else {
                print("文件凭证已就绪；运行意图为停止，等待人工开始。")
                return
            }
            if let deadline = intent.deadline, deadline.timeIntervalSinceNow <= 0 {
                print("运行意图已过期，不恢复自动回复。")
                store.clear()
                return
            }
            // 关键：先把"已授权运行"装回引擎，再连。
            // 否则 runRequested 一直是 false，首次连接失败会被重连入口直接拒掉——
            // 服务器上 NapCat 比后端慢几十秒起来，后端就永远等人来点。
            engine.restoreRunIntent(singleReply: intent.singleReply, deadline: intent.deadline)
            let generation = engine.runIntentGeneration
            await engine.connect()
            // 等待连接期间，用户可能在面板上暂停、或直接改主意：代次变了就不要再 start。
            guard engine.runIntentGeneration == generation, engine.currentRunIntent.enabled else {
                print("连接期间运行意图已变更，不再恢复自动回复。")
                return
            }
            guard engine.connected else {
                print("自动连接失败：\(engine.error ?? "未知原因")；面板仍可用，请人工检查。")
                return
            }
            engine.start(singleReply: intent.singleReply,
                         duration: intent.deadline.map { $0.timeIntervalSinceNow })
            print(engine.running ? "已按运行意图恢复自动回复。"
                                 : "已连接，但未能恢复自动回复：\(engine.error ?? "未知原因")")
        } catch {
            print("云端启动中止：\(error.localizedDescription)")
        }
    }
}
#endif
