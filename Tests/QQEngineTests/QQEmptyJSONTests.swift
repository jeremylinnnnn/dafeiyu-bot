import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import BotCore
@testable import WeChatAIBot

private final class EmptyJSONProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var mode = ""
    private static var bodies: [[String: Any]] = []
    static func configure(_ value: String) { lock.lock(); defer { lock.unlock() }; mode = value; bodies = [] }
    static var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }
                data.append(contentsOf: buffer.prefix(n))
            }
        }
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        Self.lock.lock(); let mode = Self.mode, index = Self.bodies.count; Self.bodies.append(body); Self.lock.unlock()
        var status = 200, finish = "stop"
        var message: [String: Any] = ["content": "{\"text\":\"最终核对后的回复。\",\"emotion\":\"neutral\",\"intensity\":1}"]
        if mode == "tool", index == 0 {
            finish = "tool_calls"
            message = ["content": NSNull(), "reasoning_content": "private-tool-reasoning",
                       "tool_calls": [["id": "synthetic-call", "type": "function", "function": ["name": "search_web", "arguments": "{\"query\":\"fixture\"}"]]]]
        } else if mode == "review", index == 0 {
            message = ["content": "{\"text\":\"尚未核对的草稿。\",\"emotion\":\"neutral\",\"intensity\":1}"]
        } else if index == ((mode == "tool" || mode == "review") ? 1 : 0) || mode == "alwaysEmpty" {
            message = ["content": mode == "whitespace" ? " \n\t" : NSNull(), "reasoning_content": "private-empty-reasoning"]
            if mode == "length" { finish = "length" }
            if mode == "filtered" { finish = "content_filter" }
            if mode == "emptyWithTools" { message["tool_calls"] = [["id": "unexpected", "type": "function", "function": ["name": "search_web", "arguments": "{}"]]] }
        } else if mode == "rateLimit", index == 1 {
            status = 429
        } else if mode == "invalidFallback" {
            message = ["content": "invalid plain text"]
        }
        let response: [String: Any] = ["choices": [["message": message, "finish_reason": finish]], "usage": ["total_tokens": 7]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor EmptyReservations {
    var value = 0
    func add() -> Int { value += 1; return value }
}

@Suite(.serialized) @MainActor struct QQEmptyJSONTests {
    private func session(_ mode: String) -> URLSession {
        EmptyJSONProtocol.configure(mode)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [EmptyJSONProtocol.self]
        return URLSession(configuration: config)
    }
    @Test(arguments: ["null", "whitespace", "rateLimit"])
    func recoversOnceWithoutJSONModePreservingInputAndAccounting(_ mode: String) async throws {
        let session = session(mode); defer { session.invalidateAndCancel() }
        let reservations = EmptyReservations()
        let result = try await DeepSeekClient(session: session).reply(key: "synthetic", config: QQConfig().ai,
            rule: ChatRule(name: "fixture", prompt: "Original personality and JSON rules"),
            history: [ChatTurn(incoming: "synthetic earlier input", outgoing: "synthetic earlier reply")],
            text: "synthetic current input", jsonOutput: true, thinkingEnabled: true, images: [Data([1, 2, 3])], reserve: { _ = await reservations.add() })
        let requests = EmptyJSONProtocol.requests
        let expected = mode == "rateLimit" ? 3 : 2
        #expect(await reservations.value == expected)
        #expect(requests.count == expected)
        #expect(requests[0]["response_format"] != nil)
        #expect(requests.dropFirst().allSatisfy { $0["response_format"] == nil && $0["tools"] == nil })
        let originalMessages = requests[0]["messages"] as! [[String: Any]]
        let recoveredMessages = requests[1]["messages"] as! [[String: Any]]
        #expect(NSDictionary(dictionary: ["messages": originalMessages]) == NSDictionary(dictionary: ["messages": Array(recoveredMessages.dropLast())]))
        #expect(recoveredMessages.last?["role"] as? String == "system")
        #expect(!String(describing: recoveredMessages).contains("private-empty-reasoning"))
        #expect((requests[1]["thinking"] as? [String: String])?["type"] == "enabled")
        #expect(result.tokens == 14 && result.reasoningCharacters > 0)
        #expect(QQPersona().decode(result.text, input: "fixture").text == "最终核对后的回复。")
    }
    @Test(arguments: ["alwaysEmpty", "length", "filtered", "emptyWithTools"])
    func failsClosedWithBoundedRequests(_ mode: String) async throws {
        let session = session(mode); defer { session.invalidateAndCancel() }
        let reservations = EmptyReservations(); var failed = false
        do {
            _ = try await DeepSeekClient(session: session).reply(key: "synthetic", config: QQConfig().ai,
                rule: ChatRule(name: "fixture"), history: [], text: "fixture", jsonOutput: true,
                reserve: { _ = await reservations.add() })
        } catch { failed = true }
        #expect(failed)
        #expect(await reservations.value == (mode == "alwaysEmpty" ? 2 : 1))
        #expect(await reservations.value == EmptyJSONProtocol.requests.count)
    }
    @Test(arguments: ["quota", "cancelled"])
    func recoveryCannotBypassReservationOrCancellation(_ mode: String) async throws {
        enum Limit: Error { case exhausted }
        let session = session("null"); defer { session.invalidateAndCancel() }
        let reservations = EmptyReservations(); var failed = false
        do {
            _ = try await DeepSeekClient(session: session).reply(key: "synthetic", config: QQConfig().ai,
                rule: ChatRule(name: "fixture"), history: [], text: "fixture", jsonOutput: true, reserve: {
                    if await reservations.add() == 2 {
                        if mode == "cancelled" { throw CancellationError() }
                        throw Limit.exhausted
                    }
                })
        } catch is CancellationError { #expect(mode == "cancelled"); failed = true }
        catch Limit.exhausted { #expect(mode == "quota"); failed = true }
        #expect(failed && EmptyJSONProtocol.requests.count == 1)
        #expect(await reservations.value == 2)
    }
    @Test func reviewStillRunsAndDoesNotFallBackToDraft() async throws {
        let session = session("review"); defer { session.invalidateAndCancel() }
        let reservations = EmptyReservations()
        let result = try await DeepSeekClient(session: session).reviewedQQReply(key: "synthetic", config: QQConfig().ai,
            rule: ChatRule(name: "fixture"), history: [], text: "fixture", reserve: { _ = await reservations.add() })
        #expect(await reservations.value == 3)
        #expect(result.tokens == 21)
        #expect(result.text.contains("最终核对后的回复"))
        #expect(!result.text.contains("尚未核对的草稿"))
        let requests = EmptyJSONProtocol.requests
        #expect(requests[1]["response_format"] != nil && requests[2]["response_format"] == nil)
    }
    @Test func toolIsNotExecutedAgainWhenFinalTextIsEmpty() async throws {
        let session = session("tool"); defer { session.invalidateAndCancel() }
        let reservations = EmptyReservations(); var toolCalls = 0
        let result = try await DeepSeekClient(session: session).reply(key: "synthetic", config: QQConfig().ai,
            rule: ChatRule(name: "fixture"), history: [], text: "fixture", jsonOutput: true, thinkingEnabled: true,
            toolHandler: { _, _ in toolCalls += 1; return ModelToolResult(content: "synthetic evidence", image: Data([1, 2, 3])) },
            reserve: { _ = await reservations.add() })
        #expect(await reservations.value == 3)
        #expect(toolCalls == 1 && result.usedTools)
        #expect(result.tokens == 21 && result.image == Data([1, 2, 3]))
        #expect(EmptyJSONProtocol.requests.dropFirst().allSatisfy { $0["tools"] == nil })
    }
    @Test func unconstrainedRecoveryStillRequiresValidReplyJSON() async throws {
        let session = session("invalidFallback"); defer { session.invalidateAndCancel() }
        let result = try await DeepSeekClient(session: session).reply(key: "synthetic", config: QQConfig().ai,
            rule: ChatRule(name: "fixture"), history: [], text: "fixture", jsonOutput: true, reserve: {})
        #expect(EmptyJSONProtocol.requests.count == 2)
        #expect(QQPersona().decode(result.text, input: "fixture").isFallback)
    }
}
