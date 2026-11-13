import Foundation

/// Builds argument vectors for the system OpenSSH client.
///
/// Every connection to the same endpoint shares one encrypted tunnel through
/// `ControlMaster=auto`; the socket lives under the short path `~/.ssh/lm/%C`
/// so we stay well below the 104-byte UNIX socket limit on macOS.
public struct SSHInvocation: Sendable {
    public static let sshPath = "/usr/bin/ssh"

    public var home: String
    public var controlPersist: String

    public init(home: String = NSHomeDirectory(), controlPersist: String = "10m") {
        self.home = home
        self.controlPersist = controlPersist
    }

    public var controlDirectory: String { home + "/.ssh/lm" }
    public var controlPath: String { controlDirectory + "/%C" }

    /// Creates `~/.ssh/lm` with 0700 permissions if needed.
    public func ensureControlDirectory() throws {
        let fm = FileManager.default
        let sshDir = home + "/.ssh"
        if !fm.fileExists(atPath: sshDir) {
            try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        if !fm.fileExists(atPath: controlDirectory) {
            try fm.createDirectory(atPath: controlDirectory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory)
        }
    }

    public var multiplexOptions: [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=\(controlPersist)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
    }

    /// Options used when a saved password is fed through `SSH_ASKPASS`.
    public static let askpassOptions: [String] = [
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "StrictHostKeyChecking=accept-new",
    ]

    /// Non-interactive options for SFTP and probes. They never block on a prompt.
    public func backgroundOptions(usesAskpass: Bool) -> [String] {
        var opts = multiplexOptions + ["-o", "ConnectTimeout=6"]
        if usesAskpass {
            opts += Self.askpassOptions
        } else {
            opts += ["-o", "BatchMode=yes"]
        }
        return opts
    }

    // MARK: - Terminal panes

    /// Interactive terminal: `ssh -t … dest -- sh -c '<launcher>'`.
    public func terminalArguments(endpoint: SSHEndpoint, slot: Int?, directory: String?, usesAskpass: Bool,
                                  session: String? = nil) -> [String] {
        var args = ["-t"] + multiplexOptions
        if usesAskpass { args += Self.askpassOptions }
        args += endpoint.arguments(home: home)
        args.append(Self.remoteLauncher(slot: slot, directory: directory, session: session))
        return args
    }

    /// The remote command for a pane. With a slot it attaches to (or creates)
    /// the private `lm_<slot>` tmux session, falling back to the login shell
    /// silently when tmux is missing. It never touches global tmux options.
    public static func remoteLauncher(slot: Int?, directory: String?, session: String? = nil) -> String {
        var script = ""
        if let directory, !directory.isEmpty {
            let dir: String
            if directory == "~" {
                dir = "\"$HOME\""
            } else if directory.hasPrefix("~/") {
                dir = "\"$HOME\"/" + ShellWords.quote(String(directory.dropFirst(2)))
            } else {
                dir = ShellWords.quote(directory)
            }
            script += "cd \(dir) 2>/dev/null; "
        }
        if let session, !session.isEmpty {
            // Someone else's session: attach as it is, never create or rename it.
            let s = ShellWords.quote(session)
            script += "if command -v tmux >/dev/null 2>&1 && tmux has-session -t =\(s) 2>/dev/null; then exec tmux attach-session -t =\(s); fi; "
        } else if let slot {
            let session = sessionName(slot: slot)
            script += "if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s \(session); fi; "
        }
        script += "exec \"${SHELL:-/bin/sh}\" -l"
        return "sh -c " + ShellWords.quote(script)
    }

    public static func sessionName(slot: Int) -> String { "lm_\(slot)" }

    // MARK: - Background channels

    /// `ssh … -s dest sftp` — the binary SFTP subsystem over stdin/stdout.
    public func sftpArguments(endpoint: SSHEndpoint, usesAskpass: Bool) -> [String] {
        ["-T"] + backgroundOptions(usesAskpass: usesAskpass) + ["-s"] + endpoint.arguments(home: home) + ["sftp"]
    }

    /// A long-lived `sh` on the remote side that the status bar writes probe scripts to.
    public func probeShellArguments(endpoint: SSHEndpoint, usesAskpass: Bool) -> [String] {
        ["-T"] + backgroundOptions(usesAskpass: usesAskpass) + endpoint.arguments(home: home) + ["exec sh"]
    }

    /// `ssh -O check` / `-O exit` against the shared master.
    public func controlArguments(endpoint: SSHEndpoint, command: String) -> [String] {
        ["-o", "ControlPath=\(controlPath)", "-O", command] + endpoint.arguments(home: home)
    }

    /// Socket files currently present in `~/.ssh/lm`.
    public func existingControlSockets() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: controlDirectory) else { return [] }
        return names.map { controlDirectory + "/" + $0 }
    }

    /// Asks the master behind a socket file to exit.
    public static func exitArguments(socketPath: String) -> [String] {
        ["-o", "ControlPath=\(socketPath)", "-O", "exit", "litemux"]
    }
}
