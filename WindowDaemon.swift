import Foundation
import AppKit
import ApplicationServices

// MARK: - Data Models
struct WindowData: Codable {
    let windowID: String
    let pid: Int32
    let appName: String
    let title: String
    let lastUsed: TimeInterval
    
    var displayString: String {
        return "\(appName) - \(title)"
    }
}

class WindowInfo {
    var windowRef: AXUIElement
    let pid: pid_t
    let appName: String
    var title: String
    let windowID: String
    var lastUsed: Date
    
    init(windowRef: AXUIElement, pid: pid_t, appName: String, title: String, windowID: String) {
        self.windowRef = windowRef
        self.pid = pid
        self.appName = appName
        self.title = title
        self.windowID = windowID
        self.lastUsed = Date()
    }
    
    var asWindowData: WindowData {
        return WindowData(
            windowID: windowID,
            pid: pid,
            appName: appName,
            title: title,
            lastUsed: lastUsed.timeIntervalSince1970
        )
    }
}

// MARK: - IPC Protocol
enum DaemonCommand: String, CaseIterable {
    case list = "list"
    case listJson = "list-json"
    case focus = "focus"
    case refresh = "refresh"
    case quit = "quit"
}

struct DaemonResponse: Codable {
    let success: Bool
    let message: String?
    let windows: [WindowData]?
}

// MARK: - Window Daemon
class WindowDaemon {
    private var windows: [String: WindowInfo] = [:]
    private let queue = DispatchQueue(label: "windowdaemon", qos: .userInteractive)
    private var refreshTimer: Timer?
    private var isRunning = true
    private let socketPath = "/tmp/windowdaemon.sock"
    
    // Helper function to ensure output is flushed
    private func logMessage(_ message: String) {
        print(message)
        fflush(stdout)
    }
    
    init() {
        setupAccessibilityPermissions()
        cleanupSocket()
        initialWindowScan()
        setupEventObservers()
        setupIPCServer()
    }
    
    private func cleanupSocket() {
        try? FileManager.default.removeItem(atPath: socketPath)
    }
    
    private func setupAccessibilityPermissions() {
        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        
        if !trusted {
            logMessage("Please grant accessibility permissions in System Preferences > Security & Privacy > Privacy > Accessibility")
        }
    }
    
    private func initialWindowScan() {
        queue.async { [weak self] in
            self?.performWindowScan()
        }
    }
    
    private func performWindowScan() {
        guard AXIsProcessTrusted() else {
            logMessage("⚠️  Accessibility permissions not granted.")
            return
        }
        
        var newWindows: [String: WindowInfo] = [:]
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated
        }
        
        for app in apps {
            guard let appName = app.localizedName else { continue }
            let pid = app.processIdentifier
            
            if shouldSkipApp(appName: appName) {
                continue
            }
            
            let appRef = AXUIElementCreateApplication(pid)
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
            
            guard result == .success, let axWindows = value as? [AXUIElement] else {
                continue
            }
            
            for (_, axWindow) in axWindows.enumerated() {
                var titleValue: AnyObject?
                let titleResult = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue)
                
                guard titleResult == .success, 
                      let title = titleValue as? String, 
                      !title.isEmpty else {
                    continue
                }
                
                if shouldSkipWindow(appName: appName, title: title) {
                    continue
                }
                
                let titleHash = abs(title.hashValue) % 10000
                let windowID = "\(pid)_\(titleHash)_\(title.prefix(10))"
                
                let windowInfo = WindowInfo(
                    windowRef: axWindow,
                    pid: pid,
                    appName: appName,
                    title: title,
                    windowID: windowID
                )
                newWindows[windowID] = windowInfo
            }
        }
        
        let windowCount = newWindows.count
        let previousCount = self.windows.count
        
        DispatchQueue.main.async { [weak self] in
            self?.windows = newWindows
            // Only print on initial scan or significant changes
            if windowCount != previousCount {
                self?.logMessage("✅ Loaded \(windowCount) windows")
            }
        }
    }
    
    private func shouldSkipApp(appName: String) -> Bool {
        let skipApps = [
            "Dock", "SystemUIServer", "Window Server", "Spotlight",
            "Control Center", "NotificationCenter", "System Preferences"
        ]
        return skipApps.contains(appName)
    }
    
    private func shouldSkipWindow(appName: String, title: String) -> Bool {
        let skipTitles = ["", "Item-0", "Window"]
        return skipTitles.contains(title) || title.count < 2
    }
    
    private func setupEventObservers() {
        let workspace = NSWorkspace.shared
        
        // App activation - scan for new windows when apps become active
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivation(notification)
        }
        
        // App launch - scan when new apps start
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppLaunch(notification)
        }
        
        // App termination - clean up windows
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppTermination(notification)
        }
        
        // Remove periodic refresh for now to focus on event handling
        // refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
        //     guard let self = self, self.isRunning else { return }
        //     self.logMessage("⏰ Periodic refresh triggered")
        //     self.refreshWindows()
        // }
    }
    
    private func updateActiveWindow() {
        // Update last used time for active app windows
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let appName = frontApp.localizedName else {
            return
        }
        
        let activeWindows = windows.values.filter { $0.appName == appName }
        for window in activeWindows {
            window.lastUsed = Date()
        }
    }
    
    private func refreshWindows() {
        logMessage("🔄 refreshWindows called - testing queue")
        queue.async { [weak self] in
            self?.logMessage("🔄 Queue is working - calling performWindowScan")
            self?.performWindowScan()
        }
    }
    
    private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        guard let appName = app.localizedName else { return }
        logMessage("🔄 App activated: \(appName) - about to queue scan")
        
        // Update last used time for windows of this app
        updateActiveWindow()
        
        // Try synchronous scan first to debug
        logMessage("🔄 Doing SYNCHRONOUS scan for \(appName)")
        scanAppWindows(app)
    }
    
    private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        guard let appName = app.localizedName else { return }
        logMessage("🚀 App launched: \(appName) - scheduling scan")
        
        // Give the app a moment to create its windows, then do synchronous scan
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.logMessage("🚀 Delayed SYNCHRONOUS scan starting for \(appName)")
            self?.scanAppWindows(app)
        }
    }
    
    private func handleAppTermination(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        // Remove windows for terminated app
        let pid = app.processIdentifier
        DispatchQueue.main.async { [weak self] in
            let removedCount = self?.windows.count ?? 0
            self?.windows = self?.windows.filter { $0.value.pid != pid } ?? [:]
            let newCount = self?.windows.count ?? 0
            
            if removedCount != newCount {
                self?.logMessage("🗑️ Removed \(removedCount - newCount) windows from terminated app: \(app.localizedName ?? "Unknown")")
            }
        }
    }
    
    private func scanAppWindows(_ app: NSRunningApplication) {
        guard let appName = app.localizedName else { 
            logMessage("❌ scanAppWindows: No app name")
            return 
        }
        let pid = app.processIdentifier
        
        logMessage("🔍 scanAppWindows CALLED for \(appName) (PID: \(pid))")
        
        if shouldSkipApp(appName: appName) {
            logMessage("⏭️ Skipping app: \(appName)")
            return
        }
        
        logMessage("🔍 Scanning \(appName) (PID: \(pid)) for new windows...")
        
        let appRef = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &value)
        
        logMessage("🔍 AXUIElementCopyAttributeValue result: \(result.rawValue)")
        
        guard result == .success, let axWindows = value as? [AXUIElement] else {
            logMessage("⚠️ Could not get windows for \(appName) - result: \(result.rawValue)")
            return
        }
        
        logMessage("📊 \(appName) reports \(axWindows.count) total AX windows")
        
        // Get current windows for this app to see what we already have
        let existingWindowsForApp = windows.values.filter { $0.pid == pid }
        logMessage("📋 We already know about \(existingWindowsForApp.count) windows for \(appName):")
        for existingWindow in existingWindowsForApp {
            logMessage("  - Existing: '\(existingWindow.title)' (ID: \(existingWindow.windowID))")
        }
        
        var newWindowsFound = 0
        var processedWindows: [String] = []
        
        for (index, axWindow) in axWindows.enumerated() {
            var titleValue: AnyObject?
            guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String,
                  !title.isEmpty else {
                logMessage("  Window \(index): no title or empty - skipping")
                continue
            }
            
            if shouldSkipWindow(appName: appName, title: title) {
                logMessage("  Window \(index): '\(title)' - SKIPPED by filter")
                continue
            }
            
            // Use same ID generation as initial scan
            let titleHash = abs(title.hashValue) % 10000
            let windowID = "\(pid)_\(titleHash)_\(title.prefix(10))"
            processedWindows.append(windowID)
            
            logMessage("  Window \(index): '\(title)' -> ID: \(windowID)")
            
            // Check if we already have this window
            if windows[windowID] == nil {
                let windowInfo = WindowInfo(
                    windowRef: axWindow,
                    pid: pid,
                    appName: appName,
                    title: title,
                    windowID: windowID
                )
                
                DispatchQueue.main.async { [weak self] in
                    self?.windows[windowID] = windowInfo
                    self?.logMessage("  ➕ NEW window added to collection: '\(title)'")
                }
                newWindowsFound += 1
            } else {
                logMessage("  ✓ Already exists in collection")
                // Update the AX reference in case it changed
                DispatchQueue.main.async { [weak self] in
                    self?.windows[windowID]?.windowRef = axWindow
                    self?.windows[windowID]?.title = title
                }
            }
        }
        
        // Clean up any windows for this app that no longer exist
        let windowsToRemove = existingWindowsForApp.filter { existingWindow in
            !processedWindows.contains(existingWindow.windowID)
        }
        
        if !windowsToRemove.isEmpty {
            logMessage("🗑️ Found \(windowsToRemove.count) windows to remove:")
            for windowToRemove in windowsToRemove {
                logMessage("  - Removing: '\(windowToRemove.title)' (ID: \(windowToRemove.windowID))")
            }
            DispatchQueue.main.async { [weak self] in
                for windowToRemove in windowsToRemove {
                    self?.windows.removeValue(forKey: windowToRemove.windowID)
                }
                self?.logMessage("🗑️ Cleanup complete - removed \(windowsToRemove.count) windows from \(appName)")
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            let totalWindows = self?.windows.count ?? 0
            if newWindowsFound > 0 {
                self?.logMessage("✅ \(appName) scan complete: +\(newWindowsFound) new windows (total collection: \(totalWindows))")
            } else {
                self?.logMessage("✅ \(appName) scan complete: no new windows found (total collection: \(totalWindows))")
            }
        }
    }
    
    // MARK: - IPC Server
    private func setupIPCServer() {
        queue.async { [weak self] in
            self?.runIPCServer()
        }
    }
    
    private func runIPCServer() {
        let serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket != -1 else {
            print("Failed to create socket")
            return
        }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            socketPath.withCString { path in
                strncpy(ptr, path, 104)
            }
        }
        
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard bind(serverSocket, withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, addrLen) == 0 else {
            print("Failed to bind socket")
            close(serverSocket)
            return
        }
        
        guard listen(serverSocket, 5) == 0 else {
            print("Failed to listen on socket")
            close(serverSocket)
            return
        }
        
        logMessage("🚀 Window daemon listening on \(socketPath)")
        
        while isRunning {
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket != -1 else { continue }
            
            handleClient(clientSocket)
            close(clientSocket)
        }
        
        close(serverSocket)
        cleanupSocket()
    }
    
    private func handleClient(_ socket: Int32) {
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        let bytesRead = recv(socket, buffer, bufferSize - 1, 0)
        guard bytesRead > 0 else { return }
        
        buffer[bytesRead] = 0
        let request = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = request.components(separatedBy: " ")
        let command = parts[0]
        
        let response: DaemonResponse
        
        switch DaemonCommand(rawValue: command) {
        case .list:
            response = handleListCommand()
        case .listJson:
            response = handleListJsonCommand()
        case .focus:
            let windowID = parts.count > 1 ? parts[1] : ""
            response = handleFocusCommand(windowID: windowID)
        case .refresh:
            logMessage("🔄 Manual refresh requested")
            refreshWindows()
            response = DaemonResponse(success: true, message: "Refreshing windows...", windows: nil)
        case .quit:
            print("Received quit command - shutting down gracefully")
            DispatchQueue.main.async { [weak self] in
                self?.shutdown()
            }
            response = DaemonResponse(success: true, message: "Shutting down daemon", windows: nil)
        case .none:
            response = DaemonResponse(success: false, message: "Unknown command: \(command)", windows: nil)
        }
        
        if let responseData = try? JSONEncoder().encode(response) {
            _ = responseData.withUnsafeBytes { bytes in
                send(socket, bytes.bindMemory(to: CChar.self).baseAddress, bytes.count, 0)
            }
        }
    }
    
    private func handleListCommand() -> DaemonResponse {
        let sortedWindows = Array(windows.values)
            .sorted { $0.lastUsed > $1.lastUsed }
            .map { $0.asWindowData }
        
        return DaemonResponse(success: true, message: nil, windows: sortedWindows)
    }
    
    private func handleListJsonCommand() -> DaemonResponse {
        return handleListCommand()
    }
    
    private func handleFocusCommand(windowID: String) -> DaemonResponse {
        guard let windowInfo = windows[windowID] else {
            return DaemonResponse(success: false, message: "Window not found: \(windowID)", windows: nil)
        }
        
        // First, activate the application
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.processIdentifier == windowInfo.pid }) else {
            return DaemonResponse(success: false, message: "Application not found", windows: nil)
        }
        
        app.activate()
        
        // Give the app a moment to activate
        usleep(100000) // 0.1 seconds
        
        // Try multiple approaches to focus the window
        var success = false
        
        // Method 1: AXRaise (bring window to front)
        let raiseResult = AXUIElementPerformAction(windowInfo.windowRef, kAXRaiseAction as CFString)
        if raiseResult == .success {
            success = true
        }
        
        // Method 2: Check if window is minimized and try to unminimize
        if !success {
            var minimizedValue: AnyObject?
            let minimizedResult = AXUIElementCopyAttributeValue(windowInfo.windowRef, kAXMinimizedAttribute as CFString, &minimizedValue)
            if minimizedResult == .success, let isMinimized = minimizedValue as? Bool, isMinimized {
                let setResult = AXUIElementSetAttributeValue(windowInfo.windowRef, kAXMinimizedAttribute as CFString, false as CFBoolean)
                if setResult == .success {
                    // Try raising again after unminimizing
                    let raiseAfterUnminimize = AXUIElementPerformAction(windowInfo.windowRef, kAXRaiseAction as CFString)
                    success = (raiseAfterUnminimize == .success)
                }
            }
        }
        
        if success {
            windowInfo.lastUsed = Date()
            return DaemonResponse(success: true, message: "Focused window: \(windowInfo.title)", windows: nil)
        } else {
            return DaemonResponse(success: false, message: "Failed to focus window", windows: nil)
        }
    }
    
    private func shutdown() {
        logMessage("🛑 Shutting down daemon...")
        isRunning = false
        
        // Stop the refresh timer
        refreshTimer?.invalidate()
        refreshTimer = nil
        
        // Clean up socket
        cleanupSocket()
        
        // Exit gracefully
        exit(0)
    }
    
    func run() {
        print("🏃 Starting Window Daemon...")
        RunLoop.main.run()
    }
}

// MARK: - Client Functions
func sendDaemonCommand(_ command: String) -> DaemonResponse? {
    let socketPath = "/tmp/windowdaemon.sock"
    let clientSocket = socket(AF_UNIX, SOCK_STREAM, 0)
    guard clientSocket != -1 else { return nil }
    
    defer { close(clientSocket) }
    
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
        socketPath.withCString { path in
            strncpy(ptr, path, 104)
        }
    }
    
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    guard connect(clientSocket, withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, addrLen) == 0 else {
        return nil
    }
    
    _ = command.withCString { cString in
        send(clientSocket, cString, strlen(cString), 0)
    }
    
    let bufferSize = 8192
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    
    let bytesRead = recv(clientSocket, buffer, bufferSize - 1, 0)
    guard bytesRead > 0 else { return nil }
    
    buffer[bytesRead] = 0
    let responseString = String(cString: buffer)
    
    return try? JSONDecoder().decode(DaemonResponse.self, from: responseString.data(using: .utf8)!)
}

// MARK: - Main Entry Point
if CommandLine.argc == 1 {
    // Run as daemon
    let daemon = WindowDaemon()
    
    // Handle shutdown gracefully
    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    
    daemon.run()
} else {
    // Run as client
    let command = CommandLine.arguments.dropFirst().joined(separator: " ")
    
    guard let response = sendDaemonCommand(command) else {
        print("Failed to connect to daemon. Make sure it's running.")
        exit(1)
    }
    
    if let windows = response.windows {
        for window in windows {
            print("\(window.windowID)\t\(window.displayString)")
        }
    } else {
        print(response.message ?? "No response")
    }
    
    exit(response.success ? 0 : 1)
}