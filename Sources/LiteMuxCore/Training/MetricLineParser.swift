import Foundation

/// One line of training output, reduced to numbers.
public struct MetricRecord: Equatable, Sendable {
    /// Epoch as printed. Fractional for Hugging Face style `'epoch': 0.5`.
    public var epoch: Double?
    /// Total epochs when the line says `7/40`.
    public var epochTotal: Int?
    /// Step (batch / iteration) inside the epoch, or a global step.
    public var step: Int?
    public var stepTotal: Int?
    /// Metric name → value, names exactly as printed (`loss`, `val_acc`, `mAP50-95`).
    public var values: [String: Double] = [:]
    /// True for the first line of a validation table row (no epoch on the line itself).
    public var isTableRow = false

    public init(epoch: Double? = nil, epochTotal: Int? = nil, step: Int? = nil, stepTotal: Int? = nil,
                values: [String: Double] = [:]) {
        self.epoch = epoch
        self.epochTotal = epochTotal
        self.step = step
        self.stepTotal = stepTotal
        self.values = values
    }

    public var hasProgress: Bool { epoch != nil || step != nil }
    public var isEmpty: Bool { values.isEmpty && !hasProgress }
}

/// Something in the log that is not a metric but matters.
public enum LogSignal: Equatable, Sendable {
    /// A Python traceback, CUDA OOM, segfault, `Killed`…; the payload is a short reason.
    case crash(String)
    /// An explicit "training finished" message.
    case finished
}

/// Result of parsing one line.
public enum ParsedLine: Equatable, Sendable {
    case record(MetricRecord)
    case signal(LogSignal)
}

/// Turns training log lines into `MetricRecord`s.
///
/// Understands the common shapes seen on GPU servers without any configuration:
/// `key=value` / `key: value` pairs (plain prints, Keras, tqdm postfixes, mmdet,
/// detectron2), Hugging Face dict lines, `Epoch 7/40`, `Epoch [3][50/7330]`,
/// tqdm `| 450/1000 [`, and Ultralytics-style tables (a header row naming the
/// columns, then numeric rows). It is stateful only for those table headers.
public struct MetricLineParser: Sendable {
    private var tableHeader: [String]?
    private var valHeader: [String]?

    public init() {}

    // MARK: Patterns

    private static let number = #"[-+]?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?|[-+]?(?:nan|NaN|NAN|inf|Inf|INF|Infinity)"#

    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are literals; a failure is a programming error caught by the unit tests.
        try! NSRegularExpression(pattern: p, options: opts)
    }

    /// `name = 1.23`, `name: 1.23`, `'name': 1.23`
    private static let keyValue = re(#"(?<![\w.])'?([A-Za-z][A-Za-z0-9_./@-]*)'?\s*[=:]\s*("# + number + #")(?![\w.])"#)
    /// `loss 0.234` for well-known names only (whitespace separated).
    private static let bareKnown = re(#"(?<![\w./-])(loss|total_loss|acc|accuracy|lr|ppl|perplexity|val_loss|val_acc|mAP|mIoU|psnr|ssim)\s+("# + number + #")(?![\w./])"#, [.caseInsensitive])
    /// `Epoch 7/40`, `epoch: 3 / 10`, `Epoch 7 of 40`
    private static let epochOfTotal = re(#"\bepoch\b\s*[:#\[=]?\s*(\d+)\s*(?:/|of)\s*(\d+)"#, [.caseInsensitive])
    /// `Epoch(train) [3][50/7330]` (mmengine) and `Epoch [3][50/7330]` (mmcv)
    private static let epochBracket = re(#"\bepoch(?:\(\w+\))?\s*\[(\d+)\](?:\s*\[\s*(\d+)\s*/\s*(\d+)\s*\])?"#, [.caseInsensitive])
    /// `Epoch 3:` / `epoch=3` / `Epoch 3,`
    private static let epochOnly = re(#"\bepoch\b\s*[:#=]?\s*(\d+(?:\.\d+)?)(?![\d/])"#, [.caseInsensitive])
    /// `step 120/5000`, `iter: 19`, `Iteration 300`, `batch 12/80`
    private static let stepPattern = re(#"\b(?:global_step|step|iter|iteration|it|batch)\b\s*[:#=\[]?\s*(\d+)(?:\s*/\s*(\d+))?"#, [.caseInsensitive])
    /// tqdm bar: `|█████| 450/1000 [00:10<…`
    private static let tqdmCount = re(#"\|\s*(\d+)/(\d+)\s*\["#)
    /// Keras bar: `1875/1875 [=====` at the start of a line
    private static let kerasCount = re(#"^\s*(\d+)/(\d+)\s*\[[=>.\s]"#)

    private static let crashNeedles: [(String, String)] = [
        ("Traceback (most recent call last)", "Python 抛出异常"),
        ("CUDA out of memory", "CUDA out of memory"),
        ("OutOfMemoryError", "显存不足 (OOM)"),
        ("CUDA error", "CUDA error"),
        ("NCCL error", "NCCL error"),
        ("Segmentation fault", "Segmentation fault"),
        ("core dumped", "进程崩溃 (core dumped)"),
        ("RuntimeError:", "RuntimeError"),
    ]

    private static let finishNeedles = [
        "training complete", "training finished", "finished training", "training done",
        "`trainer.fit` stopped", "epochs completed in",
    ]

    // MARK: Metric names

    private static let exactNames: Set<String> = [
        "lr", "map", "f1", "auc", "mae", "mse", "rmse", "wer", "cer", "iou", "err", "fid", "ppl", "bleu",
        "top1", "top5", "acc1", "acc5", "score", "reward", "dice", "kl", "nll", "ce", "bpd", "eer",
    ]
    private static let substringNames = [
        "loss", "acc", "precision", "recall", "psnr", "ssim", "lpips", "dice", "perplexity", "reward",
        "learning_rate", "grad_norm", "gradnorm", "bleu", "rouge", "top-1", "top-5", "miou", "map50",
        "map_", "map@", "/map", "f1", "error", "auroc",
    ]
    private static let excluded: Set<String> = [
        "eta", "time", "data_time", "data", "memory", "mem", "gpu_mem", "epoch", "step", "global_step",
        "iter", "iteration", "it", "batch", "v_num", "instances", "size", "samples", "train_runtime",
        "train_samples_per_second", "train_steps_per_second", "total_flos", "seed", "num_workers",
    ]

    /// Whether `name` looks like something worth plotting.
    public static func isMetricName(_ name: String) -> Bool {
        let n = name.lowercased()
        if excluded.contains(n) || n.contains("accum") || n.hasSuffix("_time") || n.hasSuffix("/s") || n.contains("runtime") || n.contains("per_second") {
            return false
        }
        let leaf = n.split(separator: "/").last.map(String.init) ?? n
        if exactNames.contains(leaf) { return true }
        for prefix in ["val_", "train_", "test_", "eval_", "valid_"] where leaf.hasPrefix(prefix) {
            if exactNames.contains(String(leaf.dropFirst(prefix.count))) { return true }
        }
        return substringNames.contains { n.contains($0) }
    }

    /// Lower is better for these; higher is better for the rest (lr has no "best").
    public static func lowerIsBetter(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["loss", "err", "ppl", "perplexity", "mae", "mse", "rmse", "wer", "cer", "fid", "lpips", "nll", "kl", "bpd", "eer"]
            .contains { n.contains($0) }
    }

    public static func isLearningRate(_ name: String) -> Bool {
        let n = (name.lowercased().split(separator: "/").last.map(String.init) ?? name.lowercased())
        return n == "lr" || n.contains("learning_rate") || n.hasSuffix("_lr") || n.hasPrefix("lr_") || n.hasPrefix("lr-")
    }

    // MARK: Parsing

    public mutating func parse(_ rawLine: String) -> ParsedLine? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.count >= 3, line.count <= 4000 else { return nil }

        for (needle, reason) in Self.crashNeedles where line.contains(needle) {
            if needle == "RuntimeError:" || needle == "CUDA error" {
                // Keep the message itself; it is the useful part.
                return .signal(.crash(String(line.prefix(120))))
            }
            return .signal(.crash(reason))
        }
        if line == "Killed" || line.hasSuffix(" Killed") && line.count < 60 {
            return .signal(.crash("进程被系统杀死 (Killed)"))
        }
        let lower = line.lowercased()
        if Self.finishNeedles.contains(where: { lower.contains($0) }) { return .signal(.finished) }

        guard line.rangeOfCharacter(from: .decimalDigits) != nil || lower.contains("nan") else {
            if let header = Self.tableHeaderTokens(line) { tableHeader = header }
            if let header = Self.valHeaderTokens(line) { valHeader = header }
            return nil
        }
        if let header = Self.tableHeaderTokens(line) { tableHeader = header; return nil }
        if let header = Self.valHeaderTokens(line) { valHeader = header; return nil }
        if let row = tableRow(line) { return .record(row) }
        if let row = valRow(line) { return .record(row) }

        var record = MetricRecord()
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Epoch / step.
        if let m = Self.epochBracket.firstMatch(in: line, range: full) {
            record.epoch = Double(ns.substring(with: m.range(at: 1)))
            if m.range(at: 2).location != NSNotFound {
                record.step = Int(ns.substring(with: m.range(at: 2)))
                record.stepTotal = Int(ns.substring(with: m.range(at: 3)))
            }
        } else if let m = Self.epochOfTotal.firstMatch(in: line, range: full) {
            record.epoch = Double(ns.substring(with: m.range(at: 1)))
            record.epochTotal = Int(ns.substring(with: m.range(at: 2)))
        } else if let m = Self.epochOnly.firstMatch(in: line, range: full) {
            record.epoch = Double(ns.substring(with: m.range(at: 1)))
        }
        if record.step == nil {
            if let m = Self.tqdmCount.firstMatch(in: line, range: full) ?? Self.kerasCount.firstMatch(in: line, range: full) {
                record.step = Int(ns.substring(with: m.range(at: 1)))
                record.stepTotal = Int(ns.substring(with: m.range(at: 2)))
            } else if let m = Self.stepPattern.firstMatch(in: line, range: full) {
                record.step = Int(ns.substring(with: m.range(at: 1)))
                if m.range(at: 2).location != NSNotFound { record.stepTotal = Int(ns.substring(with: m.range(at: 2))) }
            }
        }

        // Metrics.
        for m in Self.keyValue.matches(in: line, range: full) {
            let name = ns.substring(with: m.range(at: 1))
            guard let value = Self.parseNumber(ns.substring(with: m.range(at: 2))) else { continue }
            switch name.lowercased() {
            case "epoch":
                if record.epoch == nil { record.epoch = value }
            case "step", "global_step", "iter", "iteration":
                if record.step == nil, value >= 0, value < 1e12 { record.step = Int(value) }
            default:
                if Self.isMetricName(name) { record.values[name] = value }
            }
        }
        for m in Self.bareKnown.matches(in: line, range: full) {
            let name = ns.substring(with: m.range(at: 1))
            if record.values[name] == nil, let value = Self.parseNumber(ns.substring(with: m.range(at: 2))) {
                record.values[name] = value
            }
        }

        // A bare `Epoch 3/10` header line is useful (progress); a bare `step 12` is not.
        if record.values.isEmpty && record.epoch == nil { return nil }
        return .record(record)
    }

    static func parseNumber(_ s: String) -> Double? {
        switch s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "+")) {
        case "nan", "-nan": return .nan
        case "inf", "infinity": return .infinity
        case "-inf", "-infinity": return -.infinity
        default: return Double(s)
        }
    }

    // MARK: Tables (Ultralytics YOLO and similar)

    /// `Epoch  GPU_mem  box_loss  cls_loss  dfl_loss  Instances  Size`
    static func tableHeaderTokens(_ line: String) -> [String]? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 3, tokens[0].lowercased() == "epoch" else { return nil }
        guard tokens.dropFirst().contains(where: { isMetricName($0) }),
              !tokens.dropFirst().contains(where: { Double($0) != nil }) else { return nil }
        return tokens
    }

    /// `Class  Images  Instances  Box(P  R  mAP50  mAP50-95)`
    static func valHeaderTokens(_ line: String) -> [String]? {
        // The header is also a tqdm bar: `…mAP50-95): 100%|███| 4/4 [00:01<00:00]`.
        let head = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line
        let tokens = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 4, tokens[0] == "Class" else { return nil }
        let cleaned = tokens.map { t -> String in
            var s = t
            for p in ["Box(", "Mask(", "Pose("] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
            if s.hasSuffix(")") { s = String(s.dropLast()) }
            return s
        }
        guard cleaned.contains(where: { $0.lowercased().hasPrefix("map") }) else { return nil }
        return cleaned
    }

    /// `  12/100   3.21G   1.234   0.876   1.102   45   640: 100%|███| 59/59 [00:10<00:00]`
    private func tableRow(_ line: String) -> MetricRecord? {
        guard let header = tableHeader else { return nil }
        let head = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line
        let tokens = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let parts = tokens[0].split(separator: "/")
        guard parts.count == 2, let e = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        var r = MetricRecord(epoch: Double(e), epochTotal: total)
        for (i, name) in header.enumerated() where i > 0 && i < tokens.count && Self.isMetricName(name) {
            if let v = Double(tokens[i]) { r.values[name] = v }
        }
        let ns = line as NSString
        if let m = Self.tqdmCount.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            r.step = Int(ns.substring(with: m.range(at: 1)))
            r.stepTotal = Int(ns.substring(with: m.range(at: 2)))
        }
        return r
    }

    /// `   all   128   929   0.64   0.53   0.61   0.45`
    private func valRow(_ line: String) -> MetricRecord? {
        guard let header = valHeader else { return nil }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count == header.count, tokens.first == "all" else { return nil }
        var r = MetricRecord()
        r.isTableRow = true
        for (i, name) in header.enumerated() where i > 0 && Self.isMetricName(name) {
            if let v = Double(tokens[i]) { r.values[name] = v }
        }
        return r.values.isEmpty ? nil : r
    }
}
