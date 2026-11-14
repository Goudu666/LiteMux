import Foundation

/// A small, forgiving reader for the shell one-liners coding agents write:
/// quotes, `&&` / `||` / `;` / `|` chains, `$( … )`, comments and heredocs.
/// It is not a shell; it only needs to find the commands in a line and keep
/// quoted arguments in one piece.
public enum ShellScan {

    /// One simple command: its words and, if it read a heredoc, the body.
    public struct Segment: Hashable, Sendable {
        public var words: [String]
        public var heredoc: String?

        public init(words: [String], heredoc: String? = nil) {
            self.words = words
            self.heredoc = heredoc
        }
    }

    enum Token: Equatable {
        case word(String)
        case op(String)
        case heredoc(String)
    }

    /// Splits a command line into simple commands.
    public static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var current = Segment(words: [])
        func flush() {
            if !current.words.isEmpty { out.append(current) }
            current = Segment(words: [])
        }
        for token in tokenize(text) {
            switch token {
            case .word(let w): current.words.append(w)
            case .heredoc(let body): current.heredoc = (current.heredoc.map { $0 + "\n" } ?? "") + body
            case .op: flush()
            }
        }
        flush()
        return out
    }

    static func tokenize(_ text: String) -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var word = ""
        var inWord = false
        var i = 0

        func endWord() {
            if inWord { tokens.append(.word(word)) }
            word = ""
            inWord = false
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count {
                    if chars[i + 1] == "\n" { i += 2; continue }  // line continuation
                    word.append(chars[i + 1])
                    inWord = true
                    i += 2
                } else {
                    i += 1
                }
                continue
            case "'":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "'" { word.append(chars[i]); i += 1 }
                i += 1
                continue
            case "\"":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                        word.append(chars[i + 1])
                        i += 2
                        continue
                    }
                    word.append(chars[i])
                    i += 1
                }
                i += 1
                continue
            case " ", "\t", "\r":
                endWord()
            case "\n":
                endWord()
                tokens.append(.op("\n"))
            case ";":
                endWord()
                tokens.append(.op(";"))
            case "|":
                endWord()
                if i + 1 < chars.count, chars[i + 1] == "|" { tokens.append(.op("||")); i += 1 } else { tokens.append(.op("|")) }
            case "&":
                if i + 1 < chars.count, chars[i + 1] == "&" {
                    endWord()
                    tokens.append(.op("&&"))
                    i += 1
                } else if let last = word.last, last == ">" || last == "<" {
                    word.append(c)  // 2>&1, >&2
                } else if i + 1 < chars.count, chars[i + 1] == ">" {
                    word.append(c)  // &> file
                    inWord = true
                } else {
                    endWord()
                    tokens.append(.op("&"))
                }
            case "(":
                if word.hasSuffix("$") {
                    word.removeLast()
                    if word.isEmpty { inWord = false }
                }
                endWord()
                tokens.append(.op("("))
            case ")":
                endWord()
                tokens.append(.op(")"))
            case "`":
                endWord()
                tokens.append(.op("`"))
            case "#" where !inWord:
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            case "<" where i + 1 < chars.count && chars[i + 1] == "<" && !(i + 2 < chars.count && chars[i + 2] == "<"):
                // Heredoc: <<EOF, <<'EOF', <<-"EOF".
                endWord()
                i += 2
                var stripTabs = false
                if i < chars.count, chars[i] == "-" { stripTabs = true; i += 1 }
                while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
                var delimiter = ""
                while i < chars.count, !" \t\n;|&<>()".contains(chars[i]) {
                    if chars[i] != "'" && chars[i] != "\"" && chars[i] != "\\" { delimiter.append(chars[i]) }
                    i += 1
                }
                guard !delimiter.isEmpty else { continue }
                // The rest of this line still belongs to the command.
                var restOfLine = ""
                while i < chars.count, chars[i] != "\n" { restOfLine.append(chars[i]); i += 1 }
                var bodyLines: [String] = []
                var lineStart = i + 1
                var closed = false
                while lineStart <= chars.count {
                    var end = lineStart
                    while end < chars.count, chars[end] != "\n" { end += 1 }
                    let line = lineStart < chars.count ? String(chars[lineStart..<end]) : ""
                    let compare = stripTabs ? String(line.drop { $0 == "\t" }) : line
                    if compare.trimmingCharacters(in: .whitespaces) == delimiter {
                        lineStart = end
                        closed = true
                        break
                    }
                    bodyLines.append(compare)
                    lineStart = end + 1
                    if end >= chars.count { break }
                }
                tokens.append(contentsOf: tokenize(restOfLine).filter { if case .heredoc = $0 { return false }; return true })
                tokens.append(.heredoc(bodyLines.joined(separator: "\n")))
                i = closed ? lineStart : chars.count
                continue
            default:
                word.append(c)
                inWord = true
            }
            i += 1
        }
        endWord()
        return tokens
    }

    /// Drops `FOO=bar` assignments and wrappers such as `sudo`, `nohup`,
    /// `timeout 30`, `env -u X` in front of the real command.
    public static func strippingWrappers(_ words: [String]) -> [String] {
        var w = words[...]
        var changed = true
        while changed, let first = w.first {
            changed = false
            if isAssignment(first) { w = w.dropFirst(); changed = true; continue }
            if ["{", "}", "!", "then", "do", "else", "elif", "if", "while", "until"].contains(first) {
                w = w.dropFirst(); changed = true; continue
            }
            let name = (first as NSString).lastPathComponent
            switch name {
            case "sudo", "nohup", "command", "exec", "time", "builtin", "caffeinate", "stdbuf", "unbuffer", "nice":
                w = w.dropFirst()
                // Their own flags (`sudo -E`, `sudo -u bob`, `nice -n 5`, `stdbuf -oL`).
                while let f = w.first, f.hasPrefix("-") {
                    w = w.dropFirst()
                    let takesValue = (name == "sudo" && (f == "-u" || f == "-g")) || (name == "nice" && f == "-n")
                    if takesValue, w.first != nil { w = w.dropFirst() }
                }
                changed = true
            case "env":
                w = w.dropFirst()
                while let f = w.first, f.hasPrefix("-") || isAssignment(f) {
                    w = w.dropFirst()
                    if f == "-u", w.first != nil { w = w.dropFirst() }
                }
                changed = true
            case "timeout", "gtimeout":
                w = w.dropFirst()
                while let f = w.first, f.hasPrefix("-") { w = w.dropFirst() }
                if let f = w.first, f.first?.isNumber == true { w = w.dropFirst() }
                changed = true
            default:
                break
            }
        }
        return Array(w)
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let name = word[..<eq]
        guard let f = name.first, f.isLetter || f == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Whether a word is a redirection (`>`, `2>&1`, `>>log`, `<in`).
    static func isRedirection(_ word: String) -> Bool {
        guard let f = word.first else { return false }
        if f == ">" || f == "<" { return true }
        if f == "&", word.dropFirst().first == ">" { return true }
        if f.isNumber, let r = word.firstIndex(where: { $0 == ">" || $0 == "<" }) {
            return word[..<r].allSatisfy(\.isNumber)
        }
        return false
    }
}
