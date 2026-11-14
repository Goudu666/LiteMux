import XCTest
@testable import LiteMuxCore

final class SSHDiagnosisTests: XCTestCase {
    let ngrok = SSHEndpoint(host: "0.tcp.ngrok.io", user: "root", port: 12345)

    func testHostKeyChangedForgetsTheRightEntry() {
        let text = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Please contact your system administrator.
        Add correct host key in /Users/me/.ssh/known_hosts to get rid of this message.
        Offending ED25519 key in /Users/me/.ssh/known_hosts:7
        Host key for [0.tcp.ngrok.io]:12345 has changed and you have requested strict checking.
        Host key verification failed.
        """
        let d = SSHFailureDiagnosis.diagnose(text, endpoint: ngrok)
        XCTAssertEqual(d?.kind, .hostKeyChanged)
        XCTAssertEqual(d?.knownHostsName, "[0.tcp.ngrok.io]:12345")
        XCTAssertEqual(d?.knownHostsFile, "/Users/me/.ssh/known_hosts")
        XCTAssertEqual(d?.forgetHostKeyArguments, ["-R", "[0.tcp.ngrok.io]:12345", "-f", "/Users/me/.ssh/known_hosts"])
    }

    func testHostKeyNameFallsBackToEndpoint() {
        let d = SSHFailureDiagnosis.diagnose("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", endpoint: ngrok)
        XCTAssertEqual(d?.knownHostsName, "[0.tcp.ngrok.io]:12345")
        let plain = SSHFailureDiagnosis.diagnose("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!",
                                                 endpoint: SSHEndpoint(host: "gpu.example.com"))
        XCTAssertEqual(plain?.forgetHostKeyArguments, ["-R", "gpu.example.com"])
    }

    func testMissingTunnelProgramInEachShell() {
        let cf = SSHEndpoint(host: "abc.trycloudflare.com", user: "root",
                             options: ["ProxyCommand=cloudflared access ssh --hostname %h"])
        for line in ["zsh:1: command not found: cloudflared",
                     "/bin/sh: cloudflared: command not found",
                     "bash: line 1: exec: cloudflared: not found",
                     "/bin/sh: /Users/me/Downloads/cloudflared: No such file or directory"] {
            let d = SSHFailureDiagnosis.diagnose(line + "\nConnection closed by UNKNOWN port 65535", endpoint: cf)
            XCTAssertEqual(d?.kind, .proxyMissing, line)
            XCTAssertEqual(d?.title, "找不到隧道程序 cloudflared", line)
        }
    }

    func testTunnelWithNothingBehindIt() {
        let cf = SSHEndpoint(host: "abc.trycloudflare.com", options: ["ProxyCommand=cloudflared access ssh --hostname %h"])
        let d = SSHFailureDiagnosis.diagnose("""
        2026-11-14T19:50:01Z ERR failed to connect to origin error="websocket: bad handshake"
        kex_exchange_identification: Connection closed by remote host
        Connection closed by UNKNOWN port 65535
        """, endpoint: cf)
        XCTAssertEqual(d?.kind, .tunnelGone)
    }

    func testCommonNetworkAndAuthFailures() {
        XCTAssertEqual(SSHFailureDiagnosis.diagnose(
            "ssh: Could not resolve hostname old-name.trycloudflare.com: nodename nor servname provided, or not known",
            endpoint: nil)?.kind, .unresolved)
        XCTAssertEqual(SSHFailureDiagnosis.diagnose(
            "ssh: connect to host region-1.autodl.com port 38192: Connection refused", endpoint: nil)?.kind, .refused)
        XCTAssertEqual(SSHFailureDiagnosis.diagnose(
            "ssh: connect to host 10.0.0.9 port 22: Operation timed out", endpoint: nil)?.kind, .timeout)
        XCTAssertEqual(SSHFailureDiagnosis.diagnose(
            "Received disconnect from 1.2.3.4 port 22:2: Too many authentication failures", endpoint: nil)?.kind, .tooManyKeys)
        // Auth wins over the generic "connection closed" a proxy prints afterwards.
        let cf = SSHEndpoint(host: "abc.trycloudflare.com", options: ["ProxyCommand=cloudflared access ssh --hostname %h"])
        XCTAssertEqual(SSHFailureDiagnosis.diagnose(
            "root@abc.trycloudflare.com: Permission denied (publickey,password).\nConnection closed by UNKNOWN port 65535",
            endpoint: cf)?.kind, .authFailed)
        XCTAssertNil(SSHFailureDiagnosis.diagnose("Last login: Fri Nov 14\nlogout", endpoint: nil))
    }

    func testSoftWrappedRowsAreJoined() {
        let rows: [(text: String, isWrapped: Bool)] = [
            ("Host key for [0.tcp.ngrok.io]:12345 has ", false),
            ("changed and you have requested strict checking.   ", true),
            ("Host key verification failed.     ", false),
        ]
        XCTAssertEqual(SSHFailureDiagnosis.joinRows(rows),
                       "Host key for [0.tcp.ngrok.io]:12345 has changed and you have requested strict checking.\nHost key verification failed.")
    }

    func testPastedCloudflaredCommandKeepsProxyCommand() {
        let r = SSHCommandParser.parse(#"ssh -o ProxyCommand="cloudflared access ssh --hostname %h" root@abc-def.trycloudflare.com"#)
        XCTAssertEqual(r?.endpoint.host, "abc-def.trycloudflare.com")
        XCTAssertEqual(r?.endpoint.user, "root")
        XCTAssertEqual(r?.endpoint.options, ["ProxyCommand=cloudflared access ssh --hostname %h"])
        let args = r?.endpoint.arguments(home: "/Users/me") ?? []
        XCTAssertEqual(args, ["-o", "ProxyCommand=cloudflared access ssh --hostname %h", "root@abc-def.trycloudflare.com"])
    }
}
