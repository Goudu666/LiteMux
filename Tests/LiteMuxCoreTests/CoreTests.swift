import XCTest
@testable import LiteMuxCore

final class SSHConfigParserTests: XCTestCase {
    func testFiltersWildcardsAndTakesFirstAlias() {
        let text = """
        Host *
            ServerAliveInterval 30
        Host autodl-*
            User root
        Host lab1 lab1-alt 10.0.0.5
            HostName lab1.example.edu
            User goudu
            Port 2222
        Host jp-proxy
            HostName 1.2.3.4
        # comment
        Host lab2
            HostName=lab2.example.edu
            ProxyJump jp-proxy
        Match host foo
            User nobody
        Host !bad
            User x
        """
        let hosts = SSHConfigParser(home: "/Users/t").parse(text: text)
        XCTAssertEqual(hosts.map(\.alias), ["lab1", "jp-proxy", "lab2"])
        XCTAssertEqual(hosts[0].otherAliases, ["lab1-alt", "10.0.0.5"])
        XCTAssertEqual(hosts[0].user, "goudu")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].subtitle, "lab1-alt, 10.0.0.5 · goudu@lab1.example.edu:2222")
        XCTAssertEqual(hosts[2].hostName, "lab2.example.edu")
        XCTAssertEqual(hosts[2].proxyJump, "jp-proxy")
    }

    func testIncludeIsFollowedRecursively() {
        let files: [String: String] = [
            "/Users/t/.ssh/config": "Include conf.d/*\nHost main\n  HostName m.example.com\n",
            "/Users/t/.ssh/conf.d/a": "Host a1\n  User ua\nInclude ~/.ssh/deep\n",
            "/Users/t/.ssh/conf.d/b": "Host b1 b2\n",
            "/Users/t/.ssh/deep": "Host deep\n  Include /Users/t/.ssh/config\n",
        ]
        let parser = SSHConfigParser(home: "/Users/t",
                                     readFile: { files[$0] },
                                     expandGlob: { pattern in
                                         let prefix = pattern.replacingOccurrences(of: "*", with: "")
                                         return files.keys.filter { $0.hasPrefix(prefix) }
                                     })
        let hosts = parser.parseUserConfig()
        XCTAssertEqual(hosts.map(\.alias), ["a1", "deep", "b1", "main"])
        XCTAssertEqual(hosts.first?.user, "ua")
    }
}

final class SSHCommandParserTests: XCTestCase {
    func testAutoDLCommand() throws {
        let r = try XCTUnwrap(SSHCommandParser.parse("ssh -p 38192 root@connect.westb.seetacloud.com"))
        XCTAssertEqual(r.endpoint.host, "connect.westb.seetacloud.com")
        XCTAssertEqual(r.endpoint.user, "root")
        XCTAssertEqual(r.endpoint.port, 38192)
        XCTAssertEqual(r.suggestedName, "autodl-westb-38192")
    }

    func testIdentityAndTrailingPort() throws {
        let r = try XCTUnwrap(SSHCommandParser.parse("ssh -i ~/.ssh/id_ed25519 ubuntu@1.2.3.4 -p 2222"))
        XCTAssertEqual(r.endpoint.identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(r.endpoint.user, "ubuntu")
        XCTAssertEqual(r.endpoint.host, "1.2.3.4")
        XCTAssertEqual(r.endpoint.port, 2222)
        XCTAssertEqual(r.suggestedName, "ubuntu@1.2.3.4:2222")
    }

    func testBareUserHostPort() throws {
        let r = try XCTUnwrap(SSHCommandParser.parse("user@host.example.com:2200"))
        XCTAssertEqual(r.endpoint.user, "user")
        XCTAssertEqual(r.endpoint.host, "host.example.com")
        XCTAssertEqual(r.endpoint.port, 2200)
    }

    func testCompactFlagsAndOptions() throws {
        let r = try XCTUnwrap(SSHCommandParser.parse("ssh -p2222 -o User=alice -o Compression=yes -C example.org"))
        XCTAssertEqual(r.endpoint.port, 2222)
        XCTAssertEqual(r.endpoint.user, "alice")
        XCTAssertEqual(r.endpoint.options, ["Compression=yes"])
    }

    func testSshURLAndIPv6() throws {
        let a = try XCTUnwrap(SSHCommandParser.parse("ssh://root@[fe80::1]:2022"))
        XCTAssertEqual(a.endpoint.host, "fe80::1")
        XCTAssertEqual(a.endpoint.port, 2022)
    }

    func testMultiLinePasteWithPassword() throws {
        let text = "登录指令：\nssh -p 12345 root@region-41.seetacloud.com\n密码：Abc123xyz"
        let r = try XCTUnwrap(SSHCommandParser.parse(text))
        XCTAssertEqual(r.endpoint.port, 12345)
        XCTAssertEqual(r.detectedPassword, "Abc123xyz")
        XCTAssertEqual(r.suggestedName, "autodl-r41-12345")
    }

    func testRejectsGarbage() {
        XCTAssertNil(SSHCommandParser.parse("   "))
        XCTAssertNil(SSHCommandParser.parse("ssh -p 22"))
    }
}

final class SSHInvocationTests: XCTestCase {
    func testLauncherUsesPrivateSlotAndFallsBack() {
        let cmd = SSHInvocation.remoteLauncher(slot: 3, directory: "~/exp dir")
        XCTAssertTrue(cmd.hasPrefix("sh -c '"))
        XCTAssertTrue(cmd.contains("tmux new-session -A -s lm_3"))
        XCTAssertTrue(cmd.contains("exec \"${SHELL:-/bin/sh}\" -l"))
        XCTAssertFalse(cmd.contains("set -g"))
        XCTAssertTrue(cmd.contains("$HOME"))
    }

    func testControlPathIsShort() {
        let inv = SSHInvocation(home: "/Users/someone-with-a-long-name")
        // %C expands to 40 hex characters.
        XCTAssertLessThan(inv.controlDirectory.utf8.count + 1 + 40, 104)
        XCTAssertTrue(inv.multiplexOptions.contains("ControlMaster=auto"))
    }

    func testBackgroundNeverPrompts() {
        let inv = SSHInvocation(home: "/h")
        let args = inv.sftpArguments(endpoint: SSHEndpoint(host: "lab1"), usesAskpass: false)
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ConnectTimeout=6"))
        XCTAssertEqual(Array(args.suffix(3)), ["-s", "lab1", "sftp"])
    }
}

final class SFTPCodecTests: XCTestCase {
    func testRoundTripAttributesAndFraming() throws {
        let attrs = SFTPAttributes(size: 1234, uid: 1, gid: 2, permissions: 0o100644, accessTime: 10, modifyTime: 20)
        let packet = SFTPWriter.packet(.attrs) { w in
            w.uint32(7)
            w.attributes(attrs)
        }
        var framer = SFTPFramer()
        framer.append(packet.prefix(3))
        XCTAssertNil(try framer.next())
        framer.append(packet.dropFirst(3))
        let body = try XCTUnwrap(try framer.next())
        var r = SFTPReader(body)
        XCTAssertEqual(try r.byte(), SFTPMessage.attrs.rawValue)
        XCTAssertEqual(try r.uint32(), 7)
        XCTAssertEqual(try r.attributes(), attrs)
        XCTAssertEqual(attrs.fileType, .file)
        XCTAssertNil(try framer.next())
    }

    func testDirectoryMode() {
        XCTAssertEqual(SFTPAttributes(permissions: 0o040755).fileType, .directory)
        XCTAssertEqual(SFTPAttributes(permissions: 0o120777).fileType, .symlink)
    }
}

final class FileModelTests: XCTestCase {
    func testFoldersFirstCaseInsensitive() {
        let entries = [
            FileEntry(name: "b.py", path: "/b.py", kind: .file),
            FileEntry(name: "Zoo", path: "/Zoo", kind: .directory),
            FileEntry(name: "a.txt", path: "/a.txt", kind: .file),
            FileEntry(name: "link", path: "/link", kind: .symlink, symlinkIsDirectory: true),
            FileEntry(name: "apple", path: "/apple", kind: .directory),
        ]
        XCTAssertEqual(FileEntry.sorted(entries).map(\.name), ["apple", "link", "Zoo", "a.txt", "b.py"])
    }

    func testPaths() {
        XCTAssertEqual(RemotePath.parent("/home/a/b"), "/home/a")
        XCTAssertEqual(RemotePath.parent("/home"), "/")
        XCTAssertEqual(RemotePath.join("/", "x"), "/x")
        XCTAssertEqual(RemotePath.breadcrumbs("/home/a").map(\.path), ["/", "/home", "/home/a"])
    }

    func testGate() {
        XCTAssertEqual(TextFileGate.check(size: 6 * 1024 * 1024), .tooLarge(6 * 1024 * 1024))
        XCTAssertNil(TextFileGate.check(size: 100))
        XCTAssertEqual(TextFileGate.check(head: Data([0x41, 0x00, 0x42])), .binary)
        XCTAssertEqual(TextFileGate.check(head: Data("seed: 42\n".utf8)), .editable)
    }

    func testDownloadNaming() {
        let dir = URL(fileURLWithPath: "/tmp/dl")
        let taken: Set<String> = ["/tmp/dl/log.txt", "/tmp/dl/log 2.txt"]
        let url = DownloadNaming.uniqueURL(in: dir, for: "log.txt") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "log 3.txt")
    }
}

final class ProbeTests: XCTestCase {
    func testParsesProbeOutput() {
        let out = """
        @@lm-begin
        @@cpu
        cpu  100 0 50 800 50 0 0 0 0 0
        @@mem
        MemTotal:       131072000 kB
        MemAvailable:    91750400 kB
        @@disk
        /dev/sda1 1000000000 588000000 412000000 59% /home
        @@gpu
        0, NVIDIA GeForce RTX 4090, 1228, 24564, 12
        1, NVIDIA GeForce RTX 4090, 23347, 24564, 97
        @@lm-end
        """
        let p = ServerProbe.parse(out)
        XCTAssertEqual(p.ticks, CPUTicks(busy: 150, total: 1000))
        XCTAssertEqual(p.memTotalKiB, 131_072_000)
        XCTAssertEqual(p.diskFreeKiB, 412_000_000)
        XCTAssertEqual(p.gpus.count, 2)
        XCTAssertEqual(p.gpus[1].utilization, 97)

        let s = ServerProbe.sample(from: p, previousTicks: CPUTicks(busy: 100, total: 900), latencyMs: 24)
        XCTAssertEqual(s.cpuPercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(s.memoryUsedBytes, (131_072_000 - 91_750_400) * 1024)
        XCTAssertEqual(s.gpus[0].compact, "GPU0 1.2/24G 12%")
    }

    func testNoGPUNoProc() {
        let p = ServerProbe.parse("@@lm-begin\n@@cpu\n@@mem\n@@disk\n/dev/disk1s1 100 50 50 50% /\n@@gpu\n@@lm-end\n")
        XCTAssertNil(p.ticks)
        XCTAssertTrue(p.gpus.isEmpty)
        XCTAssertEqual(p.diskFreeKiB, 50)
    }
}

final class SplitTreeTests: XCTestCase {
    func testSplitAndCollapse() {
        let a = PaneSpec(hostID: "h", slot: 1)
        let b = PaneSpec(hostID: "h", slot: 2)
        let c = PaneSpec(hostID: "h", slot: 3)
        var tree = SplitNode.leaf(a)
        tree = tree.splitting(pane: a.id, axis: .horizontal, with: b)
        tree = tree.splitting(pane: b.id, axis: .vertical, with: c)
        XCTAssertEqual(tree.leaves.map(\.slot), [1, 2, 3])
        let removed = tree.removing(pane: a.id)
        XCTAssertEqual(removed?.leaves.map(\.slot), [2, 3])
        if case .split(_, let axis, _, _, _)? = removed { XCTAssertEqual(axis, .vertical) } else { XCTFail() }
        XCTAssertNil(SplitNode.leaf(a).removing(pane: a.id))
    }

    func testCodableRoundTrip() throws {
        let a = PaneSpec(hostID: "config:lab1", slot: 1, directory: "~/exp")
        let tree = SplitNode.leaf(a).splitting(pane: a.id, axis: .horizontal, with: PaneSpec(hostID: "local", slot: nil))
        var state = PersistedState()
        state.tabs = [TabSnapshot(kind: .terminal(tree))]
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(back.tabs, state.tabs)
        XCTAssertTrue(back.autoTmuxEnabled(for: "config:lab1"))
        XCTAssertFalse(back.autoTmuxEnabled(for: HostEntry.localID))
    }

    func testSlots() {
        XCTAssertEqual(SlotAllocator.nextSlot(used: [1, 2, 4]), 3)
        XCTAssertEqual(SlotAllocator.nextSlot(used: []), 1)
    }

    func testDecodesOlderStateLeniently() throws {
        let json = #"{"fontSize": 15, "unknownKey": true}"#
        let s = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(s.fontSize, 15)
        XCTAssertTrue(s.sidebarVisible)
        XCTAssertEqual(s.colorTheme, .paper)
        XCTAssertEqual(s.appearance, .light)
    }

    func testColorThemeRoundTripAndUnknownValue() throws {
        var state = PersistedState()
        state.colorTheme = .sakura
        let back = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.colorTheme, .sakura)
        // A theme from a newer build falls back instead of failing the whole file.
        let future = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"colorTheme": "neon", "fontSize": 14}"#.utf8))
        XCTAssertEqual(future.colorTheme, .paper)
        XCTAssertEqual(future.fontSize, 14)
    }
}

final class ShellWordsTests: XCTestCase {
    func testSplitAndQuote() {
        XCTAssertEqual(ShellWords.split(#"ssh -i "a b" 'c d' e\ f"#), ["ssh", "-i", "a b", "c d", "e f"])
        XCTAssertEqual(ShellWords.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellWords.quote("/plain/path"), "/plain/path")
    }
}
