import AppKit
import LiteMuxCore

// Writing to a pipe whose reader went away must not kill the app.
signal(SIGPIPE, SIG_IGN)

// The same executable doubles as OpenSSH's SSH_ASKPASS helper: when ssh runs
// us in that role we answer from the Keychain and exit before any UI loads.
if ProcessInfo.processInfo.environment[Askpass.modeVariable] == "1" {
    exit(Askpass.runHelper())
}

// `LiteMux --mcp`: serve local coding agents over stdio instead of opening a window.
if BridgeMain.requested {
    MainActor.assumeIsolated { BridgeMain.run() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
