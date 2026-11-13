import Foundation

/// Minimal POSIX-shell word handling: enough to split a pasted `ssh ...` line
/// and to quote arguments we hand to a remote `sh -c`.
public enum ShellWords {

    /// Splits a command line into words, honouring single quotes, double quotes
    /// and backslash escapes. Unterminated quotes are closed at end of input.
    public static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character? = nil
        var escaping = false

        for ch in line {
            if escaping {
                current.append(ch)
                escaping = false
                inWord = true
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    escaping = true
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\\":
                escaping = true
                inWord = true
            case "'", "\"":
                quote = ch
                inWord = true
            case " ", "\t", "\n", "\r":
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(ch)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Quotes a string for safe use as one word in a POSIX shell.
    public static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_-+=:,./")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Expands a leading `~` or `~/` against the given home directory.
    public static func expandTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    /// Replaces the home directory prefix with `~` for display.
    public static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
