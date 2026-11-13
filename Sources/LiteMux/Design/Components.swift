import AppKit
import SwiftUI

/// Native vibrancy (sidebar material) behind SwiftUI content.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Empty title-bar areas: drag to move the window, double-click to zoom/minimise
/// following the user's system preference.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
                return
            }
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// A quiet borderless icon button used in the bars.
struct BarButton: View {
    let systemName: String
    let help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The selected tab or segment: a sheet of paper lifted a hair off the bar.
struct RaisedPlate: View {
    var cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(Theme.raisedColor)
            .overlay(shape.strokeBorder(Theme.hairlineColor, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.07), radius: 1.5, y: 0.5)
    }
}

/// Online / offline indicator.
struct StatusDot: View {
    var online: Bool
    var warning = false

    var body: some View {
        Circle()
            .fill(online ? Color(nsColor: warning ? Theme.warning : Theme.online) : Color.clear)
            .overlay(Circle().strokeBorder(online ? Color.clear : Color.secondary.opacity(0.6), lineWidth: 1))
            .frame(width: 7, height: 7)
    }
}

/// A two-option segmented switch drawn in the restrained bar style.
struct SegmentedSwitch<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let value = option.0
                let title = option.1
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: selection == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                        .background { if selection == value { RaisedPlate(cornerRadius: 5) } }
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == value ? .primary : .secondary)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

/// Changes the cursor while hovering, e.g. for split dividers.
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
