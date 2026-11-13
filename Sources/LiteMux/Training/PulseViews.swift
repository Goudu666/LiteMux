import SwiftUI
import Charts
import LiteMuxCore

// MARK: - Formatting

enum PulseFormat {
    static func value(_ v: Double, name: String = "") -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v > 0 ? "inf" : "-inf" }
        if MetricLineParser.isLearningRate(name) || (v != 0 && abs(v) < 1e-3) {
            return String(format: "%.1e", v).replacingOccurrences(of: "e-0", with: "e-").replacingOccurrences(of: ".0e", with: "e")
        }
        if abs(v) >= 1000 { return String(format: "%.0f", v) }
        if abs(v) >= 100 { return String(format: "%.1f", v) }
        if abs(v) >= 10 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        if m < 1 { return "不到 1 分钟" }
        if m < 60 { return "\(m) 分钟" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) 小时" : "\(h) 小时 \(r) 分"
    }

    static func epoch(_ run: TrainingRun) -> String? {
        guard let e = run.epoch else { return nil }
        let shown = e.rounded() == e ? String(Int(e)) : String(format: "%.2f", e)
        if let total = run.epochTotal { return "epoch \(shown)/\(total)" }
        return "epoch \(shown)"
    }

    static func trendArrow(_ s: MetricSeries) -> String {
        switch s.trend {
        case -1: return "↓"
        case 1: return "↑"
        default: return "→"
        }
    }

    /// Whether the trend is the good direction for this metric.
    static func trendIsGood(_ s: MetricSeries) -> Bool? {
        guard s.trend != 0, !s.isLearningRate else { return nil }
        return (s.trend < 0) == s.lowerIsBetter
    }
}

extension TrainingRun.Status {
    var tint: Color {
        switch self {
        case .running: return Theme.accentColor
        case .finished: return Color(nsColor: Theme.online)
        case .diverged, .crashed: return Color(nsColor: Theme.warning)
        }
    }

    var label: String {
        switch self {
        case .running: return "训练中"
        case .finished: return "已完成"
        case .diverged(let m): return "\(m) 发散"
        case .crashed: return "已中断"
        }
    }
}

// MARK: - Sparkline

/// A min/max-normalised polyline; non-finite values are skipped.
struct SparklineShape: Shape {
    var points: [MetricPoint]
    /// Shared x domain so a ghost run lines up with the current one.
    var xDomain: ClosedRange<Double>?
    var yDomain: ClosedRange<Double>?

    func path(in rect: CGRect) -> Path {
        let pts = points.filter { $0.y.isFinite }
        guard pts.count >= 2 || (pts.count == 1 && xDomain != nil) else {
            var p = Path()
            if let only = pts.first { _ = only; p.move(to: CGPoint(x: rect.minX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
            return p
        }
        let xs = xDomain ?? (pts.first!.x...pts.last!.x)
        let ys = yDomain ?? Self.domain(pts.map(\.y))
        let dx = max(xs.upperBound - xs.lowerBound, 1e-12)
        let dy = max(ys.upperBound - ys.lowerBound, 1e-12)
        var path = Path()
        for (i, p) in pts.enumerated() {
            let cg = CGPoint(x: rect.minX + CGFloat((p.x - xs.lowerBound) / dx) * rect.width,
                             y: rect.maxY - CGFloat((p.y - ys.lowerBound) / dy) * rect.height)
            if i == 0 { path.move(to: cg) } else { path.addLine(to: cg) }
        }
        return path
    }

    static func domain(_ ys: [Double]) -> ClosedRange<Double> {
        let finite = ys.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max() else { return 0...1 }
        if hi - lo < 1e-12 { return (lo - 1)...(hi + 1) }
        return lo...hi
    }
}

// MARK: - Status bar chip

/// `╱╲_ loss 0.142 ↓ · epoch 18/50` in the status bar; opens the panel.
struct PulseChip: View {
    let training: PaneTraining
    @Binding var showPanel: Bool
    @State private var hovering = false

    var body: some View {
        if let run = training.run, let primary = run.primary {
            Button { showPanel.toggle() } label: {
                HStack(spacing: 7) {
                    SparklineShape(points: Array(primary.points.suffix(120)))
                        .stroke(run.status.tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                        .frame(width: 44, height: 11)
                    HStack(spacing: 0) {
                        Text(primary.name + " ").foregroundStyle(.secondary)
                        Text(primary.last.map { PulseFormat.value($0, name: primary.name) } ?? "–")
                            .foregroundColor(run.status == .running ? .primary : run.status.tint)
                        Text(" " + PulseFormat.trendArrow(primary))
                            .foregroundColor(trendColor(primary))
                    }
                    if case .running = run.status, let e = PulseFormat.epoch(run) {
                        Text(e.replacingOccurrences(of: "epoch ", with: "")).foregroundStyle(.secondary)
                    } else if run.status != .running {
                        Text(run.status.label).foregroundColor(run.status.tint)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering || showPanel ? 0.07 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Training Pulse：点击查看完整曲线")
            .popover(isPresented: $showPanel, arrowEdge: .top) {
                PulsePanel(training: training)
            }
        }
    }

    private func trendColor(_ s: MetricSeries) -> Color {
        switch PulseFormat.trendIsGood(s) {
        case true?: return Color(nsColor: Theme.online)
        case false?: return Color(nsColor: Theme.warning)
        case nil: return .secondary
        }
    }
}

// MARK: - Panel

/// The popover: progress, one large chart, and small multiples for every metric.
struct PulsePanel: View {
    let training: PaneTraining
    @State private var selected: String?

    var body: some View {
        Group {
            if let run = training.run {
                content(run)
            } else {
                Text("还没有识别到训练输出").foregroundStyle(.secondary).padding(30)
            }
        }
        .frame(width: 468)
        .background(Theme.canvasColor)
    }

    @ViewBuilder
    private func content(_ run: TrainingRun) -> some View {
        let all = run.orderedSeries
        let focus = all.first { $0.name == selected } ?? run.primary ?? all.first
        VStack(alignment: .leading, spacing: 0) {
            header(run).padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            if let focus {
                FocusChart(series: focus, ghost: training.previous?.series(named: focus.name), tint: run.status.tint)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
            if all.count > 1 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(all) { s in
                        MetricCard(series: s, ghost: training.previous?.series(named: s.name),
                                   selected: s.name == focus?.name, tint: run.status.tint)
                            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = s.name } }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            footer(run)
        }
    }

    private func header(_ run: TrainingRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(run.status.tint).frame(width: 7, height: 7)
                Text(run.status.label).font(.system(size: 13, weight: .semibold))
                if case .crashed(let reason) = run.status {
                    Text(reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                if let e = PulseFormat.epoch(run) {
                    Text(e).font(.system(size: 11.5, design: .monospaced).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let f = run.fraction {
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.07))
                            Capsule().fill(run.status.tint).frame(width: max(3, geo.size.width * f))
                        }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(String(format: "%.0f%%", f * 100))
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 15)) { ctx in
                            if let eta = run.eta(now: ctx.date) {
                                Text("预计还需 " + PulseFormat.duration(eta))
                            } else {
                                Text("更新于 " + run.updatedAt.formatted(date: .omitted, time: .shortened))
                            }
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func footer(_ run: TrainingRun) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 10))
            Text("识别自终端输出 · 不在服务器上运行任何东西")
            Spacer()
            if training.previous != nil {
                HStack(spacing: 4) {
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 12, height: 1)
                    Text("上一次运行")
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Theme.chromeColor)
        .hairline(.top)
    }
}

/// The big chart: area + line for the current run, a dashed ghost for the previous one.
private struct FocusChart: View {
    let series: MetricSeries
    let ghost: MetricSeries?
    let tint: Color

    var body: some View {
        let pts = series.points.filter { $0.y.isFinite }
        let ghostPts = (ghost?.points ?? []).filter { $0.y.isFinite }
        let yDomain = SparklineShape.domain(pts.map(\.y) + ghostPts.map(\.y))
        let floor = yDomain.lowerBound
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(series.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let best = series.best {
                    Text("最佳 " + PulseFormat.value(best, name: series.name))
                        .font(.system(size: 11, design: .monospaced).monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(series.last.map { PulseFormat.value($0, name: series.name) } ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced).monospacedDigit())
            }
            Chart {
                ForEach(Array(ghostPts.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("epoch", p.x), y: .value("ghost", p.y), series: .value("run", "previous"))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .interpolationMethod(.monotone)
                }
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("epoch", p.x), yStart: .value("floor", floor), yEnd: .value(series.name, p.y))
                        .foregroundStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.0)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("epoch", p.x), y: .value(series.name, p.y), series: .value("run", "current"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let last = pts.last {
                    PointMark(x: .value("epoch", last.x), y: .value(series.name, last.y))
                        .foregroundStyle(tint)
                        .symbolSize(28)
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairlineColor)
                    AxisValueLabel().font(.system(size: 9.5, design: .monospaced))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.hairlineColor)
                    AxisValueLabel().font(.system(size: 9.5, design: .monospaced))
                }
            }
            .frame(height: 150)
        }
    }
}

/// One small multiple: name, latest value, best, sparkline (with ghost).
private struct MetricCard: View {
    let series: MetricSeries
    let ghost: MetricSeries?
    let selected: Bool
    let tint: Color

    var body: some View {
        let pts = series.points
        let ghostPts = ghost?.points ?? []
        let all = pts + ghostPts
        let xDomain = (all.map(\.x).min() ?? 0)...(max(all.map(\.x).max() ?? 1, (all.map(\.x).min() ?? 0) + 1e-9))
        let yDomain = SparklineShape.domain(all.map(\.y))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(series.last.map { PulseFormat.value($0, name: series.name) } ?? "–")
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced).monospacedDigit())
                Text(PulseFormat.trendArrow(series))
                    .font(.system(size: 10.5))
                    .foregroundColor(arrowColor)
            }
            ZStack {
                if !ghostPts.isEmpty {
                    SparklineShape(points: ghostPts, xDomain: xDomain, yDomain: yDomain)
                        .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
                SparklineShape(points: pts, xDomain: ghostPts.isEmpty ? nil : xDomain, yDomain: yDomain)
                    .stroke(tint.opacity(selected ? 1 : 0.8), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
            .frame(height: 26)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            shape.fill(selected ? Theme.raisedColor : Color.primary.opacity(0.03))
                .overlay(shape.strokeBorder(selected ? tint.opacity(0.45) : Theme.hairlineColor, lineWidth: selected ? 1 : 0.5))
        }
        .contentShape(Rectangle())
    }

    private var arrowColor: Color {
        switch PulseFormat.trendIsGood(series) {
        case true?: return Color(nsColor: Theme.online)
        case false?: return Color(nsColor: Theme.warning)
        case nil: return .secondary
        }
    }
}
