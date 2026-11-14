import XCTest
@testable import LiteMuxCore

final class ShellScanTests: XCTestCase {
    func testChainsRedirectionsAndBackground() {
        let s = ShellScan.segments("cd ~/exp && nohup python train.py --lr 3e-4 > train.log 2>&1 &")
        XCTAssertEqual(s.map(\.words), [["cd", "~/exp"],
                                        ["nohup", "python", "train.py", "--lr", "3e-4", ">", "train.log", "2>&1"]])
    }

    func testQuotesStayOneWord() {
        let s = ShellScan.segments(#"ssh lab1 "cd /data && tmux new -d -s train 'python t.py'" | tail -5; echo done"#)
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0].words, ["ssh", "lab1", "cd /data && tmux new -d -s train 'python t.py'"])
        XCTAssertEqual(s[1].words, ["tail", "-5"])
    }

    func testHeredocBodyAttachesToItsCommand() {
        let text = """
        ssh gpu bash -s <<'EOF'
        cd ~/proj
        python eval.py --ckpt best.pt
        EOF
        echo after
        """
        let s = ShellScan.segments(text)
        XCTAssertEqual(s.first?.words, ["ssh", "gpu", "bash", "-s"])
        XCTAssertEqual(s.first?.heredoc, "cd ~/proj\npython eval.py --ckpt best.pt")
        XCTAssertEqual(s.last?.words, ["echo", "after"])
    }

    func testWrappersAreStripped() {
        XCTAssertEqual(ShellScan.strippingWrappers(["CUDA_VISIBLE_DEVICES=0", "timeout", "30", "ssh", "gpu"]), ["ssh", "gpu"])
        XCTAssertEqual(ShellScan.strippingWrappers(["sudo", "-u", "bob", "python", "x.py"]), ["python", "x.py"])
        XCTAssertEqual(ShellScan.strippingWrappers(["env", "-u", "X", "A=1", "ssh", "h"]), ["ssh", "h"])
    }
}

final class SSHArgvTests: XCTestCase {
    func testOptionsDestinationAndCommand() throws {
        let a = try XCTUnwrap(SSHArgv.parse(["-p", "2222", "-o", "ControlPath=~/.ssh/cm-%r@%h:%p", "-o", "ControlMaster=auto",
                                             "root@1.2.3.4", "nvidia-smi", "-L"]))
        XCTAssertEqual(a.destination, "root@1.2.3.4")
        XCTAssertEqual(a.remoteCommand, "nvidia-smi -L")
        XCTAssertEqual(a.controlPath, "~/.ssh/cm-%r@%h:%p")
        XCTAssertEqual(a.controlMaster, "auto")
        XCTAssertEqual(a.endpoint, SSHEndpoint(host: "1.2.3.4", user: "root", port: 2222))
        XCTAssertEqual(a.resolveArguments.first, "-G")
        XCTAssertEqual(a.resolveArguments.last, "root@1.2.3.4")
        XCTAssertFalse(a.resolveArguments.contains("nvidia-smi"))
    }

    func testOptionsAfterDestinationAndFlags() throws {
        let a = try XCTUnwrap(SSHArgv.parse(["-fN", "lab1", "-L", "6006:localhost:6006"]))
        XCTAssertTrue(a.noCommand)
        XCTAssertEqual(a.forwards, ["-L 6006:localhost:6006"])
        XCTAssertEqual(a.remoteCommand, "")
        let check = try XCTUnwrap(SSHArgv.parse(["-S", "/tmp/s", "-O", "check", "x"]))
        XCTAssertEqual(check.muxCommand, "check")
        XCTAssertEqual(check.controlPath, "/tmp/s")
        XCTAssertTrue(try XCTUnwrap(SSHArgv.parse(["-G", "lab1"])).isQuery)
    }

    func testMuxTitleAndSocketNames() {
        XCTAssertEqual(SSHArgv.muxMasterSocket(fromTitle: "ssh: /Users/me/.ssh/cm-root@gpu:22 [mux]"), "/Users/me/.ssh/cm-root@gpu:22")
        XCTAssertNil(SSHArgv.muxMasterSocket(fromTitle: "ssh lab1"))
        XCTAssertEqual(SSHArgv.endpoint(fromSocketName: "/Users/me/.ssh/cm-root@connect.westb.seetacloud.com:38192"),
                       SSHEndpoint(host: "connect.westb.seetacloud.com", user: "root", port: 38192))
        XCTAssertEqual(SSHArgv.endpoint(fromSocketName: "/tmp/runner@localhost:22"), SSHEndpoint(host: "localhost", user: "runner"))
        XCTAssertNil(SSHArgv.endpoint(fromSocketName: "/Users/me/.ssh/lm/0123456789abcdef"))
    }

    func testResolvedTarget() throws {
        let out = """
        user root
        hostname 10.1.2.3
        port 2222
        controlmaster auto
        controlpath /Users/me/.ssh/cm-root@10.1.2.3:2222
        proxyjump none
        """
        let t = try XCTUnwrap(ResolvedSSHTarget.parse(out, home: "/Users/me"))
        XCTAssertEqual(t, ResolvedSSHTarget(hostName: "10.1.2.3", user: "root", port: 2222,
                                            controlPath: "/Users/me/.ssh/cm-root@10.1.2.3:2222", controlMaster: "auto"))
        XCTAssertNil(try XCTUnwrap(ResolvedSSHTarget.parse("hostname x\ncontrolpath none")).controlPath)
        XCTAssertNil(try XCTUnwrap(ResolvedSSHTarget.parse("hostname x\ncontrolpath ~/.ssh/%C")).controlPath)
    }

    func testHostMatching() {
        let config = [SSHConfigHost(alias: "lab1", otherAliases: [], hostName: "localhost", user: "runner", port: nil,
                                    identityFile: nil, proxyJump: nil, sourceFile: "~/.ssh/config")]
        let bookmark = Bookmark(name: "autodl", endpoint: SSHEndpoint(host: "connect.westb.seetacloud.com", user: "root", port: 38192))
        XCTAssertEqual(HostMatcher.match(alias: "lab1", endpoint: SSHEndpoint(host: "lab1"), resolved: nil,
                                         bookmarks: [bookmark], config: config), "config:lab1")
        XCTAssertEqual(HostMatcher.match(alias: "runner@localhost", endpoint: SSHEndpoint(host: "localhost", user: "runner"),
                                         resolved: nil, bookmarks: [bookmark], config: config), "config:lab1")
        XCTAssertEqual(HostMatcher.match(alias: "root@connect.westb.seetacloud.com",
                                         endpoint: SSHEndpoint(host: "connect.westb.seetacloud.com", user: "root", port: 38192),
                                         resolved: nil, bookmarks: [bookmark], config: config), bookmark.hostID)
        XCTAssertNil(HostMatcher.match(alias: "ubuntu@10.0.0.8", endpoint: SSHEndpoint(host: "10.0.0.8", user: "ubuntu"),
                                       resolved: nil, bookmarks: [bookmark], config: config))
        // An alias the config does not list, resolved by ssh -G to a bookmark's address.
        XCTAssertEqual(HostMatcher.match(alias: "westb", endpoint: SSHEndpoint(host: "westb"),
                                         resolved: ResolvedSSHTarget(hostName: "connect.westb.seetacloud.com", user: "root", port: 38192),
                                         bookmarks: [bookmark], config: config), bookmark.hostID)
    }

    func testRidingAnAgentSocket() throws {
        let dir = NSTemporaryDirectory() + "lm-agent-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ep = SSHEndpoint(host: "gpu", options: ["ControlPath=/elsewhere/x", "ServerAliveInterval=5"])
        let riding = ep.riding(controlPath: dir + "/cm-root@gpu:22")
        XCTAssertEqual(riding.options, ["ServerAliveInterval=5", "ControlPath=\(dir)/cm-root@gpu:22"])
        XCTAssertEqual(riding.adoptedControlPath, dir + "/cm-root@gpu:22")
        XCTAssertNil(ep.adoptedControlPath, "a folder that does not exist is never used")

        let inv = SSHInvocation(home: "/h")
        XCTAssertTrue(inv.multiplexOptions(for: riding).contains("ControlPath=\(dir)/cm-root@gpu:22"))
        XCTAssertTrue(inv.multiplexOptions(for: ep).contains("ControlPath=/h/.ssh/lm/%C"))
        XCTAssertTrue(inv.controlArguments(endpoint: riding, command: "check").contains("ControlPath=\(dir)/cm-root@gpu:22"))
    }

    func testReadOnlyAttach() {
        let cmd = SSHInvocation.remoteLauncher(slot: nil, directory: nil, session: "agent-train", readOnly: true)
        XCTAssertTrue(cmd.contains("attach-session -r -t =agent-train"), cmd)
        XCTAssertFalse(SSHInvocation.remoteLauncher(slot: nil, directory: nil, session: "x").contains(" -r "))
    }
}

final class RemoteCommandInsightTests: XCTestCase {
    func testTrainingJobInBackground() {
        let i = RemoteCommandInsight.analyze("cd ~/exp && source .venv/bin/activate && nohup python train.py --lr 3e-4 > train.log 2>&1 &")
        XCTAssertEqual(i.directory, "~/exp")
        XCTAssertEqual(i.logFiles, ["train.log"])
        XCTAssertEqual(i.headline, "python train.py --lr 3e-4")
        XCTAssertTrue(i.tmuxSessions.isEmpty)
    }

    func testDetachedTmuxSession() {
        let i = RemoteCommandInsight.analyze("cd /data && tmux new-session -d -s train 'python train.py --epochs 40 | tee run.log'")
        XCTAssertEqual(i.directory, "/data")
        XCTAssertEqual(i.tmuxSessions, ["train"])
        XCTAssertTrue(i.startsTmuxSession)
        XCTAssertEqual(i.headline, "python train.py --epochs 40")
        XCTAssertEqual(i.logFiles, ["run.log"])
    }

    func testSendKeysAndCapture() {
        let send = RemoteCommandInsight.analyze("tmux send-keys -t =lm_2:0.1 'python eval.py' Enter")
        XCTAssertEqual(send.tmuxSessions, ["lm_2"])
        XCTAssertEqual(send.headline, "python eval.py")
        let cap = RemoteCommandInsight.analyze("tmux capture-pane -p -t train -S -50")
        XCTAssertEqual(cap.tmuxSessions, ["train"])
        XCTAssertEqual(cap.headline, "tmux capture-pane train")
    }

    func testTailFollowAndInteractive() {
        let t = RemoteCommandInsight.analyze("tail -n 50 -f ~/exp/train.log")
        XCTAssertEqual(t.logFiles, ["~/exp/train.log"])
        XCTAssertTrue(RemoteCommandInsight.analyze("").isInteractive)
    }

    func testHeredocScriptIsTheCommand() {
        let i = RemoteCommandInsight.analyze("bash -s", script: "cd ~/proj\npython eval.py --ckpt best.pt")
        XCTAssertEqual(i.directory, "~/proj")
        XCTAssertEqual(i.headline, "python eval.py --ckpt best.pt")
    }

    func testFindsEverySSHAndCopy() {
        let line = #"rsync -avz -e "ssh -p 2222" ./ckpt/ root@1.2.3.4:/data/ckpt/ && ssh -p 2222 root@1.2.3.4 'ls /data/ckpt' && scp lab1:~/exp/out.png ."#
        let t = RemoteTouch.find(in: line)
        XCTAssertEqual(t.map(\.tool), ["rsync", "ssh", "scp"])
        XCTAssertEqual(t[0].destination, "root@1.2.3.4")
        XCTAssertEqual(t[0].endpoint.port, 2222)
        XCTAssertEqual(t[0].remotePaths, ["/data/ckpt/"])
        XCTAssertEqual(t[1].command, "ls /data/ckpt")
        XCTAssertEqual(t[2].destination, "lab1")
        XCTAssertEqual(t[2].insight.directory, "~/exp")
        XCTAssertTrue(RemoteTouch.find(in: "ssh -O check lab1; ls -la; git push").isEmpty)
    }
}

final class LocalAgentTests: XCTestCase {
    func testAgentDetection() {
        XCTAssertEqual(AgentKind.detect(command: "node /opt/homebrew/bin/claude --resume"), .claudeCode)
        XCTAssertEqual(AgentKind.detect(command: "claude"), .claudeCode)
        XCTAssertEqual(AgentKind.detect(command: "/bin/zsh -c -l source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh && eval 'ssh x'"), .claudeCode)
        XCTAssertEqual(AgentKind.detect(command: "/opt/homebrew/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex"), .codex)
        XCTAssertEqual(AgentKind.detect(command: "/Applications/Antigravity.app/Contents/MacOS/Electron"), .antigravity)
        XCTAssertNil(AgentKind.detect(command: "-zsh"))
        XCTAssertNil(AgentKind.detect(command: "/Applications/iTerm.app/Contents/MacOS/iTerm2"))
        XCTAssertEqual(AgentKind.fromClientName("claude-code"), .claudeCode)
        XCTAssertEqual(AgentKind.fromClientName("codex-mcp-client"), .codex)
    }

    func testPsParsing() {
        let out = """
            1     0 3-04:05:06 /sbin/launchd
          501     1    01:02 /Applications/iTerm.app/Contents/MacOS/iTerm2
          502   501 02:03:04 ssh -p 2222 root@1.2.3.4  ls   -la
        """
        let p = ProcessTable.parse(out)
        XCTAssertEqual(p.count, 3)
        let threeDays: TimeInterval = 3 * 86_400 + 4 * 3600 + 5 * 60 + 6
        XCTAssertEqual(p[0].elapsed, threeDays)
        XCTAssertEqual(p[1].elapsed, 62)
        XCTAssertEqual(p[2].ppid, 501)
        XCTAssertEqual(p[2].executableName, "ssh")
        XCTAssertEqual(p[2].words, ["ssh", "-p", "2222", "root@1.2.3.4", "ls", "-la"])
    }

    func testScanFindsAgentsAndSkipsLiteMux() {
        let lm = "/Users/me/.ssh/lm"
        let table: [LocalProcess] = [
            .init(pid: 100, ppid: 1, elapsed: 900, command: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
            .init(pid: 110, ppid: 100, elapsed: 800, command: "-zsh"),
            .init(pid: 120, ppid: 110, elapsed: 700, command: "node /opt/homebrew/bin/claude"),
            .init(pid: 130, ppid: 120, elapsed: 5, command: "/bin/zsh -c ssh lab1 cd ~/exp && python train.py"),
            .init(pid: 140, ppid: 130, elapsed: 5, command: "ssh lab1 cd ~/exp && python train.py"),
            .init(pid: 141, ppid: 140, elapsed: 5, command: "ssh -W [localhost]:22 jump"),
            .init(pid: 150, ppid: 110, elapsed: 60, command: "ssh -p 2222 root@1.2.3.4"),
            .init(pid: 160, ppid: 1, elapsed: 600, command: "ssh: /Users/me/.ssh/cm-root@1.2.3.4:2222 [mux]"),
            .init(pid: 170, ppid: 1, elapsed: 600, command: "ssh: \(lm)/0123abcd [mux]"),
            .init(pid: 999, ppid: 1, elapsed: 1000, command: "/Applications/LiteMux.app/Contents/MacOS/LiteMux"),
            .init(pid: 180, ppid: 999, elapsed: 30, command: "/usr/bin/ssh -T -o ControlPath=\(lm)/%C lab1 sftp"),
            .init(pid: 200, ppid: 999, elapsed: 30, command: "-zsh"),
            .init(pid: 210, ppid: 200, elapsed: 20, command: "ssh gpu"),
            .init(pid: 220, ppid: 120, elapsed: 2, command: "ssh -O check lab1"),
        ]
        let r = LocalSSHScan.scan(table, selfPID: 999, controlDirectory: lm)
        XCTAssertEqual(r.connections.map(\.pid), [140, 150])
        XCTAssertEqual(r.connections[0].agent, .claudeCode)
        XCTAssertEqual(r.connections[0].argv.destination, "lab1")
        XCTAssertEqual(r.connections[0].insight.headline, "python train.py")
        XCTAssertNil(r.connections[1].agent)
        XCTAssertEqual(r.connections[1].app, "iTerm")
        XCTAssertEqual(r.masters, [ObservedMaster(pid: 160, socketPath: "/Users/me/.ssh/cm-root@1.2.3.4:2222")])
    }
}

final class TranscriptTests: XCTestCase {
    let claudeCall = Data(#"{"type":"assistant","timestamp":"2026-11-14T10:00:00.123Z","cwd":"/Users/me/proj","message":{"role":"assistant","content":[{"type":"text","text":"Let me check"},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ssh lab1 'nvidia-smi --query-gpu=name --format=csv'","description":"Check GPU on lab1"}}]}}"#.utf8)
    let claudeResult = Data(#"{"type":"user","timestamp":"2026-11-14T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"name\nNVIDIA A100"}],"is_error":false}]}}"#.utf8)
    let codexCall = Data(#"{"timestamp":"2026-11-14T10:01:00.000Z","type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"ssh -p 38192 root@connect.westb.seetacloud.com 'df -h /root/autodl-tmp'\"],\"workdir\":\"/Users/me/x\"}","call_id":"call_9"}}"#.utf8)
    let codexResult = Data(#"{"timestamp":"2026-11-14T10:01:03.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_9","output":"{\"output\":\"df: /root/autodl-tmp: No such file\",\"metadata\":{\"exit_code\":1}}"}}"#.utf8)

    func testClaudeLines() throws {
        let call = AgentTranscript.parseClaude(line: claudeCall)
        XCTAssertEqual(call.count, 1)
        XCTAssertEqual(call[0].id, "toolu_1")
        XCTAssertEqual(call[0].cwd, "/Users/me/proj")
        XCTAssertNotNil(call[0].time)
        XCTAssertEqual(call[0].kind, .call(command: "ssh lab1 'nvidia-smi --query-gpu=name --format=csv'", note: "Check GPU on lab1"))
        let result = AgentTranscript.parseClaude(line: claudeResult)
        XCTAssertEqual(result.first?.kind, .result(output: "name\nNVIDIA A100", isError: false, exitCode: nil))
        XCTAssertTrue(AgentTranscript.parseClaude(line: Data("not json".utf8)).isEmpty)
    }

    func testCodexLines() {
        let call = AgentTranscript.parseCodex(line: codexCall)
        XCTAssertEqual(call.first?.kind, .call(command: "ssh -p 38192 root@connect.westb.seetacloud.com 'df -h /root/autodl-tmp'", note: nil))
        XCTAssertEqual(call.first?.cwd, "/Users/me/x")
        let result = AgentTranscript.parseCodex(line: codexResult)
        XCTAssertEqual(result.first?.kind, .result(output: "df: /root/autodl-tmp: No such file", isError: true, exitCode: 1))
        let begin = Data(#"{"type":"event_msg","payload":{"type":"exec_command_begin","call_id":"c2","command":["bash","-lc","ssh lab1 uptime"],"cwd":"/w"}}"#.utf8)
        XCTAssertEqual(AgentTranscript.parseCodex(line: begin).first?.kind, .call(command: "ssh lab1 uptime", note: nil))
    }

    func testTimelineMergesSources() throws {
        var t = AgentTimeline()
        t.ingest(AgentTranscript.parseClaude(line: claudeCall), agent: .claudeCode, session: "s1")
        // A shell call that never touches a server is not recorded.
        let local = Data(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"git status"}}]}}"#.utf8)
        t.ingest(AgentTranscript.parseClaude(line: local), agent: .claudeCode, session: "s1")
        XCTAssertEqual(t.recent().count, 1)
        var a = try XCTUnwrap(t.recent().first)
        XCTAssertEqual(a.state, .running)
        XCTAssertEqual(a.destination, "lab1")
        XCTAssertEqual(a.command, "nvidia-smi --query-gpu=name --format=csv")
        XCTAssertEqual(a.note, "Check GPU on lab1")
        XCTAssertEqual(a.project, "proj")

        // The same command seen in ps while it ran is not added twice.
        let argv = try XCTUnwrap(SSHArgv.parse(["lab1", "nvidia-smi", "--query-gpu=name", "--format=csv"]))
        let ssh = ObservedSSH(pid: 140, agent: .claudeCode, agentPID: 120, app: nil, argv: argv, elapsed: 1)
        XCTAssertEqual(t.transcriptAction(for: ssh, firstSeen: a.start.addingTimeInterval(1))?.id, a.id)
        t.processEnded(ssh, firstSeen: a.start.addingTimeInterval(1))
        XCTAssertEqual(t.recent().count, 1)

        t.ingest(AgentTranscript.parseClaude(line: claudeResult), agent: .claudeCode, session: "s1")
        a = try XCTUnwrap(t.recent().first)
        XCTAssertEqual(a.state, .done(exitCode: nil))
        XCTAssertEqual(a.output, "name\nNVIDIA A100")

        // An ssh the logs never mention is kept from the process list.
        let other = try XCTUnwrap(SSHArgv.parse(["gpu", "watch", "-n1", "nvidia-smi"]))
        t.processEnded(ObservedSSH(pid: 150, agent: .codex, agentPID: 1, app: nil, argv: other, elapsed: 30),
                        firstSeen: a.start.addingTimeInterval(3600))
        XCTAssertEqual(t.recent().count, 2)
        XCTAssertEqual(t.recent().first?.source, .process)

        t.setBridge([BridgeActivity(client: "claude-code", tool: "read_terminal", host: "lab1", summary: "lm_1 · 120 行", outcome: .ok)])
        XCTAssertEqual(t.recent().first?.source, .bridge)
        XCTAssertEqual(t.recent().first?.agent, .claudeCode)
        t.setBridge([])
        XCTAssertEqual(t.recent().count, 2)
    }

    func testTailReadsOnlyNewCompleteLines() throws {
        let path = NSTemporaryDirectory() + "lm-tail-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("old line that is cut\n{\"a\":1}\n".utf8).write(to: URL(fileURLWithPath: path))
        var tail = JSONLinesTail(path: path, backlog: 10)
        XCTAssertEqual(tail.read().map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}"])
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        h.seekToEndOfFile()
        h.write(Data("{\"b\":2}\n{\"c\"".utf8))
        XCTAssertEqual(tail.read().map { String(decoding: $0, as: UTF8.self) }, ["{\"b\":2}"])
        h.write(Data(":3}\n".utf8))
        try h.close()
        XCTAssertEqual(tail.read().map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
        XCTAssertTrue(tail.read().isEmpty)
    }
}

final class UserFocusTests: XCTestCase {
    func testSelectionLines() throws {
        let text = "import torch\n\ndef main():\n    train()\n    evaluate()\n"
        let ns = text as NSString
        let r = ns.range(of: "def main():\n    train()\n")
        let (line, sel) = UserFocus.selection(in: text, location: r.location, length: r.length)
        XCTAssertEqual(line, 3)
        let s = try XCTUnwrap(sel)
        XCTAssertEqual(s.startLine, 3)
        XCTAssertEqual(s.endLine, 4)
        XCTAssertEqual(s.text, "def main():\n    train()\n")
        let (cursor, none) = UserFocus.selection(in: text, location: ns.range(of: "evaluate").location, length: 0)
        XCTAssertEqual(cursor, 5)
        XCTAssertNil(none)
    }

    func testDescribeAndRoundTrip() throws {
        let home = NSTemporaryDirectory() + "lm-focus-\(UUID().uuidString.prefix(6))"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let f = UserFocus(view: "editor",
                          file: .init(hostID: "config:lab1", host: "lab1", path: "/root/exp/train.py", cursorLine: 12,
                                      selection: .init(startLine: 12, endLine: 14, text: "for x in loader:\n    step(x)")),
                          browser: .init(hostID: "config:lab1", host: "lab1", directory: "/root/exp", selected: "/root/exp/train.py"),
                          openFiles: ["lab1:/root/exp/train.py", "lab1:/root/exp/config.yaml"])
        try f.save(home: home)
        let back = try XCTUnwrap(UserFocus.load(home: home))
        XCTAssertTrue(back.sameContent(as: f))
        let text = back.describe(now: back.updated)
        XCTAssertTrue(text.contains("lab1:/root/exp/train.py"))
        XCTAssertTrue(text.contains("第 12–14 行"))
        XCTAssertTrue(text.contains("for x in loader:"))
        XCTAssertTrue(text.contains("config.yaml"))
        XCTAssertFalse(text.contains("其他打开的文件：lab1:/root/exp/train.py"))
    }
}
