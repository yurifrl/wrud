import AppKit
import Foundation
import Carbon

// MARK: - Configuration

struct Config: Decodable {
    var offsetX: CGFloat? = nil
    var offsetY: CGFloat? = nil
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var startSelected: Bool? = nil
    var intervalMinutes: Int? = nil
    var logFile: String? = nil
    var hotKey: String? = nil // e.g. "cmd+shift+1"
    var closeOnBlur: Bool? = nil // if true, window closes when it loses focus
    var showOnStart: Bool? = nil  // open palette immediately on launch
    var showDockIcon: Bool? = nil // show icon in Dock (default false)
    var showMenuBarIcon: Bool? = nil // show an icon in macOS menu bar
    var updateURL: String? = nil // optional URL to releases/latest
    var cron: String? = nil // e.g. "*/30 * * * *" or "0,30 * * * *"
    var showInsideClock: Bool? = nil
    var showOutsideClock: Bool? = nil
}

func loadConfig() -> Config {
    let fm = FileManager.default

    // 1. Path from environment variable CONFIG_PATH
    if let customPath = ProcessInfo.processInfo.environment["CONFIG_PATH"] {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: customPath))
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            logError("Failed to load config from \(customPath): \(error)")
            exit(1)
        }
    }

    // 2. ~/.config/wrud.json
    let homeConfig = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".config")
        .appendingPathComponent("wrud.json")
    if fm.fileExists(atPath: homeConfig.path) {
        do {
            let data = try Data(contentsOf: homeConfig)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            logError("Failed to load ~/.config/wrud.json: \(error)")
            exit(1)
        }
    }

    // 3. "config.json" in current directory (dev convenience)
    let url = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("config.json")
    if fm.fileExists(atPath: url.path) {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            logError("Failed to load config.json: \(error)")
            exit(1)
        }
    }

    // 3. Fallback defaults
    return Config()
}

// MARK: - Globals & Helpers

let config = loadConfig()

var isPaused: Bool = false

func expandPath(_ path: String) -> URL {
    if path.hasPrefix("~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = path.replacingOccurrences(of: "~", with: home)
        return URL(fileURLWithPath: expanded)
    }
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
    }
    return URL(fileURLWithPath: path)
}

let logURL: URL = {
    if let path = config.logFile {
        return expandPath(path)
    }
    let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        .appendingPathComponent("wrud")
    if let dir = appSupport {
        return dir.appendingPathComponent("log.md")
    }
    // Fallback to home directory if App Support resolution fails
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("wrud-log.md")
}()

func logError(_ message: String) {
    print("ERROR: \(message)")
}

// Remove extractTags, tagCache, refreshTags

func formatMMSS(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    let minutes = total / 60
    let seconds = total % 60
    return String(format: "%02d:%02d", minutes, seconds)
}

// MARK: - HotKey Parsing & Registration

func parseHotKey(_ string: String) -> (UInt32, UInt32)? {
    let parts = string.lowercased().split(separator: "+")
    guard !parts.isEmpty else { return nil }

    var modifiers: UInt32 = 0
    var keyCode: UInt32?

    for part in parts {
        switch part {
        case "cmd", "command": modifiers |= UInt32(cmdKey)
        case "shift": modifiers |= UInt32(shiftKey)
        case "option", "alt": modifiers |= UInt32(optionKey)
        case "ctrl", "control": modifiers |= UInt32(controlKey)
        default:
            // Assume this is the key
            switch part {
            case "1": keyCode = 18
            case "2": keyCode = 19
            case "3": keyCode = 20
            case "4": keyCode = 21
            case "5": keyCode = 23
            case "6": keyCode = 22
            case "7": keyCode = 26
            case "8": keyCode = 28
            case "9": keyCode = 25
            case "0": keyCode = 29
            default: break
            }
        }
    }

    guard let kc = keyCode else { return nil }
    return (kc, modifiers)
}

func registerGlobalHotKey() {
    let hotKeyString = config.hotKey ?? "cmd+shift+1"
    guard let (keyCode, modifiers) = parseHotKey(hotKeyString) else {
        logError("Unsupported hotkey string: \(hotKeyString)")
        return
    }

    var hotKeyRef: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x7768646b), id: 1) // 'whdk'

    let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    if status != noErr {
        logError("Failed to register hotkey (status \(status))")
    }

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, evt, _ in
        var hkID = EventHotKeyID()
        GetEventParameter(evt, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout.size(ofValue: hkID), nil, &hkID)
        if hkID.id == 1 {
            showPalette()
            statusBarController.updateMenuUI()
        }
        return noErr
    }, 1, &spec, nil, nil)
}

// MARK: - UI

let app = NSApplication.shared
if config.showDockIcon ?? false {
    app.setActivationPolicy(.regular) // Dock + menu bar
} else {
    app.setActivationPolicy(.accessory) // menu bar only
}

// MARK: - Status Bar Item

final class StatusBarController: NSObject {
    private var item: NSStatusItem?
    private var statusMenu: NSMenu?
    private var statusItem: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var startAtLoginItem: NSMenuItem?
    private var nextItem: NSMenuItem?
    private var countdownTimer: Timer?

    func setup() {
        guard config.showMenuBarIcon ?? true else { return }

        let statusBar = NSStatusBar.system
        item = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item?.button {
            button.title = "🕒"
        }

        buildMenu()
        updateMenuUI()
        startCountdownUpdates()
    }

    private func buildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: "Running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        self.statusItem = status
        menu.addItem(status)

        let next = NSMenuItem(title: "Next: —", action: nil, keyEquivalent: "")
        next.isEnabled = false
        self.nextItem = next
        menu.addItem(next)

        menu.addItem(NSMenuItem.separator())

        let showNow = NSMenuItem(title: "Show Now", action: #selector(showNowAction), keyEquivalent: "s")
        showNow.target = self
        menu.addItem(showNow)

        let toggle = NSMenuItem(title: "Pause", action: #selector(togglePauseAction), keyEquivalent: "p")
        toggle.target = self
        self.toggleItem = toggle
        menu.addItem(toggle)

        let startAtLogin = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLoginAction), keyEquivalent: "l")
        startAtLogin.target = self
        self.startAtLoginItem = startAtLogin
        menu.addItem(startAtLogin)

        if config.updateURL != nil {
            let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "u")
            update.target = self
            menu.addItem(update)
        }

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusMenu = menu
        item?.menu = menu
    }

    func updateMenuUI() {
        statusItem?.title = isPaused ? "Paused" : "Running"
        toggleItem?.title = isPaused ? "Resume" : "Pause"
        let remaining = max(0, schedulerTimer?.fireDate.timeIntervalSinceNow ?? 0)
        let mmss = formatMMSS(remaining)
        if let button = item?.button {
            let showOutside = config.showOutsideClock ?? false
            button.title = isPaused ? "🕒⏸" : (showOutside ? "🕒 \(mmss)" : "🕒")
        }
        if let fireDate = schedulerTimer?.fireDate {
            let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "HH:mm"
            let at = timeFormatter.string(from: fireDate)
            nextItem?.title = isPaused ? "Next: paused" : "Next: \(at) (\(mmss))"
        } else {
            nextItem?.title = isPaused ? "Next: paused" : "Next: —"
        }
        startAtLoginItem?.state = isStartAtLoginEnabled() ? .on : .off
    }

    private func startCountdownUpdates() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(countdownTimer!, forMode: .common)
    }

    @objc private func tick() {
        updateMenuUI()
    }

    @objc private func showNowAction() {
        showPalette()
    }

    @objc private func togglePauseAction() {
        togglePause()
        updateMenuUI()
    }

    @objc private func toggleStartAtLoginAction() {
        let enabled = isStartAtLoginEnabled()
        setStartAtLogin(enabled: !enabled)
        updateMenuUI()
    }

    @objc private func checkForUpdatesAction() {
        guard let urlString = config.updateURL, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}

let statusBarController = StatusBarController()
statusBarController.setup()

final class PaletteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let onSubmit: (String) -> Void
    private let cfg: Config
    private var globalClickMonitor: Any?

    init(cfg: Config, onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        self.cfg = cfg
        let screenFrame: NSRect = (NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]).visibleFrame
        let width = cfg.width ?? 600
        let height = cfg.height ?? 60
        let centerX = screenFrame.midX - (width / 2)
        let centerY = screenFrame.midY - (height / 2)
        let deltaX: CGFloat = cfg.offsetX ?? 0
        let deltaY: CGFloat = cfg.offsetY ?? 0
        let frame = NSRect(x: centerX + deltaX, y: centerY + deltaY, width: width, height: height)

        class PaletteWindow: NSWindow {
            override var canBecomeKey: Bool { true }
            override var canBecomeMain: Bool { true }
        }

        let window = PaletteWindow(contentRect: frame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 0.9)
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10

        super.init(window: window)

        let textField = NSTextField(frame: NSRect(x: 16,
                                                  y: (height - 30) / 2,
                                                  width: width - 32,
                                                  height: 30))
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 20, weight: .medium)
        textField.textColor = .white
        textField.placeholderString = "Search for apps and commands…"
        textField.delegate = self
        window.contentView?.addSubview(textField)

        if cfg.startSelected ?? true {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                window.makeFirstResponder(textField)
                textField.becomeFirstResponder()
            }
        } else {
            window.orderFrontRegardless()
        }

        window.delegate = self

        if cfg.closeOnBlur ?? true {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.window?.close()
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if cfg.closeOnBlur ?? true { // default to close on blur
            self.window?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        activeControllers.removeAll { $0 === self }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            self.window?.close()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let tf = control as? NSTextField {
                onSubmit(tf.stringValue)
            }
            self.window?.close()
            return true
        default:
            return false
        }
    }

    // Removed autocomplete delegate methods
}

// MARK: - Logging

func appendEntry(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    // Ensure log file and its directory exist
    if !FileManager.default.fileExists(atPath: logURL.path) {
        let dir = logURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            } catch { logError("Failed to create directory: \(error)") }
        }
        do {
            try "".write(to: logURL, atomically: true, encoding: .utf8)
        } catch { logError("Failed to create log file: \(error)") }
    }

    var content = ""
    do {
        content = try String(contentsOf: logURL, encoding: .utf8)
    } catch { logError("Failed to read existing log: \(error)") }

    let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "yyyy-MM-dd"
    let dayString = dayFormatter.string(from: Date())

    if !content.contains("# \(dayString)") {
        if !content.hasSuffix("\n") { content += "\n" }
        content += "# \(dayString)\n"
    }

    let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "HH:mm"
    let timeString = timeFormatter.string(from: Date())

    content += "- [ ] \(trimmed) \(timeString)\n"

    do {
        try content.write(to: logURL, atomically: true, encoding: .utf8)
    } catch { logError("Failed to write log: \(error)") }

    // removed refreshTags call
}

// MARK: - Scheduler

var activeControllers: [PaletteWindowController] = []

func showPalette() {
    // If a palette is already open, just focus it and return
    if let existing = activeControllers.last?.window {
        existing.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return
    }

    var ctrl: PaletteWindowController? = nil
    ctrl = PaletteWindowController(cfg: config) { text in
        appendEntry(text)
        if let c = ctrl {
            activeControllers.removeAll { $0 === c }
        }
        ctrl = nil
    }
    if let controller = ctrl {
        activeControllers.append(controller)
        controller.window?.orderFrontRegardless()
    }
}

func nextScheduledDate(from date: Date = Date()) -> Date {
    if let cron = config.cron, isThirtyMinuteCron(cron) {
        return nextThirtyMinuteAligned(from: date)
    }
    let interval = config.intervalMinutes ?? 30
    return nextIntervalAligned(interval: interval, from: date)
}

func isThirtyMinuteCron(_ expr: String) -> Bool {
    let trimmed = expr.trimmingCharacters(in: .whitespaces)
    return trimmed == "*/30 * * * *" || trimmed == "0,30 * * * *" || trimmed == "0 */1 * * *" // treat hourly as 0 past hour
}

func nextThirtyMinuteAligned(from date: Date) -> Date {
    let calendar = Calendar.current
    var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let minute = comps.minute ?? 0
    let add = (minute < 30) ? (30 - minute) : (60 - minute)
    return calendar.date(byAdding: .minute, value: add, to: date)!.withZeroSeconds()
}

func nextIntervalAligned(interval: Int, from date: Date) -> Date {
    let calendar = Calendar.current
    var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let minute = comps.minute ?? 0
    let remainder = minute % interval
    comps.minute! += remainder == 0 ? interval : (interval - remainder)
    comps.second = 0
    return calendar.date(from: comps)!
}

extension Date {
    func withZeroSeconds() -> Date {
        let calendar = Calendar.current
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        comps.second = 0
        return calendar.date(from: comps)!
    }
}

var schedulerTimer: Timer?
var lastFireDate: Date?

func startScheduler() {
    guard schedulerTimer == nil else { return }
    let firstFire = nextScheduledDate()
    let t = Timer(fireAt: firstFire,
                  interval: TimeInterval((config.intervalMinutes ?? 30) * 60),
                  target: BlockOperation { showPalette() },
                  selector: #selector(Operation.main),
                  userInfo: nil,
                  repeats: true)
    lastFireDate = firstFire
    schedulerTimer = t
    RunLoop.main.add(t, forMode: .common)
}

func stopScheduler() {
    schedulerTimer?.invalidate()
    schedulerTimer = nil
}

func togglePause() {
    isPaused.toggle()
    if isPaused {
        stopScheduler()
    } else {
        startScheduler()
    }
}

startScheduler()

// MARK: - Start at Login (LaunchAgent)

func agentPlistURL() -> URL {
    let bundleId = "dev.local.wrud"
    let launchAgents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    return launchAgents.appendingPathComponent("\(bundleId).plist")
}

func isStartAtLoginEnabled() -> Bool {
    FileManager.default.fileExists(atPath: agentPlistURL().path)
}

func setStartAtLogin(enabled: Bool) {
    let fm = FileManager.default
    let plistURL = agentPlistURL()
    let launchAgentsDir = plistURL.deletingLastPathComponent()
    do { try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true) } catch {}

    if enabled {
        let exePath = Bundle.main.bundlePath
        let dict: [String: Any] = [
            "Label": "dev.local.wrud",
            "ProgramArguments": [exePath + "/Contents/MacOS/wrud"],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? data.write(to: plistURL)
            _ = runLaunchCtl(["load", plistURL.path])
        }
    } else {
        _ = runLaunchCtl(["unload", plistURL.path])
        try? fm.removeItem(at: plistURL)
    }
}

@discardableResult
func runLaunchCtl(_ args: [String]) -> Int32 {
    let task = Process()
    task.launchPath = "/bin/launchctl"
    task.arguments = args
    do { try task.run(); task.waitUntilExit(); return task.terminationStatus } catch { return -1 }
}

// Register global hot key
registerGlobalHotKey()
// Show prompt on start if enabled (default true)
if config.showOnStart ?? true {
    showPalette()
}
// Start app event loop
app.run() 