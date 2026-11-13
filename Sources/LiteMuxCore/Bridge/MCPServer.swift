import Foundation

/// What a tool may do; decides whether it is listed and whether it asks first.
public enum BridgeAccess: String, Sendable {
    case read, exec, write
}

/// Shown in LiteMux's dialog before a command or write runs.
public struct BridgeConfirmation: Sendable, Equatable {
    public var client: String
    public var tool: String
    public var hostTitle: String
    /// e.g. "执行命令"
    public var action: String
    /// The command, keys or file preview, shown in monospace.
    public var detail: String
}

public enum BridgeDecision: Sendable, Equatable {
    case allowOnce
    case allowForSession
    case deny
}

public typealias BridgeConfirmHandler = @Sendable (BridgeConfirmation) async -> BridgeDecision

public struct BridgeToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// One tool call in flight. Handlers fill in `host` and `summary` for the log
/// and call `authorize` before anything that changes the server.
public final class BridgeCall: @unchecked Sendable {
    public let arguments: JSONValue
    public let client: String
    public var host: HostEntry?
    public var summary = ""
    fileprivate var authorizeImpl: (BridgeCall, String, String) async throws -> Void = { _, _, _ in }
    fileprivate let tool: BridgeTool

    fileprivate init(arguments: JSONValue, client: String, tool: BridgeTool) {
        self.arguments = arguments
        self.client = client
        self.tool = tool
    }

    public func string(_ key: String) -> String? {
        guard let s = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    public func rawString(_ key: String) -> String? { arguments[key]?.stringValue }

    public func int(_ key: String, default value: Int, range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, arguments[key]?.intValue ?? value))
    }

    public func double(_ key: String, default value: Double, range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, arguments[key]?.doubleValue ?? value))
    }

    public func bool(_ key: String, default value: Bool) -> Bool { arguments[key]?.boolValue ?? value }

    /// Asks the user (depending on the mode). Throws when denied.
    public func authorize(action: String, detail: String) async throws {
        try await authorizeImpl(self, action, detail)
    }
}

public struct BridgeTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var access: BridgeAccess
    public var inputSchema: JSONValue
    public var handler: @Sendable (BridgeCall) async throws -> BridgeToolResult

    public init(name: String, title: String, description: String, access: BridgeAccess,
                inputSchema: JSONValue, handler: @escaping @Sendable (BridgeCall) async throws -> BridgeToolResult) {
        self.name = name
        self.title = title
        self.description = description
        self.access = access
        self.inputSchema = inputSchema
        self.handler = handler
    }

    var listing: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(access == .read),
                "destructiveHint": .bool(access == .write),
                "idempotentHint": .bool(access == .read),
                "openWorldHint": false,
            ],
        ]
    }
}

/// A Model Context Protocol server over newline-delimited JSON-RPC 2.0.
///
/// It knows nothing about stdio or AppKit: `handle(_:)` takes one line and
/// returns the response line, so tests drive it directly and the app wires it
/// to stdin/stdout and an NSAlert.
public actor MCPServer {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverVersion = "0.2.0"

    public static let instructions = """
    LiteMux is the user's SSH/tmux workbench for GPU training servers. These tools reach the \
    servers the user has open in LiteMux, through LiteMux's own SSH connections. Start with \
    list_hosts. read_terminal and training_status read what the user's terminal panes show \
    (LiteMux panes are tmux sessions named lm_1, lm_2, …); gpu_status shows GPUs, memory and disk. \
    Prefer reading before acting. Long jobs (training) belong in a terminal pane via \
    send_to_terminal so they survive disconnects; use run_command for short, non-interactive \
    commands. Commands and writes may need the user's approval in a LiteMux dialog.
    """

    private let tools: [BridgeTool]
    private let mode: @Sendable () -> BridgeMode
    private let confirm: BridgeConfirmHandler
    private let log: BridgeActivityLog?
    private var clientName = "Agent"
    private var allowed: Set<String> = []

    public init(tools: [BridgeTool], mode: @escaping @Sendable () -> BridgeMode,
                confirm: @escaping BridgeConfirmHandler, log: BridgeActivityLog? = nil) {
        self.tools = tools
        self.mode = mode
        self.confirm = confirm
        self.log = log
    }

    public var client: String { clientName }

    /// Handles one JSON-RPC line. Notifications return nil.
    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(trimmed) else {
            return Self.error(id: .null, code: -32700, message: "Parse error")
        }
        if case .array = message { return Self.error(id: .null, code: -32600, message: "Batches are not supported") }
        guard case .object = message else { return Self.error(id: .null, code: -32600, message: "Invalid request") }
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            // A response to something we never sent; ignore.
            return id == nil ? nil : Self.error(id: id ?? .null, code: -32600, message: "Invalid request")
        }
        let params = message["params"] ?? .object([:])
        guard let id else {
            // Notifications: initialized, cancelled, … nothing to answer.
            return nil
        }
        do {
            let result = try await dispatch(method: method, params: params)
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).serialized()
        } catch let e as RPCError {
            return Self.error(id: id, code: e.code, message: e.message)
        } catch {
            return Self.error(id: id, code: -32603, message: String(describing: error))
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    static func error(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id,
                          "error": ["code": .number(Double(code)), "message": .string(message)]]).serialized()
    }

    private func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            if let info = params["clientInfo"] {
                clientName = Self.prettyClientName(info["title"]?.stringValue ?? info["name"]?.stringValue)
            }
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "litemux", "title": "LiteMux", "version": .string(Self.serverVersion)],
                "instructions": .string(Self.instructions),
            ]
        case "ping":
            return .object([:])
        case "tools/list":
            return ["tools": .array(visibleTools().map(\.listing))]
        case "tools/call":
            return try await callTool(params)
        case "resources/list":
            return ["resources": []]
        case "prompts/list":
            return ["prompts": []]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func visibleTools() -> [BridgeTool] {
        mode() == .readOnly ? tools.filter { $0.access == .read } : tools
    }

    private func callTool(_ params: JSONValue) async throws -> JSONValue {
        guard let name = params["name"]?.stringValue else { throw RPCError(code: -32602, message: "Missing tool name") }
        guard let tool = tools.first(where: { $0.name == name }) else {
            throw RPCError(code: -32602, message: "Unknown tool: \(name)")
        }
        let call = BridgeCall(arguments: params["arguments"] ?? .object([:]), client: clientName, tool: tool)
        if ProcessInfo.processInfo.environment["LITEMUX_SMOKE_BRIDGE"] == "1" {
            FileHandle.standardError.write(Data("bridge: call \(name) \((params["arguments"] ?? .null).serialized().prefix(160))\n".utf8))
        }
        call.authorizeImpl = { [weak self] call, action, detail in
            guard let self else { throw BridgeToolError("LiteMux Bridge 已关闭。") }
            try await self.authorize(call, action: action, detail: detail)
        }
        var outcome = BridgeActivity.Outcome.ok
        let result: BridgeToolResult
        if tool.access != .read, mode() == .readOnly {
            outcome = .denied
            result = BridgeToolResult("LiteMux 处于只读模式，不能\(tool.title)。用户可以在 LiteMux 的「接入 Coding Agent」里改成「执行前确认」。", isError: true)
        } else {
            do {
                result = try await tool.handler(call)
                if result.isError { outcome = .failed }
            } catch let denied as Denied {
                outcome = .denied
                result = BridgeToolResult(denied.message, isError: true)
            } catch {
                outcome = .failed
                result = BridgeToolResult(String(describing: error), isError: true)
            }
        }
        log?.append(BridgeActivity(client: clientName, tool: name, host: call.host?.title,
                                   summary: call.summary, outcome: outcome))
        return [
            "content": [["type": "text", "text": .string(result.text)]],
            "isError": .bool(result.isError),
        ]
    }

    struct Denied: Error { var message: String }

    private func authorize(_ call: BridgeCall, action: String, detail: String) async throws {
        switch mode() {
        case .trusted: return
        case .readOnly: throw Denied(message: "LiteMux 处于只读模式。")
        case .confirm: break
        }
        let key = call.tool.name + "|" + (call.host?.id ?? "")
        if allowed.contains(key) { return }
        let request = BridgeConfirmation(client: clientName, tool: call.tool.name,
                                         hostTitle: call.host?.title ?? "本机", action: action, detail: detail)
        switch await confirm(request) {
        case .allowOnce: return
        case .allowForSession: allowed.insert(key)
        case .deny: throw Denied(message: "用户在 LiteMux 里拒绝了这次操作（\(action)）。请换个做法，或者先问问用户。")
        }
    }

    /// `claude-code` → `Claude Code`, keeps proper titles as they are.
    static func prettyClientName(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "Agent" }
        let known: [String: String] = [
            "claude-code": "Claude Code", "claude-ai": "Claude", "claude": "Claude",
            "codex-mcp-client": "Codex", "codex": "Codex", "codex_cli": "Codex",
            "antigravity": "Antigravity", "gemini-cli-mcp-client": "Gemini CLI", "cursor-vscode": "Cursor",
        ]
        if let k = known[raw.lowercased()] { return k }
        if raw.lowercased().contains("antigravity") { return "Antigravity" }
        if raw.lowercased().contains("codex") { return "Codex" }
        return raw
    }
}
