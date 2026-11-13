import AppKit
import SwiftUI
import LiteMuxCore

/// Hosts the long-lived terminal NSView. SwiftUI may rebuild this wrapper as
/// the split tree changes; the terminal view itself (and its PTY) survives and
/// is simply re-parented.
struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession

    final class Container: NSView {
        var terminal: NSView?

        func embed(_ view: NSView) {
            guard terminal !== view || view.superview !== self else { return }
            terminal?.removeFromSuperview()
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            terminal = view
        }

        override func layout() {
            super.layout()
            terminal?.frame = bounds
        }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        c.embed(session.view)
        // Start once the view has been laid out, so the PTY gets the real size.
        Task { @MainActor in session.startIfNeeded() }
        return c
    }

    func updateNSView(_ c: Container, context: Context) {
        c.embed(session.view)
    }
}

/// Renders a split tree recursively.
struct SplitNodeView: View {
    let node: SplitNode
    let tab: WorkspaceTab
    let model: AppModel

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneView(pane: pane, tab: tab, model: model)
                .id(pane.id)
        case .split(let id, let axis, let ratio, let first, let second):
            SplitPair(axis: axis, ratio: ratio, onChange: { model.setRatio($0, split: id, in: tab) }) {
                AnyView(SplitNodeView(node: first, tab: tab, model: model))
            } second: {
                AnyView(SplitNodeView(node: second, tab: tab, model: model))
            }
        }
    }
}

/// Two children separated by a 1px divider with a generous drag target.
struct SplitPair<First: View, Second: View>: View {
    let axis: SplitAxis
    let ratio: Double
    let onChange: (Double) -> Void
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let firstLength = max(0, (total - 1) * ratio)
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first()
                    .frame(width: axis == .horizontal ? firstLength : nil,
                           height: axis == .vertical ? firstLength : nil)
                Rectangle()
                    .fill(Theme.hairlineColor)
                    .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
                    .overlay {
                        Color.clear
                            .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
                            .contentShape(Rectangle())
                            .cursor(axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                                    .onChanged { value in
                                        let start = dragStart ?? ratio
                                        if dragStart == nil { dragStart = ratio }
                                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                                        guard total > 1 else { return }
                                        onChange(start + Double(delta) / Double(total))
                                    }
                                    .onEnded { _ in dragStart = nil }
                            )
                            .onTapGesture(count: 2) { onChange(0.5) }
                    }
                    .zIndex(1)
                second()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: "split")
        }
    }
}

/// One terminal pane: the surface, a dim veil when unfocused, and a
/// reconnect hint after the connection drops.
struct PaneView: View {
    let pane: PaneSpec
    let tab: WorkspaceTab
    let model: AppModel

    var body: some View {
        let session = model.session(for: pane)
        let isFocused = tab.focusedPaneID == pane.id || (tab.focusedPaneID == nil && tab.root?.leaves.first?.id == pane.id)
        let multiple = (tab.root?.leaves.count ?? 1) > 1
        ZStack(alignment: .bottom) {
            if let session {
                TerminalSurface(session: session)
                    .padding(.leading, 6)
                    .padding(.top, 4)
                    .background(Theme.canvasColor, ignoresSafeAreaEdges: [])
                if case .ended(let code) = session.phase {
                    ReconnectBanner(remote: session.host.endpoint != nil, code: code,
                                    reconnect: { session.restart(); model.focusSoon(pane.id) },
                                    close: { model.closePane(pane.id, in: tab) })
                        .padding(10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                Text("找不到这台主机").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if multiple && !isFocused {
                Theme.canvasColor.opacity(0.32).allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: session?.phase)
    }
}

struct ReconnectBanner: View {
    let remote: Bool
    let code: Int32?
    let reconnect: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: remote ? "bolt.horizontal.circle" : "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(remote && code == 255 ? "连接已断开" : "会话已结束")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 12)
            Button("关闭窗格", action: close)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            Button(action: reconnect) {
                Text(remote ? "重新连接 ⏎" : "重新打开 ⏎").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairlineColor))
        .frame(maxWidth: 440)
    }
}
