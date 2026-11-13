import XCTest
@testable import LiteMuxCore

/// Answers scripts by substring; records what ran where.
private final class FakeShell: BridgeShell, @unchecked Sendable {
    var replies: [(needle: String, result: ShellResult)] = []
    var connected: Set<String> = [HostEntry.localID]
    private(set) var ran: [(host: String, script: String, stdin: Data?)] = []
    private let lock = NSLock()

    func reply(_ needle: String, _ out: String, status: Int32 = 0, err: String = "") {
        replies.append((needle, ShellResult(status: status, stdout: Data(out.utf8), stderr: Data(err.utf8))))
    }

    func run(_ script: String, on host: HostEntry, stdin: Data?, timeout: TimeInterval, outputLimit: Int) async -> ShellResult {
        lock.withLock { ran.append((host.id, script, stdin)) }
        return replies.first { script.contains($0.needle) }?.result ?? ShellResult(status: 0)
    }

    func isConnected(_ host: HostEntry) async -> Bool { connected.contains(host.id) }

    var scripts: [String] { lock.lock(); defer { lock.unlock() }; return ran.map(\.script) }
}

private final class ConfirmRecorder: @unchecked Sendable {
    var asked: [BridgeConfirmation] = []
    var answer: BridgeDecision = .allowOnce
}

final class BridgeServerTests: XCTestCase {
    private let gpuHost = HostEntry(id: "config:gpu", kind: .config, title: "gpu", subtitle: "root@10.0.0.2",
                                    endpoint: SSHEndpoint(host: "gpu"))

    private func makeServer(_ shell: FakeShell, mode: BridgeMode = .confirm, recorder: ConfirmRecorder = ConfirmRecorder(),
                            log: BridgeActivityLog? = nil) -> MCPServer {
        let hosts = [gpuHost, .local]
        let gpuID = gpuHost.id
        let toolbox = BridgeToolbox(shell: shell, directory: {
            BridgeHostDirectory(hosts: hosts, openSlots: [gpuID: [1]], focusedHostID: gpuID)
        })
        return MCPServer(tools: toolbox.tools, mode: { mode }, confirm: { request in
            recorder.asked.append(request)
            return recorder.answer
        }, log: log)
    }

    private func call(_ server: MCPServer, _ id: Int, _ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let line = JSONValue.object(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]).serialized()
        let handled = await server.handle(line)
        let response = try XCTUnwrap(handled)
        let value = try JSONValue.parse(response)
        XCTAssertEqual(value["id"], .number(Double(id)))
        return value
    }

    private func tool(_ server: MCPServer, _ name: String, _ args: JSONValue = [:]) async throws -> (text: String, isError: Bool) {
        let r = try await call(server, 9, "tools/call", ["name": .string(name), "arguments": args])
        let result = try XCTUnwrap(r["result"], "error: \(r.serialized())")
        guard case .array(let content)? = result["content"] else { XCTFail("no content"); return ("", true) }
        return (content.first?["text"]?.stringValue ?? "", result["isError"]?.boolValue ?? false)
    }

    func testInitializeEchoesVersionAndRemembersClient() async throws {
        let server = makeServer(FakeShell())
        let r = try await call(server, 1, "initialize", ["protocolVersion": "2025-03-26",
                                                         "clientInfo": ["name": "claude-code", "version": "2.0"]])
        XCTAssertEqual(r["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(r["result"]?["serverInfo"]?["name"], "litemux")
        XCTAssertNotNil(r["result"]?["capabilities"]?["tools"])
        let client = await server.client
        XCTAssertEqual(client, "Claude Code")

        let unknown = try await call(server, 2, "initialize", ["protocolVersion": "1999-01-01"])
        XCTAssertEqual(unknown["result"]?["protocolVersion"]?.stringValue, MCPServer.supportedVersions[0])
    }

    func testNotificationsAndErrors() async throws {
        let server = makeServer(FakeShell())
        let none = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(none)
        let badLine = await server.handle("{not json")
        let bad = try JSONValue.parse(XCTUnwrap(badLine))
        XCTAssertEqual(bad["error"]?["code"], -32700)
        let missing = try await call(server, 3, "no/such")
        XCTAssertEqual(missing["error"]?["code"], -32601)
        let ping = try await call(server, 4, "ping")
        XCTAssertEqual(ping["result"], .object([:]))
        let unknownTool = try await call(server, 5, "tools/call", ["name": "rm_rf"])
        XCTAssertEqual(unknownTool["error"]?["code"], -32602)
    }

    func testReadOnlyHidesAndRefusesActingTools() async throws {
        let shell = FakeShell()
        let server = makeServer(shell, mode: .readOnly)
        let list = try await call(server, 1, "tools/list")
        guard case .array(let tools)? = list["result"]?["tools"] else { return XCTFail() }
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("read_terminal"))
        XCTAssertFalse(names.contains("run_command"))
        XCTAssertFalse(names.contains("write_file"))
        XCTAssertEqual(tools.first { $0["name"] == "read_terminal" }?["annotations"]?["readOnlyHint"], true)

        let r = try await tool(server, "run_command", ["command": "rm -rf /"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("只读"))
        XCTAssertTrue(shell.scripts.isEmpty, "nothing may run in read-only mode")
    }

    func testConfirmModeAsksAndHonoursDenial() async throws {
        let shell = FakeShell()
        shell.reply("bash -lc", "hi\n")
        let recorder = ConfirmRecorder()
        recorder.answer = .deny
        let server = makeServer(shell, recorder: recorder)
        _ = try await call(server, 1, "initialize", ["clientInfo": ["name": "codex-mcp-client"]])

        let denied = try await tool(server, "run_command", ["command": "nvidia-smi -r", "cwd": "~/exp"])
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.text.contains("拒绝"))
        XCTAssertEqual(recorder.asked.count, 1)
        XCTAssertEqual(recorder.asked[0].client, "Codex")
        XCTAssertEqual(recorder.asked[0].hostTitle, "gpu")
        XCTAssertTrue(recorder.asked[0].detail.contains("cd ~/exp\nnvidia-smi -r"))
        XCTAssertTrue(shell.scripts.isEmpty)

        recorder.answer = .allowForSession
        let ok = try await tool(server, "run_command", ["command": "echo hi"])
        XCTAssertFalse(ok.isError)
        XCTAssertTrue(ok.text.contains("退出码 0"))
        XCTAssertTrue(ok.text.contains("hi"))
        // Allowed for the session: the next command on the same host does not ask again.
        _ = try await tool(server, "run_command", ["command": "echo again"])
        XCTAssertEqual(recorder.asked.count, 2)
        // …but another tool still asks.
        _ = try await tool(server, "send_to_terminal", ["text": "python train.py"])
        XCTAssertEqual(recorder.asked.count, 3)
        XCTAssertTrue(recorder.asked[2].action.contains("向终端"))
    }

    func testTrustedModeNeverAsks() async throws {
        let shell = FakeShell()
        let recorder = ConfirmRecorder()
        let server = makeServer(shell, mode: .trusted, recorder: recorder)
        shell.reply("base64", "12\n")
        let r = try await tool(server, "write_file", ["path": "~/exp/a.yaml", "content": "lr: 3e-4\n"])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(recorder.asked.isEmpty)
        let last = try XCTUnwrap(shell.ran.last)
        XCTAssertNil(last.stdin)
        XCTAssertTrue(last.script.contains("P=\"$HOME\"/exp/a.yaml"))
        XCTAssertTrue(last.script.contains(Data("lr: 3e-4\n".utf8).base64EncodedString()))

        // Big content goes in chunks: the first truncates, the rest append.
        let big = String(repeating: "x", count: BridgeScripts.writeChunk * 2 + 10)
        let before = shell.ran.count
        _ = try await tool(server, "write_file", ["path": "/tmp/big.txt", "content": .string(big)])
        let writes = shell.scripts.suffix(shell.ran.count - before)
        XCTAssertEqual(writes.count, 3)
        XCTAssertTrue(writes.first?.contains("| $B > ") == true)
        XCTAssertTrue(writes.dropFirst().allSatisfy { $0.contains("| $B >> ") })
    }

    func testReadTerminalPicksHostAndSession() async throws {
        let shell = FakeShell()
        shell.reply("capture-pane", "@@lm-session lm_1\nEpoch 1/3 loss=0.9\nEpoch 2/3 loss=0.5\n\n\n")
        let server = makeServer(shell)
        let r = try await tool(server, "read_terminal", ["lines": 50])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.hasPrefix("gpu · tmux lm_1"))
        XCTAssertTrue(r.text.hasSuffix("Epoch 2/3 loss=0.5"))
        XCTAssertEqual(shell.ran.last?.host, "config:gpu", "no host means the focused tab's host")
        XCTAssertTrue(shell.scripts.last?.contains("-S -50") == true)

        _ = try await tool(server, "read_terminal", ["host": "local", "session": "2"])
        XCTAssertEqual(shell.ran.last?.host, "local")
        XCTAssertTrue(shell.scripts.last?.contains("S=lm_2") == true)

        let bad = try await tool(server, "read_terminal", ["session": "x; rm -rf ~"])
        XCTAssertTrue(bad.isError)
    }

    func testReadTerminalExplainsMissingTmux() async throws {
        let shell = FakeShell()
        shell.reply("capture-pane", "@@lm-no-session\n", status: 4)
        let server = makeServer(shell)
        let r = try await tool(server, "read_terminal")
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("lm_"))
    }

    func testSSHFailureIsReadable() async throws {
        let shell = FakeShell()
        shell.reply("capture-pane", "", status: 255, err: "ssh: connect to host 10.0.0.2 port 22: Connection refused\n")
        let server = makeServer(shell)
        let r = try await tool(server, "read_terminal", ["host": "gpu"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("连不上 gpu"))
        XCTAssertTrue(r.text.contains("Connection refused"))
    }

    func testTrainingStatusSummarisesTheLog() async throws {
        var log = "@@lm-session lm_1\n$ python train.py\n"
        for i in 1...12 {
            log += String(format: "Epoch %d/40  loss=%.4f  acc=%.3f  lr=3.0e-04\n", i, 2.0 / Double(i), 0.5 + Double(i) * 0.02)
        }
        let shell = FakeShell()
        shell.reply("capture-pane", log)
        let server = makeServer(shell)
        let r = try await tool(server, "training_status")
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("训练中"), r.text)
        XCTAssertTrue(r.text.contains("epoch 12/40"), r.text)
        XCTAssertTrue(r.text.contains("%"), r.text)
        XCTAssertTrue(r.text.contains("loss"), r.text)
        XCTAssertTrue(r.text.contains("↓ 在变好"), r.text)
        XCTAssertTrue(r.text.contains("最佳 0.1667"), r.text)
        XCTAssertTrue(r.text.contains("loss 曲线"), r.text)
    }

    func testTrainingStatusWithoutALog() async throws {
        let shell = FakeShell()
        shell.reply("capture-pane", "@@lm-session lm_3\n$ ls\nREADME.md\n")
        let server = makeServer(shell)
        let r = try await tool(server, "training_status")
        XCTAssertFalse(r.isError)
        XCTAssertTrue(r.text.contains("没有认出训练日志"))
    }

    func testReadFileRefusesBinary() async throws {
        let shell = FakeShell()
        shell.replies.append(("head -c", ShellResult(status: 0, stdout: Data("2048\n@@lm-data\n".utf8) + Data([0x89, 0x50, 0x00, 0x01]))))
        let server = makeServer(shell)
        let r = try await tool(server, "read_file", ["path": "~/exp/mask.png"])
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.text.contains("二进制"))

        let text = FakeShell()
        text.reply("tail -n 2", "57\n@@lm-data\nline 9\nline 10\n")
        let server2 = makeServer(text)
        let t = try await tool(server2, "read_file", ["path": "/root/log.txt", "tail_lines": 2])
        XCTAssertFalse(t.isError, t.text)
        XCTAssertTrue(t.text.contains("57 字节"))
        XCTAssertTrue(t.text.hasSuffix("line 9\nline 10\n"))
    }

    func testListHostsShowsSessions() async throws {
        let shell = FakeShell()
        shell.connected.insert("config:gpu")
        shell.reply("list-sessions -F '#{session_name}", "@@now 1000\nlm_1\t880\t1\tpython\t/root/yolo\nwork\t100\t0\tzsh\t/root\n")
        let server = makeServer(shell)
        let r = try await tool(server, "list_hosts")
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("● gpu  [id: config:gpu]"), r.text)
        XCTAssertTrue(r.text.contains("lm_1 · python · /root/yolo · 2 分钟前有输出 · LiteMux 窗格 · 已连接"), r.text)
        XCTAssertTrue(r.text.contains("work · zsh"), r.text)
        XCTAssertTrue(r.text.contains("← LiteMux 当前标签页"), r.text)
    }

    func testActivityIsLogged() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = BridgeActivityLog(url: dir.appendingPathComponent("a.jsonl"), limit: 4096)
        let shell = FakeShell()
        shell.reply("nvidia-smi", "## gpu\nnone\n## load\n 10:00 up 1 day, load averages: 0.5 0.4 0.3\n")
        let recorder = ConfirmRecorder()
        recorder.answer = .deny
        let server = makeServer(shell, recorder: recorder, log: log)
        _ = try await tool(server, "gpu_status")
        _ = try await tool(server, "run_command", ["command": "reboot"])
        let recent = log.recent()
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent[0].tool, "run_command")
        XCTAssertEqual(recent[0].outcome, .denied)
        XCTAssertEqual(recent[0].summary, "reboot")
        XCTAssertEqual(recent[1].tool, "gpu_status")
        XCTAssertEqual(recent[1].host, "gpu")

        for i in 0..<200 {
            log.append(BridgeActivity(client: "c", tool: "t", host: nil, summary: "entry \(i)", outcome: .ok))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: log.url.path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, 4096 + 200)
        XCTAssertEqual(log.recent(1).first?.summary, "entry 199")
    }
}

final class BridgePartsTests: XCTestCase {
    func testJSONRoundTrip() throws {
        let v: JSONValue = ["a": [1, 2.5, "x\n\"y\"", true, nil], "b": ["c": "中文"]]
        let text = v.serialized()
        XCTAssertEqual(text, #"{"a":[1,2.5,"x\n\"y\"",true,null],"b":{"c":"中文"}}"#)
        XCTAssertEqual(try JSONValue.parse(text), v)
        XCTAssertEqual(try JSONValue.parse("false"), .bool(false))
        XCTAssertEqual(try JSONValue.parse("0"), .number(0))
    }

    func testPathWordAndSessionNames() throws {
        XCTAssertEqual(BridgeScripts.pathWord("~"), "\"$HOME\"")
        XCTAssertEqual(BridgeScripts.pathWord("~/runs/exp 1"), "\"$HOME\"/'runs/exp 1'")
        XCTAssertEqual(BridgeScripts.pathWord("/root/a'b"), ShellWords.quote("/root/a'b"))
        XCTAssertEqual(try BridgeScripts.sessionName("3"), "lm_3")
        XCTAssertEqual(try BridgeScripts.sessionName(" lm_2 "), "lm_2")
        XCTAssertNil(try BridgeScripts.sessionName(""))
        XCTAssertThrowsError(try BridgeScripts.sessionName("a b"))
        XCTAssertThrowsError(try BridgeScripts.sessionName("$(id)"))
    }

    func testCappedBufferKeepsHeadAndTail() {
        var b = CappedBuffer(limit: 40)
        b.append(Data(repeating: UInt8(ascii: "a"), count: 10))
        XCTAssertFalse(b.truncated)
        XCTAssertEqual(b.data.count, 10)
        for _ in 0..<50 { b.append(Data("0123456789".utf8)) }
        XCTAssertTrue(b.truncated)
        let s = String(decoding: b.data, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("aaaaaaaaaa"))
        XCTAssertTrue(s.hasSuffix("0123456789"))
        XCTAssertTrue(s.contains("省略"))
    }

    func testHostResolution() throws {
        let gpu = HostEntry(id: "bookmark:1", kind: .bookmark, title: "autodl-westb", subtitle: "root@connect.westb.seetacloud.com:38192",
                            endpoint: SSHEndpoint(host: "connect.westb.seetacloud.com", user: "root", port: 38192))
        let lab = HostEntry(id: "config:lab1", kind: .config, title: "lab1", subtitle: "localhost", endpoint: SSHEndpoint(host: "lab1"))
        let dir = BridgeHostDirectory(hosts: [gpu, lab, .local], openSlots: ["config:lab1": [1, 2]])
        XCTAssertEqual(try dir.resolve(nil).id, "config:lab1", "only host with open panes")
        XCTAssertEqual(try dir.resolve("LAB1").id, "config:lab1")
        XCTAssertEqual(try dir.resolve("bookmark:1").id, "bookmark:1")
        XCTAssertEqual(try dir.resolve("root@connect.westb.seetacloud.com").id, "bookmark:1")
        XCTAssertEqual(try dir.resolve("westb").id, "bookmark:1")
        XCTAssertEqual(try dir.resolve("本机").id, "local")
        XCTAssertThrowsError(try dir.resolve("nowhere"))

        var state = PersistedState()
        state.tabs = [TabSnapshot(kind: .terminal(.leaf(PaneSpec(hostID: "local", slot: 3)))),
                      TabSnapshot(kind: .terminal(.leaf(PaneSpec(hostID: "config:lab1", slot: 1))))]
        state.selectedTabIndex = 1
        let made = BridgeHostDirectory.make(state: state, config: [])
        XCTAssertEqual(made.focusedHostID, "config:lab1")
        XCTAssertEqual(made.openSlots["local"], [3])
        XCTAssertEqual(made.hosts.last?.id, "local")
    }

    func testGPUReport() {
        let out = """
        ## gpu
        0, NVIDIA A100-SXM4-80GB, 97, 61234, 81920, 66, 312.55
        1, NVIDIA A100-SXM4-80GB, 0, 4, 81920, 31, 52.10
        ## procs
        GPU-aaa, 4242, 61000, python
        ## uuids
        0, GPU-aaa
        1, GPU-bbb
        ## load
         12:01:02 up 3 days,  2:11,  1 user,  load average: 3.10, 2.80, 2.50
        ## cpus
        32
        ## mem
        Mem:         257000       64000      100000         100       93000      190000
        ## disk
        /dev/vda1  200G  120G  80G  60% /root
        """
        let r = GPUReport.parse(out)
        XCTAssertEqual(r.gpus.count, 2)
        XCTAssertEqual(r.gpus[0].processes.first?.pid, 4242)
        XCTAssertTrue(r.text.contains("GPU0 NVIDIA A100-SXM4-80GB · 利用率 97% · 显存 59.8/80.0 GiB"), r.text)
        XCTAssertTrue(r.text.contains("GPU1") && r.text.contains("（空闲）"), r.text)
        XCTAssertTrue(r.text.contains("pid 4242 python · 61000 MiB"), r.text)
        XCTAssertTrue(r.text.contains("（32 核）"), r.text)
        XCTAssertTrue(r.text.contains("磁盘（/root）：可用 80G / 200G"), r.text)
        XCTAssertTrue(r.text.contains("可用 185.5 GiB"), r.text)
    }

    func testConfigFallsBackToConfirm() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertEqual(BridgeConfig.load(home: home).mode, .confirm)
        try BridgeConfig(mode: .trusted).save(home: home)
        XCTAssertEqual(BridgeConfig.load(home: home).mode, .trusted)
        try Data(#"{"mode":"yolo"}"#.utf8).write(to: BridgeConfig.url(home: home))
        XCTAssertEqual(BridgeConfig.load(home: home).mode, .confirm)
    }

    func testLocalShellRunsAndTimesOut() async throws {
        let shell = ProcessBridgeShell()
        let ok = await shell.run("echo out; echo err >&2; exit 3", on: .local, stdin: nil, timeout: 10, outputLimit: 1000)
        XCTAssertEqual(ok.status, 3)
        XCTAssertEqual(ok.out, "out\n")
        XCTAssertEqual(ok.err, "err\n")

        let piped = await shell.run("cat", on: .local, stdin: Data("from stdin".utf8), timeout: 10, outputLimit: 1000)
        XCTAssertEqual(piped.out, "from stdin")

        let written = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/a b/x.txt").path
        let w = await shell.run(BridgeScripts.write(path: written, chunk: Data("héllo\n".utf8), append: false),
                                on: .local, stdin: nil, timeout: 10, outputLimit: 1000)
        XCTAssertEqual(w.status, 0, w.err)
        _ = await shell.run(BridgeScripts.write(path: written, chunk: Data("again\n".utf8), append: true),
                            on: .local, stdin: nil, timeout: 10, outputLimit: 1000)
        XCTAssertEqual(try String(contentsOfFile: written, encoding: .utf8), "héllo\nagain\n")

        let started = Date()
        let slow = await shell.run("sleep 30", on: .local, stdin: nil, timeout: 1, outputLimit: 1000)
        XCTAssertTrue(slow.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)

        let big = await shell.run("yes 0123456789 | head -c 200000", on: .local, stdin: nil, timeout: 10, outputLimit: 10_000)
        XCTAssertTrue(big.truncated)
        XCTAssertLessThan(big.stdout.count, 10_200)
    }

    func testSSHArgumentsReuseTheMaster() {
        let shell = ProcessBridgeShell(invocation: SSHInvocation(home: "/Users/me"))
        let args = shell.sshArguments(for: SSHEndpoint(host: "gpu", user: "root", port: 2222), usesAskpass: false, script: "echo 'hi'")
        XCTAssertTrue(args.contains("ControlMaster=no"))
        XCTAssertTrue(args.contains("ControlPath=/Users/me/.ssh/lm/%C"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(Array(args.suffix(4)), ["-p", "2222", "root@gpu", "sh -c " + ShellWords.quote("echo 'hi'")])
    }
}
