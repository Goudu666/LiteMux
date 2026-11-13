import AppKit

/// Deliberately small regex highlighter: comments, strings, numbers, keys and
/// keywords. Enough to read configs and scripts at a glance, nothing more.
struct SyntaxHighlighter {
    enum Language {
        case python, shell, yaml, json, toml, markdown, cLike, plain

        init(fileExtension ext: String, fileName: String) {
            switch ext {
            case "py", "pyi": self = .python
            case "sh", "bash", "zsh", "env": self = .shell
            case "yaml", "yml": self = .yaml
            case "json", "ipynb": self = .json
            case "toml", "ini", "cfg", "conf": self = .toml
            case "md", "markdown": self = .markdown
            case "c", "h", "cc", "cpp", "hpp", "cu", "js", "ts", "swift", "go", "rs", "java": self = .cLike
            default:
                let lower = fileName.lowercased()
                if lower.hasPrefix(".bash") || lower.hasPrefix(".zsh") || lower == ".profile" || lower == "makefile" {
                    self = .shell
                } else if lower == ".tmux.conf" || lower == "config" {
                    self = .toml
                } else {
                    self = .plain
                }
            }
        }
    }

    struct Rule {
        let regex: NSRegularExpression
        let color: NSColor
        let group: Int
    }

    var font: NSFont = Theme.monoFont(13)
    private let rules: [Rule]
    static let maxHighlightLength = 400_000

    init(language: Language) {
        rules = Self.rules(for: language)
    }

    func apply(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: Theme.canvasText], range: full)
        if storage.length <= Self.maxHighlightLength {
            let text = storage.string
            for rule in rules {
                rule.regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                    guard let match else { return }
                    let r = match.range(at: rule.group)
                    if r.location != NSNotFound { storage.addAttribute(.foregroundColor, value: rule.color, range: r) }
                }
            }
        }
        storage.endEditing()
    }

    // MARK: Palette

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func c(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        return NSColor(name: nil) { a in Theme.isDark(a) ? c(dark) : c(light) }
    }

    static let comment = dyn(0x9A968C, 0x6F727A)
    static let string = dyn(0x4E8A57, 0x9CC78F)
    static let number = dyn(0xB0662A, 0xE0A46A)
    static let keyword = dyn(0x8A4FA6, 0xC49AE3)
    static let key = dyn(0x2E7D74, 0x7CCBBE)
    static let heading = dyn(0x2F2E2A, 0xF0F0EC)

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        // Patterns are literals in this file; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func rules(for language: Language) -> [Rule] {
        let numbers = Rule(regex: re(#"(?<![\w.])-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\b"#), color: number, group: 0)
        let dq = Rule(regex: re(#""(?:[^"\\\n]|\\.)*""#), color: string, group: 0)
        let sq = Rule(regex: re(#"'(?:[^'\\\n]|\\.)*'"#), color: string, group: 0)
        let hashComment = Rule(regex: re(#"(?<![\w$"'])#.*$"#), color: comment, group: 0)

        func keywords(_ words: [String]) -> Rule {
            Rule(regex: re("\\b(?:" + words.joined(separator: "|") + ")\\b"), color: keyword, group: 0)
        }

        switch language {
        case .python:
            return [
                numbers,
                keywords(["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or",
                          "import", "from", "as", "with", "try", "except", "finally", "raise", "yield", "lambda",
                          "pass", "break", "continue", "None", "True", "False", "self", "async", "await", "is", "global"]),
                Rule(regex: re(#"^\s*@[\w.]+"#), color: keyword, group: 0),
                dq, sq,
                Rule(regex: re(#"(?s)(\"\"\"|''').*?\1"#, []), color: string, group: 0),
                hashComment,
            ]
        case .shell:
            return [
                numbers,
                keywords(["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in",
                          "function", "export", "local", "return", "source", "alias", "unset", "set"]),
                Rule(regex: re(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#), color: key, group: 0),
                dq, sq, hashComment,
            ]
        case .yaml:
            return [
                numbers,
                Rule(regex: re(#"\b(?:true|false|null|yes|no|on|off)\b"#, [.anchorsMatchLines, .caseInsensitive]), color: keyword, group: 0),
                Rule(regex: re(#"^\s*-?\s*([\w.\-/]+)\s*:(?=\s|$)"#), color: key, group: 1),
                dq, sq, hashComment,
            ]
        case .json:
            return [
                numbers,
                Rule(regex: re(#"\b(?:true|false|null)\b"#), color: keyword, group: 0),
                dq,
                Rule(regex: re(#"("(?:[^"\\\n]|\\.)*")\s*:"#), color: key, group: 1),
            ]
        case .toml:
            return [
                numbers,
                Rule(regex: re(#"\b(?:true|false)\b"#), color: keyword, group: 0),
                Rule(regex: re(#"^\s*\[[^\]\n]+\]"#), color: keyword, group: 0),
                Rule(regex: re(#"^\s*([\w.\-]+)\s*="#), color: key, group: 1),
                dq, sq, hashComment,
            ]
        case .markdown:
            return [
                Rule(regex: re(#"^#{1,6}\s.*$"#), color: heading, group: 0),
                Rule(regex: re(#"`[^`\n]+`"#), color: string, group: 0),
                Rule(regex: re(#"^```.*$"#), color: comment, group: 0),
                Rule(regex: re(#"\[[^\]\n]+\]\([^)\n]+\)"#), color: key, group: 0),
            ]
        case .cLike:
            return [
                numbers,
                keywords(["if", "else", "for", "while", "return", "switch", "case", "break", "continue", "struct",
                          "class", "func", "let", "var", "const", "static", "void", "int", "float", "double", "bool",
                          "true", "false", "null", "nil", "import", "include", "public", "private", "fn", "impl",
                          "package", "type", "interface", "new", "auto", "template", "namespace", "using", "__global__"]),
                Rule(regex: re(#"^\s*#\s*\w+"#), color: keyword, group: 0),
                dq, sq,
                Rule(regex: re(#"//.*$"#), color: comment, group: 0),
                Rule(regex: re(#"(?s)/\*.*?\*/"#, []), color: comment, group: 0),
            ]
        case .plain:
            return []
        }
    }
}
