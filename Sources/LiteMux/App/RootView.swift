import SwiftUI
import LiteMuxCore

/// Window layout: sidebar | (top bar / workspace), status bar across the bottom.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var dragStartWidth: Double?

    var body: some View {
        GeometryReader { geo in
            // The title bar row; our bars share it with the traffic lights.
            let titlebar = max(30, geo.safeAreaInsets.top)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if model.sidebarVisible {
                        SidebarView(model: model, titlebarHeight: titlebar)
                            .frame(width: model.sidebarWidth)
                            .transition(.move(edge: .leading))
                        resizer
                    }
                    VStack(spacing: 0) {
                        TopBar(model: model, height: titlebar)
                        WorkspaceView(model: model)
                    }
                }
                StatusBarView(monitor: model.monitor, transfers: model.transfers)
            }
            .ignoresSafeArea()
        }
        .background(Theme.canvasColor)
        .overlay(alignment: .bottom) { ToastView(model: model).padding(.bottom, 36) }
        .sheet(item: $model.connectionSheet) { draft in
            NewConnectionSheet(model: model, draft: draft)
        }
        .animation(.easeOut(duration: 0.18), value: model.sidebarVisible)
        .animation(.easeOut(duration: 0.2), value: model.toastItem)
        .frame(minWidth: 720, minHeight: 420)
    }

    /// The 1px sidebar edge doubles as a drag handle (180–420pt).
    private var resizer: some View {
        Rectangle()
            .fill(Theme.hairlineColor)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .cursor(.resizeLeftRight)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { v in
                            let start = dragStartWidth ?? model.sidebarWidth
                            if dragStartWidth == nil { dragStartWidth = model.sidebarWidth }
                            model.setSidebarWidth(start + v.translation.width)
                        }
                        .onEnded { _ in dragStartWidth = nil })
            }
            .zIndex(2)
    }
}

struct ToastView: View {
    let model: AppModel

    var body: some View {
        if let t = model.toastItem {
            HStack(spacing: 10) {
                Image(systemName: icon(t.style))
                    .foregroundStyle(t.style == .error ? Color(nsColor: .systemOrange) : Color.secondary)
                Text(t.text).font(.system(size: 12)).lineLimit(2)
                if let title = t.actionTitle, let action = t.action {
                    Button(title) { action(); model.toastItem = nil }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairlineColor))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }

    private func icon(_ s: Toast.Style) -> String {
        switch s {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }
}
