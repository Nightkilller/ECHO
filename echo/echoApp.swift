//
//  echoApp.swift
//  echo
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct echoApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private let companionManager = CompanionManager()
    private var panelManager: MenuBarPanelManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Redirect stdout and stderr to echo.log in the project root so it can be monitored via tail -f
        let logPath = "/Users/adityagupta/Desktop/KURSOR/clicky-main/echo.log"
        _ = freopen(logPath, "w", stdout)
        _ = freopen(logPath, "w", stderr)

        print("🎯 Echo: Starting...")
        print("🎯 Echo: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        companionManager.start()
        
        // Instantiate the MenuBarPanelManager which handles the status item and attached dropdown panel
        panelManager = MenuBarPanelManager(companionManager: companionManager)
        panelManager?.showPanelOnLaunch()

        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelManager?.showPanel()
        return true
    }

    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Echo: Registered as login item")
            } catch {
                print("⚠️ Echo: Failed to register as login item: \(error)")
            }
        }
    }
}
