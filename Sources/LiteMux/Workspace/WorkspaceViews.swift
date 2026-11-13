import AppKit
import SwiftUI
import LiteMuxCore

/// The bar that shares the window's title-bar row: tabs on the left,
/// a few actions on the right.
struct TopBar: View {
    let model: AppModel
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            if !model.sidebarVisible {
                Color.clear.frame(width: 70, height: 1)
                BarButton(systemName: "sidebar.left", help: "显示侧边栏 ⌘B") { model.toggleSidebar() }
            }
            TabStrip(model: model)
            BarButton(systemName: "plus", help: "新建连接 ⌘N") { model.presentNewConnection() }
            Rectangle().fill(Theme.hairlineColor).frame(width: 1, height: 14)
            BarButton(systemName: "rectangle.split.2x1", help: "左右分屏 ⌘D") { model.split(.horizontal) }
            BarButton(systemName: "rectangle.split.1x2", help: "上下分屏 ⇧⌘D") { model.split(.vertical) }
            AppearanceMenu(model: model)
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(WindowDragArea())
        .background(Theme.chromeColor)
        .hairline(.bottom)
    }
}

struct AppearanceMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            Picker("外观", selection: Binding(get: { model.state.appearance }, set: { model.setAppearance($0) })) {
                Text("跟随系统").tag(PersistedState.Appearance.system)
                Text("浅色 · 纸面").tag(PersistedState.Appearance.light)
                Text("深色 · 暗房").tag(PersistedState.Appearance.dark)
            }
            .pickerStyle(.inline)
            Divider()
            Button("放大字号") { model.adjustFontSize(1) }
            Button("缩小字号") { model.adjustFontSize(-1) }
            Button("恢复默认字号") { model.adjustFontSize(0) }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 13))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("外观")
    }
}

/// Tabs share the bar's width like Safari's compact tabs: they shrink
/// before they ever scroll, so the strip never needs a scroll view.
struct TabStrip: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.tabs) { tab in
                TabChip(tab: tab, model: model, selected: tab.id == model.selectedTabID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

struct TabChip: View {
    let tab: WorkspaceTab
    let model: AppModel
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let dirty = tab.editor?.isDirty ?? false
        let hostID = tab.hostID ?? ""
        HStack(spacing: 6) {
            if tab.isTerminal {
                StatusDot(online: model.isOnline(hostID))
            } else {
                Image(systemName: "doc.text").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Text(model.tabTitle(tab))
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if let count = tab.root?.leaves.count, count > 1 {
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            ZStack {
                if dirty && !hovering {
                    Circle().fill(Color.primary.opacity(0.55)).frame(width: 6, height: 6)
                } else {
                    Button {
                        model.closeTab(tab.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hovering || selected ? 1 : 0)
                }
            }
            .frame(width: 14)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 64, maxWidth: 220, minHeight: 24, maxHeight: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.primary.opacity(0.085) : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .foregroundStyle(selected ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { hovering = $0 }
        .contextMenu {
            if tab.isTerminal {
                Button("左右分屏") { model.selectTab(tab.id); model.split(.horizontal) }
                Button("上下分屏") { model.selectTab(tab.id); model.split(.vertical) }
                Button("均分窗格") { model.selectTab(tab.id); model.equalizeSplits() }
                Divider()
            }
            Button("关闭标签页") { model.closeTab(tab.id) }
        }
        .help(tab.editor?.path ?? model.tabTitle(tab))
    }
}

/// The main area under the top bar.
struct WorkspaceView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let tab = model.selectedTab {
                if let root = tab.root {
                    SplitNodeView(node: root, tab: tab, model: model)
                        .id(tab.id)
                } else if let doc = tab.editor {
                    EditorPane(document: doc, model: model)
                        .id(tab.id)
                }
            } else {
                EmptyWorkspace(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasColor, ignoresSafeAreaEdges: [])
    }
}

struct EmptyWorkspace: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("LiteMux")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                Text("轻量的 SSH 与 tmux 工作台")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                ShortcutRow(keys: "⌘N", text: "新建或粘贴 SSH 连接")
                ShortcutRow(keys: "⌘T", text: "在当前主机打开终端")
                ShortcutRow(keys: "⌘D", text: "左右分屏，每个窗格独立 tmux 槽位")
                ShortcutRow(keys: "⌘B", text: "收起侧边栏")
            }
            HStack(spacing: 10) {
                Button("打开本机终端") { model.openTerminalTab(host: .local) }
                Button("新建连接…") { model.presentNewConnection() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(40)
    }
}

private struct ShortcutRow: View {
    let keys: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
    }
}
