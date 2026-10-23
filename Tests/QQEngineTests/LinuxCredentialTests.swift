#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import WeChatAIBot

/// 只读文件凭证与运行意图的合成测试。
///
/// 这些用例只碰临时目录里的合成文件，不读真实凭证、不连 QQ、不发消息。
/// `.serialized` 是必须的：用例会改进程级环境变量，并行跑会互相踩。
@Suite(.serialized) struct LinuxCloudStartupTests {
    // MARK: - 夹具

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dafeiyu-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private func write(_ contents: String, to url: URL, mode: mode_t) throws {
        try Data(contents.utf8).write(to: url)
        #expect(chmod(url.path, mode) == 0)
    }

    /// 只设置列出的变量，其余一律清空；退出时恢复原值。
    private func withEnvironment(_ values: [String: String], _ body: () throws -> Void) rethrows {
        let keys = ["DAFEIYU_ONEBOT_TOKEN_FILE", "DAFEIYU_DEEPSEEK_KEY_FILE", "DAFEIYU_DATA_DIR"]
        let saved = keys.map { ($0, getenv($0).map { String(cString: $0) }) }
        defer {
            for (key, value) in saved {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for key in keys { unsetenv(key) }
        for (key, value) in values { setenv(key, value, 1) }
        try body()
    }

    private func expectFailure(_ contains: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("预期抛错但没有：\(contains)")
        } catch {
            #expect(error.localizedDescription.contains(contains), "实际错误：\(error.localizedDescription)")
        }
    }

    // MARK: - 默认行为不变

    @Test func neitherVariableSetKeepsSessionOnlyBehaviour() throws {
        try withEnvironment([:]) {
            let loaded = try LinuxCredentialFile.loadIfConfigured()
            #expect(loaded == nil)
        }
    }

    @Test func onlyOneVariableSetFailsLoudly() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = folder.appendingPathComponent("onebot-token")
        try write("synthetic-token", to: token, mode: 0o600)
        withEnvironment([LinuxCredentialFile.oneBotEnvironmentKey: token.path]) {
            expectFailure("必须同时设置") { _ = try LinuxCredentialFile.loadIfConfigured() }
        }
    }

    // MARK: - 正常读取

    @Test func readsBothFilesAndTrimsTrailingNewline() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = folder.appendingPathComponent("onebot-token")
        let key = folder.appendingPathComponent("deepseek-key")
        try write("synthetic-token\n", to: token, mode: 0o600)
        try write("  synthetic-key  \n", to: key, mode: 0o400)
        try withEnvironment([LinuxCredentialFile.oneBotEnvironmentKey: token.path,
                             LinuxCredentialFile.deepSeekEnvironmentKey: key.path]) {
            let loaded = try LinuxCredentialFile.loadIfConfigured()
            let pair = try #require(loaded)
            #expect(pair.oneBotToken == "synthetic-token")
            #expect(pair.deepSeekKey == "synthetic-key")
        }
    }

    // MARK: - 拒绝的四类文件

    @Test func rejectsGroupOrOtherReadableFile() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = folder.appendingPathComponent("onebot-token")
        let key = folder.appendingPathComponent("deepseek-key")
        try write("synthetic-token", to: token, mode: 0o644)
        try write("synthetic-key", to: key, mode: 0o600)
        withEnvironment([LinuxCredentialFile.oneBotEnvironmentKey: token.path,
                         LinuxCredentialFile.deepSeekEnvironmentKey: key.path]) {
            expectFailure("过宽") { _ = try LinuxCredentialFile.loadIfConfigured() }
        }
    }

    @Test func rejectsSymlink() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real-token")
        let link = folder.appendingPathComponent("onebot-token")
        let key = folder.appendingPathComponent("deepseek-key")
        try write("synthetic-token", to: real, mode: 0o600)
        try write("synthetic-key", to: key, mode: 0o600)
        #expect(symlink(real.path, link.path) == 0)
        withEnvironment([LinuxCredentialFile.oneBotEnvironmentKey: link.path,
                         LinuxCredentialFile.deepSeekEnvironmentKey: key.path]) {
            expectFailure("必须是普通文件") { _ = try LinuxCredentialFile.loadIfConfigured() }
        }
    }

    @Test func rejectsDirectory() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent("onebot-token")
        let key = folder.appendingPathComponent("deepseek-key")
        // 0700 是刻意的：先让权限检查通过，才验证到"类型"这一关。
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try write("synthetic-key", to: key, mode: 0o600)
        withEnvironment([LinuxCredentialFile.oneBotEnvironmentKey: directory.path,
                         LinuxCredentialFile.deepSeekEnvironmentKey: key.path]) {
            expectFailure("必须是普通文件") { _ = try LinuxCredentialFile.loadIfConfigured() }
        }
    }

    @Test func rejectsMissingEmptyAndOversizeFiles() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = folder.appendingPathComponent("onebot-token")
        let key = folder.appendingPathComponent("deepseek-key")
        try write("synthetic-key", to: key, mode: 0o600)

        withEnvironment([LinuxCredentialFile.oneBotEnvironmentKey: folder.appendingPathComponent("absent").path,
                         LinuxCredentialFile.deepSeekEnvironmentKey: key.path]) {
            expectFailure("无法访问") { _ = try LinuxCredentialFile.loadIfConfigured() }
        }

        try write("   \n", to: token, mode: 0o600)
        withEnvironment([LinuxCredentialFile.oneBotEnvironmentKey: token.path,
                         LinuxCredentialFile.deepSeekEnvironmentKey: key.path]) {
            expectFailure("文件为空") { _ = try LinuxCredentialFile.loadIfConfigured() }
        }

        try write(String(repeating: "x", count: 9000), to: token, mode: 0o600)
        withEnvironment([LinuxCredentialFile.oneBotEnvironmentKey: token.path,
                         LinuxCredentialFile.deepSeekEnvironmentKey: key.path]) {
            expectFailure("8 KiB") { _ = try LinuxCredentialFile.loadIfConfigured() }
        }
    }

    // MARK: - 运行意图落盘

    /// 只记"是否授权运行"，不记队列——这条边界必须由测试守住。
    private func withDataDirectory(_ path: String, _ body: () throws -> Void) rethrows {
        let saved = getenv("DAFEIYU_DATA_DIR").map { String(cString: $0) }
        defer { if let saved { setenv("DAFEIYU_DATA_DIR", saved, 1) } else { unsetenv("DAFEIYU_DATA_DIR") } }
        setenv("DAFEIYU_DATA_DIR", path, 1)
        try body()
    }

    @Test func missingFileMeansNotAuthorised() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        withDataDirectory(folder.path) {
            let intent = LinuxRunIntentStore().load()
            #expect(!intent.enabled && !intent.singleReply && intent.deadline == nil)
        }
    }

    @Test func roundTripWritesPrivateFile() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try withDataDirectory(folder.path) {
            let store = LinuxRunIntentStore()
            let deadline = Date(timeIntervalSince1970: 1_800_000_000)
            store.save(LinuxRunIntent(enabled: true, singleReply: true, deadline: deadline))
            let file = folder.appendingPathComponent("run-intent.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let loaded = store.load()
            #expect(loaded.enabled && loaded.singleReply)
            #expect(abs((loaded.deadline ?? .distantPast).timeIntervalSince(deadline)) < 1)
            // 落盘内容里不能有队列、消息或凭证字段。
            let raw = try String(contentsOf: file, encoding: .utf8)
            #expect(!raw.lowercased().contains("token") && !raw.lowercased().contains("key"))
            store.clear()
            #expect(!store.load().enabled)
        }
    }

    @Test func brokenFileFailsClosed() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not json".utf8).write(to: folder.appendingPathComponent("run-intent.json"))
        withDataDirectory(folder.path) {
            // 坏文件等同于"没授权"，绝不能因为解析失败就自己跑起来。
            #expect(!LinuxRunIntentStore().load().enabled)
        }
    }

    // MARK: - 撤销授权写盘失败时必须 fail-closed

    @Test func successfulSaveReportsTrue() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        withDataDirectory(folder.path) {
            #expect(LinuxRunIntentStore().save(LinuxRunIntent(enabled: true, singleReply: false, deadline: nil)))
        }
    }

    @Test func failedRevokeClearsStaleAuthorisation() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("run-intent.json")
        // 用同名目录占位：写一定失败，但删除能成功——正是"撤销授权写不进去"的形态。
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        withDataDirectory(folder.path) {
            let store = LinuxRunIntentStore()
            // 旧实现吞掉错误、返回 Void，调用方无从得知磁盘上还留着 enabled=true。
            #expect(!store.save(LinuxRunIntent(enabled: false, singleReply: false, deadline: nil)))
            // 写失败后必须把旧状态清掉，让磁盘退回"未授权"，而不是留着旧授权。
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func readOnlyDataDirectoryLeavesStaleAuthorisation() throws {
        // root 无视目录权限，这条只能在非 root 下验证（CI 容器是 root，会跳过）。
        guard geteuid() != 0 else { return }
        let folder = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        withDataDirectory(folder.path) {
            let store = LinuxRunIntentStore()
            #expect(store.save(LinuxRunIntent(enabled: true, singleReply: false, deadline: nil)))
            let file = folder.appendingPathComponent("run-intent.json")
            // 目录只读：写不进、也删不掉。
            #expect(chmod(folder.path, 0o500) == 0)
            #expect(!store.save(LinuxRunIntent(enabled: false, singleReply: false, deadline: nil)))
            // 诚实地承认失败：旧授权还在盘上，重启会恢复。
            // 这正是"面板必须显示停止状态未保存"的场景，不能标成已彻底修复。
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(store.load().enabled)
        }
    }
}
#endif
