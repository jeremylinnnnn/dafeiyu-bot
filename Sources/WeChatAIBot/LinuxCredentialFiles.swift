#if os(Linux)
import Foundation
import Glibc

/// 只读文件凭证。
///
/// 设计前提：**默认行为不变**。`Keychain` 仍然是"仅本次运行"，只有当显式设置了
/// `DAFEIYU_ONEBOT_TOKEN_FILE` 与 `DAFEIYU_DEEPSEEK_KEY_FILE` 时才从文件加载。
/// 两个变量都没设就返回 nil，调用方沿用原来的手动流程。
///
/// 安全约束（都不可放宽）：
/// - 必须是普通文件，符号链接与目录一律拒绝；
/// - 属组与其他用户不得有任何权限位（即 0400 / 0600 这一族）；
/// - 属主必须是当前运行用户 —— 只设 0600 而属主不对，非 root 进程照样读不到；
/// - 内容不得写入日志、`state.json` 或镜像。
enum LinuxCredentialFile {
    static let oneBotEnvironmentKey = "DAFEIYU_ONEBOT_TOKEN_FILE"
    static let deepSeekEnvironmentKey = "DAFEIYU_DEEPSEEK_KEY_FILE"

    struct Pair {
        var oneBotToken: String
        var deepSeekKey: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 两个变量都没设 → nil（沿用仅本次运行的默认行为）。
    /// 只设了其中一个 → 报错，不猜、不静默降级。
    static func loadIfConfigured() throws -> Pair? {
        let environment = ProcessInfo.processInfo.environment
        let oneBotPath = (environment[oneBotEnvironmentKey] ?? "").trimmingCharacters(in: .whitespaces)
        let keyPath = (environment[deepSeekEnvironmentKey] ?? "").trimmingCharacters(in: .whitespaces)
        if oneBotPath.isEmpty, keyPath.isEmpty { return nil }
        guard !oneBotPath.isEmpty, !keyPath.isEmpty else {
            throw Failure(message: "\(oneBotEnvironmentKey) 与 \(deepSeekEnvironmentKey) 必须同时设置；只设一个会跳过自动连接")
        }
        return Pair(oneBotToken: try read(oneBotPath, label: oneBotEnvironmentKey),
                    deepSeekKey: try read(keyPath, label: deepSeekEnvironmentKey))
    }

    private static func read(_ path: String, label: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw Failure(message: "\(label)：无法访问 \(path)")
        }
        // 用八进制字面量而不是 S_IFMT / S_IFREG：这两个宏在 Swift 里是 Int32，
        // 与 Linux 上 `st_mode` 的 mode_t(UInt32) 直接按位与会触发类型不匹配。
        // 0o170000 = 文件类型掩码，0o100000 = 普通文件。
        guard info.st_mode & 0o170000 == 0o100000 else {
            throw Failure(message: "\(label)：必须是普通文件，不能是符号链接或目录")
        }
        let permissions = info.st_mode & 0o777
        guard permissions & 0o077 == 0 else {
            throw Failure(message: "\(label)：权限 \(String(permissions, radix: 8)) 过宽，需 chmod 600")
        }
        // 属主不对时，0600 也读不到。直接比对，比等到 open 失败更容易定位。
        guard info.st_uid == geteuid() else {
            throw Failure(message: "\(label)：属主 uid=\(info.st_uid) 与运行用户 uid=\(geteuid()) 不一致，需 chown")
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw Failure(message: "\(label)：无法打开 \(path)")
        }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.readToEnd() ?? Data() }
        catch { throw Failure(message: "\(label)：读取失败") }
        guard data.count <= 8192 else {
            throw Failure(message: "\(label)：内容超过 8 KiB，不像是凭证")
        }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw Failure(message: "\(label)：文件为空")
        }
        return text
    }
}
#endif
