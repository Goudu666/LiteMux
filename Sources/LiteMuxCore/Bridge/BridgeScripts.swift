import Foundation

/// The POSIX sh snippets behind each tool. They only read, except the ones the
/// user confirms, and leave nothing behind on the server.
public enum BridgeScripts {
    public static let noTmux = "@@lm-no-tmux"
    public static let noSession = "@@lm-no-session"
    public static let sessionMarker = "@@lm-session "
    public static let dataMarker = "@@lm-data"

    /// A path as a shell word: `~` and `~/x` expand to `$HOME`, everything else is quoted.
    public static func pathWord(_ path: String) -> String {
        if path == "~" || path.isEmpty { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/" + ShellWords.quote(String(path.dropFirst(2))) }
        return ShellWords.quote(path)
    }

    /// `3` → `lm_3`; anything else must be a plain tmux session name.
    public static func sessionName(_ raw: String?) throws -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let n = Int(raw), n > 0 { return SSHInvocation.sessionName(slot: n) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.@"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw BridgeToolError("会话名只能包含字母、数字和 _ - . @，例如 lm_1。")
        }
        return raw
    }

    /// Prelude that finds tmux and picks the session into `$S`: the named one,
    /// or the LiteMux pane (`lm_*`) with the most recent activity.
    static func selectSession(_ session: String?) -> String {
        """
        T=$(command -v tmux 2>/dev/null)
        for c in /usr/bin/tmux /usr/local/bin/tmux /opt/homebrew/bin/tmux "$HOME/.local/bin/tmux"; do [ -n "$T" ] && break; [ -x "$c" ] && T=$c; done
        [ -n "$T" ] || { echo \(noTmux); exit 3; }
        S=\(session.map(ShellWords.quote) ?? "''")
        if [ -z "$S" ]; then
          S=$("$T" list-sessions -F '#{session_activity} #{session_name}' 2>/dev/null | awk '$2 ~ /^lm_/' | sort -rn | head -n 1 | cut -d' ' -f2)
        fi
        [ -n "$S" ] || { echo \(noSession); exit 4; }
        "$T" has-session -t "$S" 2>/dev/null || { echo "\(noSession) $S"; exit 4; }
        echo "\(sessionMarker)$S"
        """
    }

    public static func capture(session: String?, lines: Int) -> String {
        selectSession(session) + "\n" + "\"$T\" capture-pane -p -J -t \"$S\" -S -\(max(1, lines))\n"
    }

    public static func send(session: String?, text: String, enter: Bool, interrupt: Bool, settle: Double, tail: Int) -> String {
        var s = selectSession(session) + "\n"
        if interrupt { s += "\"$T\" send-keys -t \"$S\" C-c\nsleep 0.3\n" }
        if !text.isEmpty { s += "\"$T\" send-keys -t \"$S\" -l -- \(ShellWords.quote(text))\n" }
        if enter { s += "\"$T\" send-keys -t \"$S\" Enter\n" }
        if settle > 0 { s += "sleep \(String(format: "%.1f", min(settle, 10)))\n" }
        s += "echo \(dataMarker)\n\"$T\" capture-pane -p -J -t \"$S\" -S -\(max(1, tail))\n"
        return s
    }

    /// Lists every tmux session (LiteMux's are named `lm_<n>`).
    public static let sessions = """
    T=$(command -v tmux 2>/dev/null)
    for c in /usr/bin/tmux /usr/local/bin/tmux /opt/homebrew/bin/tmux "$HOME/.local/bin/tmux"; do [ -n "$T" ] && break; [ -x "$c" ] && T=$c; done
    [ -n "$T" ] || { echo \(noTmux); exit 0; }
    "$T" list-sessions -F '#{session_name}\t#{session_activity}\t#{session_attached}\t#{pane_current_command}\t#{pane_current_path}' 2>/dev/null
    exit 0
    """

    public static let gpu = """
    echo '## gpu'
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>&1
      echo '## procs'
      nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory,process_name --format=csv,noheader,nounits 2>/dev/null
      echo '## uuids'
      nvidia-smi --query-gpu=index,uuid --format=csv,noheader 2>/dev/null
    else
      echo 'none'
    fi
    echo '## load'
    uptime 2>/dev/null
    echo '## cpus'
    (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)
    echo '## mem'
    free -m 2>/dev/null | sed -n 2p
    echo '## disk'
    df -Ph "$HOME" 2>/dev/null | tail -n 1
    exit 0
    """

    public static func listDirectory(_ path: String) -> String {
        "P=\(pathWord(path))\ncd -- \"$P\" 2>/dev/null || { echo \"不是可进入的目录：$P\" >&2; exit 2; }\npwd\nls -lA 2>&1 | head -n 1000\n"
    }

    public static func readFile(_ path: String, maxBytes: Int, tailLines: Int?) -> String {
        var s = "P=\(pathWord(path))\n"
        s += "[ -e \"$P\" ] || { echo \"文件不存在：$P\" >&2; exit 2; }\n"
        s += "[ -d \"$P\" ] && { echo \"这是一个目录：$P，请用 list_directory\" >&2; exit 2; }\n"
        s += "[ -r \"$P\" ] || { echo \"没有读取权限：$P\" >&2; exit 2; }\n"
        s += "wc -c < \"$P\" | tr -d ' '\necho \(dataMarker)\n"
        if let tailLines {
            s += "tail -n \(max(1, tailLines)) \"$P\" | head -c \(maxBytes)\n"
        } else {
            s += "head -c \(maxBytes) \"$P\"\n"
        }
        return s
    }

    public static func run(command: String, directory: String?) -> String {
        var s = ""
        if let directory, !directory.isEmpty {
            s += "cd -- \(pathWord(directory)) || exit 125\n"
        }
        // A login bash picks up PATH from the profile (conda, CUDA) like a terminal does.
        s += "if command -v bash >/dev/null 2>&1; then exec bash -lc \(ShellWords.quote(command)) </dev/null; "
        s += "else exec sh -c \(ShellWords.quote(command)) </dev/null; fi\n"
        return s
    }

    /// Raw bytes per `write` call. The content travels base64-encoded inside
    /// the command (one argv string, which Linux caps at 128 KB), not over
    /// stdin, so a multiplexed ssh never has to forward an EOF.
    public static let writeChunk = 48 * 1024

    public static func write(path: String, chunk: Data, append: Bool) -> String {
        var s = "P=\(pathWord(path))\n"
        if !append { s += "D=$(dirname -- \"$P\")\nmkdir -p -- \"$D\" || exit 2\n" }
        // GNU, busybox and current macOS take -d; older macOS only -D.
        s += "if printf 'YQ==' | base64 -d >/dev/null 2>&1; then B='base64 -d'; else B='base64 -D'; fi\n"
        s += "printf '%s' '\(chunk.base64EncodedString())' | $B \(append ? ">>" : ">") \"$P\" || exit 2\n"
        s += "wc -c < \"$P\" | tr -d ' '\n"
        return s
    }
}

/// A failure the agent should read, not a protocol error.
public struct BridgeToolError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
