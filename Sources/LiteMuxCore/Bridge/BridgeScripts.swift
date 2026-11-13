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
    static let findTmux = """
    T=$(command -v tmux 2>/dev/null)
    for c in /usr/bin/tmux /usr/local/bin/tmux /opt/homebrew/bin/tmux "$HOME/.local/bin/tmux"; do [ -n "$T" ] && break; [ -x "$c" ] && T=$c; done
    """

    static func selectSession(_ session: String?) -> String {
        findTmux + "\n" + """
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

    public static func send(session: String?, text: String, enter: Bool, interrupt: Bool, settle: Double, tail: Int,
                            prelude: String? = nil) -> String {
        var s = (prelude ?? selectSession(session)) + "\n"
        if interrupt { s += "\"$T\" send-keys -t \"$S\" C-c\nsleep 0.3\n" }
        if !text.isEmpty { s += "\"$T\" send-keys -t \"$S\" -l -- \(ShellWords.quote(text))\n" }
        if enter { s += "\"$T\" send-keys -t \"$S\" Enter\n" }
        if settle > 0 { s += "sleep \(String(format: "%.1f", min(settle, 10)))\n" }
        s += "echo \(dataMarker)\n\"$T\" capture-pane -p -J -t \"$S\" -S -\(max(1, tail))\n"
        return s
    }

    public static let busyMarker = "@@lm-busy "
    /// What a pane counts as idle: a shell at its prompt.
    public static let shells: Set<String> = ["bash", "zsh", "fish", "sh", "dash", "ksh", "mksh", "tcsh", "csh", "ash", "login", "nu", "xonsh"]

    /// The program in the pane's foreground (`#{pane_current_command}`).
    public static func paneCommand(session: String?) -> String {
        selectSession(session) + "\n\"$T\" display-message -p -t \"$S\" '#{pane_current_command}'\n"
    }

    /// Starts a detached `lm_<n>` session with the first slot that is neither
    /// open in LiteMux nor already on the server.
    public static func newSession(directory: String?, avoiding slots: [Int]) -> String {
        var s = findTmux + "\n[ -n \"$T\" ] || { echo \(noTmux); exit 3; }\n"
        s += "n=1\nwhile :; do\n  case \" \(slots.map(String.init).joined(separator: " ")) \" in *\" $n \"*) n=$((n+1)); continue;; esac\n"
        s += "  \"$T\" has-session -t \"=lm_$n\" 2>/dev/null || break\n  n=$((n+1))\ndone\n"
        if let directory, !directory.isEmpty {
            s += "D=\(pathWord(directory))\n[ -d \"$D\" ] || { echo \"目录不存在：$D\" >&2; exit 2; }\n"
            s += "\"$T\" new-session -d -s \"lm_$n\" -c \"$D\" || exit 2\n"
        } else {
            s += "cd \"$HOME\" 2>/dev/null; \"$T\" new-session -d -s \"lm_$n\" || exit 2\n"
        }
        s += "S=lm_$n\necho \"\(sessionMarker)$S\"\nsleep 0.4\n"
        return s
    }

    /// Lists every tmux session (LiteMux's are named `lm_<n>`).
    public static let sessions = findTmux + "\n" + """
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

    /// Listening TCP sockets, each line prefixed with the tool (see `ListeningPort.parse`).
    public static let listeningPorts = """
    if command -v ss >/dev/null 2>&1; then ss -ltnp 2>/dev/null | tail -n +2 | sed 's/^/ss /'
    elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | tail -n +2 | sed 's/^/lsof /'
    elif command -v netstat >/dev/null 2>&1; then netstat -ltnp 2>/dev/null | grep LISTEN | sed 's/^/netstat /'
    fi
    """

    /// `gpu` plus top processes, every real mount, listening ports, failed
    /// systemd units and Docker containers. Each probe is optional.
    public static let hostStatus = gpu.replacingOccurrences(of: "\nexit 0", with: "") + """

    echo '## mounts'
    df -Ph 2>/dev/null | awk 'NR>1 && $1 !~ /^(tmpfs|devtmpfs|shm|udev|none|devfs|map)$/ && $6 !~ /^\\/(dev|sys|proc|run|snap|boot|etc|usr|var\\/lib\\/docker|System|private\\/var\\/vm)(\\/|$)/' | head -n 16
    echo '## top'
    (ps -eo pid,pcpu,pmem,etime,comm --sort=-pcpu 2>/dev/null || ps -Ao pid,pcpu,pmem,etime,comm -r 2>/dev/null) | sed -n 2,7p
    echo '## ports'
    \(listeningPorts)
    echo '## failed'
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then systemctl --failed --no-legend --plain 2>/dev/null | head -n 20; fi
    echo '## docker'
    if command -v docker >/dev/null 2>&1; then docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | head -n 20; fi
    exit 0
    """

    public static func listDirectory(_ path: String) -> String {
        "P=\(pathWord(path))\ncd -- \"$P\" 2>/dev/null || { echo \"不是可进入的目录：$P\" >&2; exit 2; }\npwd\nls -lA 2>&1 | head -n 1000\n"
    }

    static func readableFile(_ path: String) -> String {
        var s = "P=\(pathWord(path))\n"
        s += "[ -e \"$P\" ] || { echo \"文件不存在：$P\" >&2; exit 2; }\n"
        s += "[ -d \"$P\" ] && { echo \"这是一个目录：$P，请用 list_directory\" >&2; exit 2; }\n"
        s += "[ -r \"$P\" ] || { echo \"没有读取权限：$P\" >&2; exit 2; }\n"
        return s
    }

    /// Prints `<bytes>` (and ` <lines>` for a line range), the data marker, then the text.
    public static func readFile(_ path: String, maxBytes: Int, tailLines: Int?, lines: ClosedRange<Int>? = nil) -> String {
        var s = readableFile(path)
        if let lines {
            s += "echo \"$(wc -c < \"$P\" | tr -d ' ') $(wc -l < \"$P\" | tr -d ' ')\"\necho \(dataMarker)\n"
            s += "sed -n '\(lines.lowerBound),\(lines.upperBound)p' \"$P\" | head -c \(maxBytes)\n"
        } else {
            s += "wc -c < \"$P\" | tr -d ' '\necho \(dataMarker)\n"
            if let tailLines {
                s += "tail -n \(max(1, tailLines)) \"$P\" | head -c \(maxBytes)\n"
            } else {
                s += "head -c \(maxBytes) \"$P\"\n"
            }
        }
        return s
    }

    /// The largest file `edit_file` takes.
    public static let editLimit = 2_000_000

    /// Prints `cksum` of the file, the data marker, then the whole file.
    public static func readForEdit(_ path: String) -> String {
        var s = readableFile(path)
        s += "[ -w \"$P\" ] || { echo \"没有写入权限：$P\" >&2; exit 2; }\n"
        s += "N=$(wc -c < \"$P\" | tr -d ' ')\n"
        s += "[ \"$N\" -le \(editLimit) ] || { echo \"文件有 $N 字节，超过 edit_file 的 2 MB 上限\" >&2; exit 2; }\n"
        s += "cksum < \"$P\"\necho \(dataMarker)\ncat -- \"$P\"\n"
        return s
    }

    /// Replaces the file's bytes with the staged copy, in place (inode, owner
    /// and mode stay), only if it still has the checksum we edited.
    public static func commitEdit(_ path: String, staged: String, checksum: String) -> String {
        var s = "P=\(pathWord(path))\nN=\(pathWord(staged))\n"
        s += "if [ \"$(cksum < \"$P\")\" != \(ShellWords.quote(checksum)) ]; then rm -f -- \"$N\"; echo \(changedMarker); exit 9; fi\n"
        s += "cat -- \"$N\" > \"$P\" || exit 2\nrm -f -- \"$N\"\nwc -c < \"$P\" | tr -d ' '\n"
        return s
    }

    public static let changedMarker = "@@lm-changed"

    // MARK: - Transfers

    /// `file <bytes>` or `dir`, or an error on stderr.
    public static func inspect(_ path: String) -> String {
        var s = "P=\(pathWord(path))\n"
        s += "[ -e \"$P\" ] || { echo \"不存在：$P\" >&2; exit 2; }\n"
        s += "[ -r \"$P\" ] || { echo \"没有读取权限：$P\" >&2; exit 2; }\n"
        s += "if [ -d \"$P\" ]; then echo dir; else echo \"file $(wc -c < \"$P\" | tr -d ' ')\"; fi\n"
        return s
    }

    /// Writes the file's bytes, or a gzip tar of the directory's contents, to stdout.
    public static func download(_ path: String, directory: Bool) -> String {
        let p = "P=\(pathWord(path))\n"
        if directory { return p + "cd -- \"$P\" || exit 2\nCOPYFILE_DISABLE=1 tar -czf - . || exit 2\n" }
        return p + "cat -- \"$P\"\n"
    }

    /// Reads a file's bytes (or a gzip tar to unpack) from stdin into `path`.
    public static func upload(_ path: String, directory: Bool) -> String {
        var s = "P=\(pathWord(path))\n"
        if directory {
            s += "mkdir -p -- \"$P\" || exit 2\ntar -xzf - -C \"$P\" || exit 2\ndu -sk \"$P\" 2>/dev/null | cut -f1\n"
        } else {
            s += "D=$(dirname -- \"$P\")\nmkdir -p -- \"$D\" || exit 2\n"
            s += "cat > \"$P.lm-part\" && mv -f -- \"$P.lm-part\" \"$P\" || { rm -f -- \"$P.lm-part\"; exit 2; }\n"
            s += "wc -c < \"$P\" | tr -d ' '\n"
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
