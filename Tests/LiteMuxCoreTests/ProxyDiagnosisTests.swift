import XCTest
@testable import LiteMuxCore

final class ProxyDiagnosisTests: XCTestCase {
    func testProxyProbeOutcomes() {
        let missing = SSHFailureDiagnosis.diagnoseProxy(program: "cloudflared", found: false, probe: nil)
        XCTAssertEqual(missing.kind, .proxyMissing)
        XCTAssertEqual(missing.title, "找不到隧道程序 cloudflared")

        let banner = Array("SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.10\r\n".utf8)
        let alive = SSHFailureDiagnosis.diagnoseProxy(program: "/opt/homebrew/bin/cloudflared", found: true,
            probe: .from(stdout: banner, stderr: [], timedOut: false, exitCode: nil))
        XCTAssertEqual(alive.title, "隧道是通的，但 SSH 握手失败")

        let cfErr = """
        2026-11-14T19:50:01Z INF Starting
        2026-11-14T19:50:02Z ERR failed to connect to origin error="websocket: bad handshake"

        """
        let dead = SSHFailureDiagnosis.diagnoseProxy(program: "cloudflared", found: true,
                                                     probe: .init(stderr: cfErr, exitCode: 1))
        XCTAssertEqual(dead.kind, .tunnelGone)
        XCTAssertTrue(dead.detail.contains("（cloudflared 退出码 1）"), dead.detail)
        XCTAssertTrue(dead.detail.hasSuffix("""
        cloudflared 说：2026-11-14T19:50:01Z INF Starting
        2026-11-14T19:50:02Z ERR failed to connect to origin error="websocket: bad handshake"
        """), dead.detail)

        let waiting = SSHFailureDiagnosis.diagnoseProxy(program: "colab", found: true, probe: .init(timedOut: true))
        XCTAssertEqual(waiting.kind, .tunnelWaiting)
    }

    func testProbeSplitsTextAroundTheBanner() {
        // Lines before the banner are allowed (ssh skips them); text after it lands in the packet stream.
        let raw = Array("""
        [colab] Run 'colab update' to update.
        SSH-2.0-OpenSSH_9.6\r
        [colab] To silence this check, set "enable_update_check": false

        """.utf8)
        let p = SSHFailureDiagnosis.ProxyProbe.from(stdout: raw, stderr: [], timedOut: false, exitCode: nil)
        XCTAssertTrue(p.sawBanner)
        XCTAssertEqual(p.beforeBanner, "[colab] Run 'colab update' to update.")
        XCTAssertEqual(p.noise, #"[colab] To silence this check, set "enable_update_check": false"#)

        let d = SSHFailureDiagnosis.diagnoseProxy(program: "colab", found: true, probe: p)
        XCTAssertEqual(d.kind, .proxyNoise)
        XCTAssertEqual(d.title, "colab-cli 的更新提示混进了 SSH 数据")
        XCTAssertTrue(d.offersColabUpdateFix)

        // A binary KEXINIT right after the banner (dropbear does this) is not noise.
        let kex = Array("SSH-2.0-dropbear\r\n".utf8) + [0, 0, 1, 0x14, 0x0A, 0x14]
        XCTAssertEqual(SSHFailureDiagnosis.ProxyProbe.from(stdout: kex, stderr: [], timedOut: false, exitCode: nil).noise, "")
        // No banner at all: everything is "before".
        let none = SSHFailureDiagnosis.ProxyProbe.from(stdout: Array("hello\nworld".utf8), stderr: [], timedOut: true, exitCode: nil)
        XCTAssertFalse(none.sawBanner)
        XCTAssertEqual(none.beforeBanner, "hello\nworld")
    }

    func testColabNoticeOnStderrOnlyOffersTheFixWithoutBlamingIt() {
        // What the first report showed: no banner, only colab-cli's notice.
        let notice = """
        [colab] Run 'colab update' to update.
        [colab] To silence this check, set "enable_update_check": false in ~/.config/colab-cli/settings.json

        """
        let log = """
        [colab] Run 'colab update' to update.
        Error: runtime not found: please reconnect in the notebook

        """
        let d = SSHFailureDiagnosis.diagnoseProxy(program: "colab", found: true,
                                                  probe: .init(stderr: notice, exitCode: 1), connectLog: log)
        XCTAssertEqual(d.kind, .tunnelGone)
        XCTAssertTrue(d.offersColabUpdateFix)
        XCTAssertTrue(d.detail.contains("连接时 colab 说：Error: runtime not found: please reconnect in the notebook"), d.detail)
        XCTAssertFalse(d.detail.contains("to update."), d.detail)
    }

    func testProgramInsideShellWrapperAndStderrLog() {
        let t = SSHFailureDiagnosis.ProxyTarget(command: "sh -c 'colab ssh-proxy --runtime %h 2>/dev/null || exit 1'",
                                                host: "rt-1", port: 22, user: "root")
        XCTAssertEqual(t.program, "colab")
        XCTAssertEqual(t.loggingStderr(to: "/Users/me/.ssh/lm/proxy-config_colab.log"),
                       #"sh -c 'sh -c '\''colab ssh-proxy --runtime %h 2>/dev/null || exit 1'\''' 2>/Users/me/.ssh/lm/proxy-config_colab.log"#)
        XCTAssertEqual(SSHFailureDiagnosis.ProxyTarget(command: "/usr/bin/nc %h %p", host: "h", port: 1, user: "u").program,
                       "/usr/bin/nc")
    }

    func testColabSettingsKeepOtherKeys() throws {
        let out = try ColabCLISettings.disablingUpdateCheck(Data(#"{"theme": "dark", "enable_update_check": true}"#.utf8))
        let obj = try JSONSerialization.jsonObject(with: out) as? [String: Any]
        XCTAssertEqual(obj?["theme"] as? String, "dark")
        XCTAssertEqual(obj?["enable_update_check"] as? Bool, false)
        let fresh = try JSONSerialization.jsonObject(with: ColabCLISettings.disablingUpdateCheck(nil)) as? [String: Any]
        XCTAssertEqual(fresh?["enable_update_check"] as? Bool, false)
        XCTAssertThrowsError(try ColabCLISettings.disablingUpdateCheck(Data("not json".utf8)))
    }
}
