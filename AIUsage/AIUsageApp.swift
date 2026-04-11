import SwiftUI

@main
struct AIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    
    var body: some Scene {
        // 主窗口（可选显示）
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, idealWidth: 1100, minHeight: 600, idealHeight: 700)
                .preferredColorScheme(appState.isDarkMode ? .dark : .light)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    // TODO: 实现自动更新
                }
                Divider()
                Button("Preferences...") {
                    appState.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        
        // 设置窗口
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// 应用代理，用于菜单栏集成
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 创建菜单栏图标
        setupMenuBar()
        
        // 隐藏 Dock 图标（可选）
        if UserDefaults.standard.bool(forKey: "hideDockIcon") {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "AIUsage")
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        // 创建弹出菜单
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: menuText("Open Dashboard", "打开仪表盘"), action: #selector(openDashboard), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: menuText("Open Cost Tracking", "打开费用追踪"), action: #selector(openCostTracking), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: menuText("Refresh All", "全部刷新"), action: #selector(refreshAll), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: menuText("Settings...", "设置..."), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: menuText("Quit AIUsage", "退出 AIUsage"), action: #selector(quit), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc func togglePopover() {
        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                showPopover()
            }
        } else {
            showPopover()
        }
    }
    
    func showPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 500)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover
        
        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    
    @objc func openDashboard() {
        openMainWindow(section: .dashboard)
    }

    @objc func openCostTracking() {
        openMainWindow(section: .costTracking)
    }

    func openMainWindow(section: AppSection) {
        AppState.shared.selectedSection = section
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.max(by: { $0.frame.width < $1.frame.width }) ?? NSApp.windows.first
        if let window {
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @objc func refreshAll() {
        AppState.shared.refreshAllProviders()
    }
    
    @objc func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func menuText(_ en: String, _ zh: String) -> String {
        AppState.shared.language == "zh" ? zh : en
    }
}
