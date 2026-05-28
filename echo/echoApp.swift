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
final class CompanionAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private let companionManager = CompanionManager()
    private var dismissPanelObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Redirect stdout and stderr to echo.log in the project root so it can be monitored via tail -f
        let logPath = "/Users/adityagupta/Desktop/KURSOR/clicky-main/echo.log"
        _ = freopen(logPath, "w", stdout)
        _ = freopen(logPath, "w", stderr)

        print("🎯 Echo: Starting...")
        print("🎯 Echo: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        companionManager.start()
        createStatusItem()
        
        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .echoDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mainWindow?.orderOut(nil)
            }
        }
        
        // Show main window on launch so user can see permissions & enter Groq API key
        showMainWindow()
        
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        companionManager.stop()
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeEchoMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    private func makeEchoMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    @objc private func statusItemClicked() {
        if let mainWindow, mainWindow.isVisible {
            mainWindow.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    func showMainWindow() {
        if mainWindow == nil {
            let panelView = CompanionPanelView(companionManager: companionManager)
                .frame(width: 320)
            let hostingView = NSHostingView(rootView: panelView)
            
            // Set size from fitting size
            let fittingSize = hostingView.fittingSize
            let windowWidth: CGFloat = 320
            let windowHeight: CGFloat = fittingSize.height > 100 ? fittingSize.height : 450
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Echo Settings"
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(red: 16.0/255.0, green: 18.0/255.0, blue: 17.0/255.0, alpha: 1.0) // match DS.Colors.background
            window.contentView = hostingView
            window.delegate = self
            window.center()
            self.mainWindow = window
        }
        
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false // Hide the window instead of closing/destroying it
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
