import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import BotCore
@testable import WeChatAIBot
#if os(Linux)
import Glibc
#endif

/// 自动恢复状态机的回归测试。
///
/// 只碰合成 OneBot 服务（`onebot_fixture.py`）与临时目录：不连真实 QQ、不发消息、不调模型。
/// 这几条都是"用户以为已经关了，重启后却又自己跑起来"这一类事故的直接防线。
@Suite(.serialized) @MainActor struct QQRecoveryTests {
    private struct Fixture {
        let process: Process
        let port: Int
    }

    private func stopFixture(_ process: Process) {
        guard process.isRunning else { return }
        #if os(Linux)
        // Swift worker threads can pass a blocked SIGTERM to Python. A synchronous
        // wait after terminate() then blocks MainActor until the fixture's own
        // socket timeout, starving unrelated engine tests. This disposable child
        // has no persistent state; SIGKILL guarantees it can be promptly reaped.
        _ = Glibc.kill(process.processIdentifier, SIGKILL)
        #else
        process.terminate()
        #endif
        process.waitUntilExit()
    }

    private func startFixture(in directory: URL) throws -> Fixture {
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("onebot_fixture.py").path, directory.path]
        server.standardOutput = output
        try server.run()
        let raw = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            stopFixture(server)
            throw AppFailure.message("合成 OneBot 服务未报告端口")
        }
        return Fixture(process: server, port: port)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 端口延迟打开：第一次 connect() 必须真的失败，重连路径才有机会被走到。
    /// `handshakeDelay` 让握手也拖住，用来制造"connect() 正在等待时用户点了暂停"的窗口。
    private func startDelayedFixture(delay: Double, handshakeDelay: Double = 0) throws -> Fixture {
        let server = Process(), output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("onebot_fixture_delayed.py").path, String(delay), String(handshakeDelay)]
        server.standardOutput = output
        try server.run()
        let raw = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            stopFixture(server)
            throw AppFailure.message("延迟合成服务未报告端口")
        }
        return Fixture(process: server, port: port)
    }

    /// 起一个已经连上合成服务、并且正在运行的引擎。
    private func runningEngine() async throws -> (QQEngine, URL, Fixture) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try startFixture(in: directory)
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        engine.save(endpoint: "ws://127.0.0.1:\(fixture.port)", expectedSelfID: "12345")
        try #require(engine.useTemporaryCredentials(token: "synthetic-test-token", key: "synthetic-key"))
        await engine.connect()
        try #require(engine.connected, "\(engine.error ?? engine.status)")
        engine.add(try #require(engine.contacts.first { $0.number == "54321" }))
        engine.config.targets[0].enabled = true
        engine.start(duration: 60)
        try #require(engine.running, "\(engine.error ?? engine.status)")
        return (engine, directory, fixture)
    }

    private func cleanup(_ engine: QQEngine, _ directory: URL, _ fixture: Fixture) {
        engine.disconnect()
        stopFixture(fixture.process)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - P1：主动断开必须撤销授权

    @Test func userDisconnectRevokesRunAuthorisation() async throws {
        let (engine, directory, fixture) = try await runningEngine()
        defer { cleanup(engine, directory, fixture) }
        var changes = 0
        engine.onRunIntentChange = { changes += 1 }
        #expect(engine.currentRunIntent.enabled)

        // 面板"断开 QQ"走的就是这条：默认 kind = .intentional。
        engine.disconnect()

        #expect(!engine.currentRunIntent.enabled, "主动断开后仍保留授权，重启会把用户关掉的回复又拉起来")
        #expect(engine.pendingDeadline == nil)
        #expect(changes > 0, "撤销授权必须通知落盘")
        #expect(!engine.status.contains("秒后重连"))
    }

    @Test func networkDisconnectKeepsAuthorisation() async throws {
        let (engine, directory, fixture) = try await runningEngine()
        defer { cleanup(engine, directory, fixture) }

        engine.disconnect(reason: "合成网络中断", kind: .network)

        #expect(engine.currentRunIntent.enabled, "网络故障是被动断开，意图必须留着，否则自动恢复永远起不来")
        #expect(engine.pendingDeadline != nil)
    }

    // MARK: - P1：第二次网络失败不能把已存的截止时间覆盖成 nil

    @Test func secondNetworkFailureKeepsPreservedDeadline() async throws {
        let (engine, directory, fixture) = try await runningEngine()
        defer { cleanup(engine, directory, fixture) }
        let original = try #require(engine.currentRunIntent.deadline)

        engine.disconnect(reason: "第一次断线", kind: .network)
        let preserved = try #require(engine.pendingDeadline)
        #expect(abs(preserved.timeIntervalSince(original)) < 1)

        // 第二次断线时 runDeadline 已被第一次 pause 清成 nil。
        // 旧实现会拿这个 nil 覆盖掉上面存好的值，重连后就变成无限期运行。
        engine.disconnect(reason: "第二次断线", kind: .network)
        let stillThere = try #require(engine.pendingDeadline, "第二次断线把已保存的截止时间清掉了")
        #expect(abs(stillThere.timeIntervalSince(original)) < 1)
    }

    @Test func unlimitedRunStaysUnlimitedAfterReconnect() async throws {
        let (engine, directory, fixture) = try await runningEngine()
        defer { cleanup(engine, directory, fixture) }
        engine.pause()
        engine.start(duration: nil)
        try #require(engine.running)
        #expect(engine.currentRunIntent.deadline == nil)

        engine.disconnect(reason: "合成网络中断", kind: .network)
        // 无限期运行不该凭空多出一个截止时间。
        #expect(engine.pendingDeadline == nil)
    }

    // MARK: - P1：冷启动失败要能进入有限重连

    @Test func restoredIntentSurvivesFirstConnectFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        defer { engine.disconnect() }
        engine.autoReconnectEnabled = true
        // 云端冷启动的等价状态：NapCat 还没起来，先按磁盘上的授权装回意图。
        engine.restoreRunIntent(singleReply: false, deadline: nil)
        #expect(engine.currentRunIntent.enabled)

        engine.disconnect(reason: "QQ 连接检查失败", kind: .network)

        #expect(engine.status.contains("秒后重连"),
                "冷启动首次连接失败没有进入重连：服务器上 NapCat 慢几十秒，后端就会一直等人来点")
    }

    @Test func restoreRunIntentIsIgnoredWhenAlreadyRunning() async throws {
        let (engine, directory, fixture) = try await runningEngine()
        defer { cleanup(engine, directory, fixture) }

        engine.restoreRunIntent(singleReply: true, deadline: nil)

        // 已经在跑的时候不能被冷启动流程改掉单条模式或授权状态。
        #expect(engine.currentRunIntent.singleReply == false)
    }

    // MARK: - P1：连接期间被暂停，不能被随后的 start 覆盖

    @Test func pauseDuringPendingWorkInvalidatesGeneration() async throws {
        let (engine, directory, fixture) = try await runningEngine()
        defer { cleanup(engine, directory, fixture) }
        let generation = engine.runIntentGeneration

        engine.pause()

        // 异步流程（重连、冷启动）靠这个代次判断"await 期间有没有被人动过"。
        #expect(engine.runIntentGeneration != generation)
        #expect(!engine.currentRunIntent.enabled)
    }

    @Test func intentionalDisconnectCancelsPendingReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        defer { engine.disconnect() }
        engine.autoReconnectEnabled = true
        engine.restoreRunIntent(singleReply: false, deadline: nil)
        engine.disconnect(reason: "合成网络中断", kind: .network)
        #expect(engine.status.contains("秒后重连"))

        engine.disconnect()

        #expect(!engine.status.contains("秒后重连"), "主动断开后重连任务仍在，会在几秒后把连接拉起来")
        #expect(!engine.currentRunIntent.enabled)
    }

    // MARK: - 异步闭环：真的失败、真的重连、真的恢复

    @Test func fixtureCleanupDoesNotWaitForReadinessTimeout() throws {
        let fixture = try startDelayedFixture(delay: 30)
        defer { stopFixture(fixture.process) }
        let started = Date()
        stopFixture(fixture.process)
        #expect(Date().timeIntervalSince(started) < 5,
                "清理合成子进程不能等 30 秒启动超时，否则会阻塞 MainActor 和其他测试")
    }

    @Test func reconnectRecoversAfterServerStartsLate() async throws {
        let directory = try makeDirectory()
        let fixture = try startDelayedFixture(delay: 3)
        defer {
            stopFixture(fixture.process)
            try? FileManager.default.removeItem(at: directory)
        }
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        defer { engine.disconnect() }
        engine.save(endpoint: "ws://127.0.0.1:\(fixture.port)", expectedSelfID: "12345")
        try #require(engine.useTemporaryCredentials(token: "synthetic-test-token", key: "synthetic-key"))
        engine.add(QQContact(number: "54321", name: "late fixture", group: false))
        engine.config.targets[0].enabled = true
        engine.autoReconnectEnabled = true
        engine.restoreRunIntent(singleReply: false, deadline: Date().addingTimeInterval(300))

        // 端口还没打开：这一次 connect() 必须真的失败。
        await engine.connect()
        #expect(!engine.connected, "端口尚未打开，第一次连接应当失败")
        #expect(engine.status.contains("秒后重连"), "失败后没有进入重连：\(engine.status)")

        // 5 秒退避后服务已就绪，重连必须成功并真正恢复运行。
        let limit = Date().addingTimeInterval(25)
        while Date() < limit, !engine.running {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        #expect(engine.running, "服务晚启动后没有自动恢复：\(engine.status)")
        #expect(engine.connected)
        #expect(engine.currentRunIntent.enabled)
    }

    @Test func pauseDuringReconnectWaitStopsRecovery() async throws {
        let directory = try makeDirectory()
        // 30 秒后才开端口：退避窗口内用户点的暂停必须生效，不能等服务起来又自己跑。
        let fixture = try startDelayedFixture(delay: 30)
        defer {
            stopFixture(fixture.process)
            try? FileManager.default.removeItem(at: directory)
        }
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        defer { engine.disconnect() }
        engine.save(endpoint: "ws://127.0.0.1:\(fixture.port)", expectedSelfID: "12345")
        try #require(engine.useTemporaryCredentials(token: "synthetic-test-token", key: "synthetic-key"))
        engine.add(QQContact(number: "54321", name: "late fixture", group: false))
        engine.config.targets[0].enabled = true
        engine.autoReconnectEnabled = true
        engine.restoreRunIntent(singleReply: false, deadline: Date().addingTimeInterval(300))

        await engine.connect()
        #expect(!engine.connected)
        #expect(engine.status.contains("秒后重连"))

        engine.pause()   // 用户在等待重连时点了暂停
        // 跨过一次 5 秒退避：重连任务醒来后必须放弃，而不是把连接拉起来再 start()。
        try await Task.sleep(nanoseconds: 8_000_000_000)

        #expect(!engine.running, "暂停后仍然恢复了自动回复")
        #expect(!engine.connected, "暂停后重连任务仍把连接拉起来了")
        #expect(!engine.currentRunIntent.enabled)
    }

    @Test func pauseWhileConnectIsInFlightStopsRecovery() async throws {
        let directory = try makeDirectory()
        // 端口 1 秒后开（第一次连接必失败），握手再拖 6 秒（重连的 connect 会挂起）。
        let fixture = try startDelayedFixture(delay: 1, handshakeDelay: 6)
        defer {
            stopFixture(fixture.process)
            try? FileManager.default.removeItem(at: directory)
        }
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        defer { engine.disconnect() }
        engine.save(endpoint: "ws://127.0.0.1:\(fixture.port)", expectedSelfID: "12345")
        try #require(engine.useTemporaryCredentials(token: "synthetic-test-token", key: "synthetic-key"))
        engine.add(QQContact(number: "54321", name: "late fixture", group: false))
        engine.config.targets[0].enabled = true
        engine.autoReconnectEnabled = true
        engine.restoreRunIntent(singleReply: false, deadline: Date().addingTimeInterval(300))

        await engine.connect()
        #expect(!engine.connected)
        #expect(engine.status.contains("秒后重连"))

        // 5 秒退避 + 1 秒余量：此刻重连的 connect() 正卡在握手等待里。
        try await Task.sleep(nanoseconds: 7_000_000_000)
        engine.pause()

        // 握手在 6 秒后完成，connect() 会返回成功；此时绝不能接着 start()。
        try await Task.sleep(nanoseconds: 7_000_000_000)
        #expect(!engine.running, "握手期间点的暂停，被 connect() 返回后的 start() 覆盖了")
        #expect(!engine.currentRunIntent.enabled)
    }

    // MARK: - 连接失败要按原因分类

    @Test func accountMismatchIsNotTreatedAsNetworkFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try startFixture(in: directory)
        defer {
            stopFixture(fixture.process)
            try? FileManager.default.removeItem(at: directory)
        }
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        defer { engine.disconnect() }
        engine.autoReconnectEnabled = true
        // 期望账号与合成服务返回的 12345 不一致。
        engine.save(endpoint: "ws://127.0.0.1:\(fixture.port)", expectedSelfID: "99999")
        try #require(engine.useTemporaryCredentials(token: "synthetic-test-token", key: "synthetic-key"))
        engine.restoreRunIntent(singleReply: false, deadline: nil)

        await engine.connect()

        #expect(!engine.connected)
        #expect(!engine.status.contains("秒后重连"),
                "账号不一致属于凭证类故障，重连只会重复失败，不该进网络重试")
        #expect(engine.currentRunIntent.enabled, "被动失败不该撤销用户授权")
    }

    // MARK: - 落盘失败必须让人在面板上看得见

    @Test func persistenceFailureIsVisibleOnThePanel() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = QQEngine(allowAuthenticationUI: false, storageDirectory: directory)
        defer { engine.disconnect() }

        engine.reportRunIntentPersistenceFailure("已暂停，但停止状态未保存到磁盘：重启后可能恢复自动回复，需要人工处理。")

        // 只 print 到日志不算数：看面板的人必须知道"这一步没保住"。
        #expect(engine.error?.contains("未保存") == true, "面板错误位没有反映落盘失败")
        #expect(engine.status.contains("未保存"))
    }
}
