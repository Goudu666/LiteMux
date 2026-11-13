import SwiftUI
import LiteMuxCore

/// The 24pt single-line status bar for the foreground host.
struct StatusBarView: View {
    let monitor: StatusMonitor
    let transfers: TransferCenter

    var body: some View {
        let s = monitor.sample
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                StatusDot(online: monitor.health == .online, warning: monitor.health == .connecting)
                Text(monitor.hostTitle.isEmpty ? "LiteMux" : monitor.hostTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let ms = s.latencyMs {
                    Text("\(Int(ms.rounded()))ms").foregroundStyle(.secondary)
                } else if let note = healthNote {
                    Text(note).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.trailing, 4)

            if let cpu = s.cpuPercent {
                Cell { Text("CPU ").foregroundStyle(.secondary) + Text(String(format: "%.0f%%", cpu)).foregroundColor(level(cpu / 100)) }
            }
            if let used = s.memoryUsedBytes, let total = s.memoryTotalBytes, total > 0 {
                Cell {
                    Text("RAM ").foregroundStyle(.secondary)
                        + Text(Self.gib(used)).foregroundColor(level(Double(used) / Double(total)))
                        + Text("/" + Self.gib(total, decimals: 0) + "G").foregroundStyle(.secondary)
                }
            }
            if let free = s.diskFreeBytes {
                Cell { Text("Disk ").foregroundStyle(.secondary) + Text(free.compactByteString) + Text(" free").foregroundStyle(.secondary) }
            }
            if !s.gpus.isEmpty {
                Separator()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(s.gpus) { g in GPUChip(gpu: g) }
                    }
                    .padding(.horizontal, 10)
                }
                .help(s.gpus.map { "GPU\($0.index) \($0.name)  \(Int($0.memoryUsedMiB))/\(Int($0.memoryTotalMiB)) MiB  \(Int($0.utilization))%" }
                        .joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            if let t = transfers.active.first {
                HStack(spacing: 5) {
                    Image(systemName: t.direction == .upload ? "arrow.up" : "arrow.down").font(.system(size: 8.5, weight: .bold))
                    Text("\(transfers.active.count) 项传输 · \(Int(t.fraction * 100))%")
                }
                .foregroundStyle(.secondary)
                .padding(.trailing, 10)
            }
        }
        .font(.system(size: 11, design: .monospaced).monospacedDigit())
        .padding(.leading, 10)
        .frame(height: 24)
        .background(Theme.chromeColor)
        .hairline(.top)
    }

    private var healthNote: String? {
        switch monitor.health {
        case .connecting: return "连接中…"
        case .waitingForAuth: return "等待终端完成认证"
        case .offline(let reason): return reason
        default: return nil
        }
    }

    private func level(_ fraction: Double) -> Color {
        if fraction >= 0.92 { return Color(nsColor: .systemRed) }
        if fraction >= 0.80 { return Color(nsColor: .systemOrange) }
        return .primary
    }

    static func gib(_ bytes: UInt64, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", Double(bytes) / 1_073_741_824)
    }
}

private struct Cell<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 0) {
            Separator()
            content().padding(.horizontal, 10).lineLimit(1)
        }
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle().fill(Theme.hairlineColor).frame(width: 1, height: 12)
    }
}

/// `GPU0 1.2/24G 12%` with a hairline meter of memory use underneath.
private struct GPUChip: View {
    let gpu: GPUReading

    var body: some View {
        let busy = gpu.memoryFraction > 0.5 || gpu.utilization > 50
        VStack(spacing: 1.5) {
            HStack(spacing: 0) {
                Text("GPU\(gpu.index) ").foregroundStyle(.secondary)
                Text(String(format: "%.1f", gpu.memoryUsedMiB / 1024))
                    .foregroundColor(busy ? Color(nsColor: .systemOrange) : .primary)
                Text(String(format: "/%.0fG ", gpu.memoryTotalMiB / 1024)).foregroundStyle(.secondary)
                Text(String(format: "%.0f%%", gpu.utilization))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(busy ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen))
                        .frame(width: max(1.5, geo.size.width * gpu.memoryFraction))
                }
            }
            .frame(height: 1.5)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
