import AppKit
import SwiftUI
import LiteMuxCore

/// AppKit owns the lifecycle and the menu bar so window-level ⌘ shortcuts can
/// never swallow terminal control keys, and ⌘W closes a pane, not the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var model: AppModel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        NSApp.mainMenu = MainMenu.build(target: self)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "LiteMux"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // No NSToolbar: on macOS 26 its glass background would cover our bar.
        // The SwiftUI top bar draws straight into the transparent title-bar row.
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.backgroundColor = Theme.canvas
        window.delegate = self
        window.setFrameAutosaveName("LiteMuxMainWindow")
        if !window.setFrameUsingName("LiteMuxMainWindow") { window.center() }

        let host = NSHostingView(rootView: RootView(model: model))
        host.sizingOptions = []
        window.contentView = host
        window.contentMinSize = NSSize(width: 720, height: 420)
        window.makeKeyAndOrderFront(nil)
        model.window = window
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        if let tab = model.selectedTab, let pane = tab.focusedPane { model.focusSoon(pane.id) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.prepareToQuit() ? .terminateNow : .terminateCancel
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Cheap: picks up hosts added to ~/.ssh/config while we were away.
        model?.reloadSSHConfig()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menu actions

    @objc func newConnection(_ sender: Any?) { model.presentNewConnection() }
    @objc func newTab(_ sender: Any?) { model.newTerminalTab() }
    @objc func newLocalTab(_ sender: Any?) { model.openTerminalTab(host: .local) }
    @objc func closeFocused(_ sender: Any?) { model.closeFocused() }
    @objc func saveDocument(_ sender: Any?) { model.saveActiveEditor() }
    @objc func splitHorizontally(_ sender: Any?) { model.split(.horizontal) }
    @objc func splitVertically(_ sender: Any?) { model.split(.vertical) }
    @objc func equalizeSplits(_ sender: Any?) { model.equalizeSplits() }
    @objc func toggleLiteSidebar(_ sender: Any?) { model.toggleSidebar() }
    @objc func showHosts(_ sender: Any?) { model.setSidebarMode(.hosts) }
    @objc func showFiles(_ sender: Any?) { model.setSidebarMode(.files) }
    @objc func nextTab(_ sender: Any?) { model.selectTab(offset: 1) }
    @objc func previousTab(_ sender: Any?) { model.selectTab(offset: -1) }
    @objc func selectTabNumber(_ sender: NSMenuItem) { model.selectTab(number: sender.tag) }
    @objc func biggerFont(_ sender: Any?) { model.adjustFontSize(1) }
    @objc func smallerFont(_ sender: Any?) { model.adjustFontSize(-1) }
    @objc func resetFont(_ sender: Any?) { model.adjustFontSize(0) }
    @objc func appearanceSystem(_ sender: Any?) { model.setAppearance(.system) }
    @objc func appearanceLight(_ sender: Any?) { model.setAppearance(.light) }
    @objc func appearanceDark(_ sender: Any?) { model.setAppearance(.dark) }
    @objc func reloadConfig(_ sender: Any?) { model.reloadSSHConfig(); model.toast("已重新读取 ~/.ssh/config", style: .info) }
    @objc func refreshFiles(_ sender: Any?) { model.files.refresh() }
    @objc func openSSHConfig(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config"))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model else { return false }
        switch item.action {
        case #selector(saveDocument(_:)):
            return model.activeEditor?.isDirty == true
        case #selector(closeFocused(_:)):
            return model.selectedTab != nil
        case #selector(equalizeSplits(_:)):
            return (model.selectedTab?.root?.leaves.count ?? 0) > 1
        case #selector(nextTab(_:)), #selector(previousTab(_:)):
            return model.tabs.count > 1
        case #selector(toggleLiteSidebar(_:)):
            item.title = model.sidebarVisible ? "隐藏侧边栏" : "显示侧边栏"
            return true
        case #selector(appearanceSystem(_:)):
            item.state = model.state.appearance == .system ? .on : .off
            return true
        case #selector(appearanceLight(_:)):
            item.state = model.state.appearance == .light ? .on : .off
            return true
        case #selector(appearanceDark(_:)):
            item.state = model.state.appearance == .dark ? .on : .off
            return true
        default:
            return true
        }
    }

    // ⌘W is ours; the red close button still closes (and quits) as usual.
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }
}

@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // `chain: true` leaves the target nil so the action travels the responder chain.
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                  chain: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = chain ? nil : target
            return i
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
            return top
        }

        // App menu
        let appName = "LiteMux"
        _ = submenu(appName, [
            item("关于 \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", [], chain: true),
            .separator(),
            item("隐藏 \(appName)", #selector(NSApplication.hide(_:)), "h", chain: true),
            item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], chain: true),
            item("全部显示", #selector(NSApplication.unhideAllApplications(_:)), "", [], chain: true),
            .separator(),
            item("退出 \(appName)", #selector(NSApplication.terminate(_:)), "q", chain: true),
        ])

        // File
        _ = submenu("文件", [
            item("新建连接…", #selector(AppDelegate.newConnection(_:)), "n"),
            item("新建终端标签页", #selector(AppDelegate.newTab(_:)), "t"),
            item("新建本机终端", #selector(AppDelegate.newLocalTab(_:)), "t", [.command, .shift]),
            .separator(),
            item("关闭窗格 / 标签页", #selector(AppDelegate.closeFocused(_:)), "w"),
            item("保存", #selector(AppDelegate.saveDocument(_:)), "s"),
            .separator(),
            item("重新读取 ~/.ssh/config", #selector(AppDelegate.reloadConfig(_:)), "r", [.command, .shift]),
            item("在编辑器中打开 ~/.ssh/config", #selector(AppDelegate.openSSHConfig(_:)), "", []),
        ])

        // Edit — standard selectors travel the responder chain to the terminal or editor.
        _ = submenu("编辑", [
            item("撤销", Selector(("undo:")), "z", chain: true),
            item("重做", Selector(("redo:")), "z", [.command, .shift], chain: true),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x", chain: true),
            item("复制", #selector(NSText.copy(_:)), "c", chain: true),
            item("粘贴", #selector(NSText.paste(_:)), "v", chain: true),
            item("全选", #selector(NSText.selectAll(_:)), "a", chain: true),
            .separator(),
            item("查找…", #selector(NSResponder.performTextFinderAction(_:)), "f", chain: true).tagged(NSTextFinder.Action.showFindInterface.rawValue),
        ])

        // View
        let appearance = NSMenu(title: "外观")
        appearance.addItem(item("跟随系统", #selector(AppDelegate.appearanceSystem(_:)), "", []))
        appearance.addItem(item("浅色 · 纸面", #selector(AppDelegate.appearanceLight(_:)), "", []))
        appearance.addItem(item("深色 · 暗房", #selector(AppDelegate.appearanceDark(_:)), "", []))
        let appearanceItem = NSMenuItem(title: "外观", action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance

        _ = submenu("显示", [
            item("隐藏侧边栏", #selector(AppDelegate.toggleLiteSidebar(_:)), "b"),
            item("主机", #selector(AppDelegate.showHosts(_:)), "1", [.command, .option]),
            item("文件", #selector(AppDelegate.showFiles(_:)), "2", [.command, .option]),
            item("刷新文件树", #selector(AppDelegate.refreshFiles(_:)), "r"),
            .separator(),
            item("左右分屏", #selector(AppDelegate.splitHorizontally(_:)), "d"),
            item("上下分屏", #selector(AppDelegate.splitVertically(_:)), "d", [.command, .shift]),
            item("均分窗格", #selector(AppDelegate.equalizeSplits(_:)), "=", [.command, .control]),
            .separator(),
            item("放大", #selector(AppDelegate.biggerFont(_:)), "="),
            item("缩小", #selector(AppDelegate.smallerFont(_:)), "-"),
            item("实际大小", #selector(AppDelegate.resetFont(_:)), "0"),
            .separator(),
            appearanceItem,
            .separator(),
            item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], chain: true),
        ])

        // Window
        var windowItems: [NSMenuItem] = [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", chain: true),
            item("缩放", #selector(NSWindow.performZoom(_:)), "", [], chain: true),
            .separator(),
            item("下一个标签页", #selector(AppDelegate.nextTab(_:)), "}"),
            item("上一个标签页", #selector(AppDelegate.previousTab(_:)), "{"),
            .separator(),
        ]
        for n in 1...9 {
            let i = item(n == 9 ? "最后一个标签页" : "标签页 \(n)", #selector(AppDelegate.selectTabNumber(_:)), "\(n)")
            i.tag = n
            windowItems.append(i)
        }
        let windowMenu = submenu("窗口", windowItems)
        NSApp.windowsMenu = windowMenu.submenu

        return main
    }
}

private extension NSMenuItem {
    func tagged(_ t: Int) -> NSMenuItem {
        tag = t
        return self
    }
}
