import AppKit
import Foundation
import Carbon

// MARK: - Configuration

struct FileConfig: Decodable {
    var promptMatch: String? = nil // regex to match prompt
    var filePositionMatch: String? = nil // regex to find position in file
    var insertBehavior: String? = nil // "append" or "prepend"
    var exitBehaviour: String? = nil // "finish" or "continue"
    var file: String? = nil // path to file
    var format: String? = nil // format string with $prompt placeholder
}

struct FilesDefault: Decodable {
    var insertBehaviour: String? = nil // "date", "prepend", or "append"
    var file: String? = nil // default file path
}

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
    var showInsideClock: Bool? = nil
    var showOutsideClock: Bool? = nil
    var filesDefault: FilesDefault? = nil
    var files: [String: FileConfig]? = nil
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
    // Check if filesDefault is configured
    if let filesDefault = config.filesDefault, let path = filesDefault.file {
        return expandPath(path)
    }
    // Fallback to logFile config for backward compatibility
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

// Custom text field to handle control key shortcuts locally
final class CommandTextField: NSTextField {
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "a":
                NSApp.sendAction(#selector(NSTextView.moveToBeginningOfLine(_:)), to: nil, from: self)
                return
            case "e", "r":
                // Support both Ctrl+E and requested Ctrl+R for end-of-line
                NSApp.sendAction(#selector(NSTextView.moveToEndOfLine(_:)), to: nil, from: self)
                return
            case "w":
                NSApp.sendAction(#selector(NSTextView.deleteWordBackward(_:)), to: nil, from: self)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

final class PaletteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let onSubmit: (String) -> Void
    private let cfg: Config
    private var globalClickMonitor: Any?
    private weak var inputField: NSTextField?

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
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.titleVisibility = .hidden
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.cornerRadius = 10

        super.init(window: window)

        let textField = CommandTextField(frame: NSRect(x: 16,
                                                  y: (height - 30) / 2,
                                                  width: width - 32,
                                                  height: 30))
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 20, weight: .medium)
        textField.textColor = .white
        textField.placeholderString = "Add item"
        textField.delegate = self
        if let cell = textField.cell as? NSTextFieldCell {
            cell.wraps = false
            cell.isScrollable = true
            cell.usesSingleLineMode = true
            cell.lineBreakMode = .byClipping
        }
        window.contentView?.addSubview(textField)
        self.inputField = textField

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
        case #selector(NSTextView.insertLineBreak(_:)):
            // Treat Shift+Enter as submit-and-continue
            if let tf = control as? NSTextField {
                onSubmit(tf.stringValue)
                tf.stringValue = ""
                DispatchQueue.main.async { tf.becomeFirstResponder() }
                return true
            }
            return false
        case #selector(NSResponder.insertNewline(_:)):
            if let tf = control as? NSTextField {
                onSubmit(tf.stringValue)
                let isShiftReturn = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                if isShiftReturn {
                    tf.stringValue = ""
                    DispatchQueue.main.async {
                        tf.becomeFirstResponder()
                    }
                    return true
                }
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

    // Process files in order
    if let files = config.files {
        let sortedFiles = files.sorted { (first, second) in
            let firstOrder = Int(first.key) ?? 999
            let secondOrder = Int(second.key) ?? 999
            return firstOrder < secondOrder
        }

        for (_, fileConfig) in sortedFiles {
            if let promptRegex = fileConfig.promptMatch {
                do {
                    let regex = try NSRegularExpression(pattern: promptRegex)
                    let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                    if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                        // Found a match, write to this file
                        if let filePath = fileConfig.file {
                            writeToFile(text: trimmed, config: fileConfig, filePath: filePath)
                            print("✓ Added to \(URL(fileURLWithPath: filePath).lastPathComponent)")
                            // Check exit behavior
                            if fileConfig.exitBehaviour != "continue" {
                                return // Default is "finish"
                            }
                        }
                    }
                } catch {
                    logError("Invalid regex pattern: \(promptRegex)")
                }
            }
        }
    }

    // Fall back to filesDefault if no matches
    if let filesDefault = config.filesDefault {
        let defaultConfig = FileConfig()
        writeToFile(text: trimmed, config: defaultConfig, filePath: filesDefault.file ?? logURL.path, insertBehaviour: filesDefault.insertBehaviour)
    } else {
        // Legacy behavior - write to logURL
        writeToFile(text: trimmed, config: FileConfig(), filePath: logURL.path, insertBehaviour: "date")
    }
}

func writeToFile(text: String, config: FileConfig, filePath: String, insertBehaviour: String? = nil) {
    let fileURL = expandPath(filePath)
    let behavior = insertBehaviour ?? config.insertBehavior ?? "date"

    // Ensure file and its directory exist
    if !FileManager.default.fileExists(atPath: fileURL.path) {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            } catch { logError("Failed to create directory: \(error)") }
        }
        do {
            try "".write(to: fileURL, atomically: true, encoding: .utf8)
        } catch { logError("Failed to create file: \(error)") }
    }

    var content = ""
    do {
        content = try String(contentsOf: fileURL, encoding: .utf8)
    } catch { logError("Failed to read existing file: \(error)") }

    let timeFormatter = DateFormatter(); timeFormatter.dateFormat = "HH:mm"
    let timeString = timeFormatter.string(from: Date())

    var newEntry = ""
    var insertionPoint = content.count

    // Handle behavior and format
    switch behavior {
    case "date":
        let dayFormatter = DateFormatter(); dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayString = dayFormatter.string(from: Date())

        if !content.contains("# \(dayString)") {
            if !content.hasSuffix("\n") { content += "\n" }
            content += "# \(dayString)\n"
        }
        if let format = config.format {
            newEntry = format.replacingOccurrences(of: "$prompt", with: text) + "\n"
        } else {
            newEntry = "- [ ] \(text) \(timeString)\n"
        }
        insertionPoint = content.count
    case "prepend":
        if let format = config.format {
            newEntry = format.replacingOccurrences(of: "$prompt", with: text) + "\n"
        } else {
            newEntry = "\(text)\n"
        }
        insertionPoint = 0
    case "append":
        if let format = config.format {
            newEntry = format.replacingOccurrences(of: "$prompt", with: text) + "\n"
        } else {
            newEntry = "\(text)\n"
        }
        insertionPoint = content.count
    case "endoflist":
        if let format = config.format {
            newEntry = format.replacingOccurrences(of: "$prompt", with: text) + "\n"
        } else {
            newEntry = "\(text)\n"
        }
        // Handle file position matching for endoflist
        if let positionRegex = config.filePositionMatch {
            do {
                let regex = try NSRegularExpression(pattern: positionRegex)
                let range = NSRange(content.startIndex..<content.endIndex, in: content)
                if let match = regex.firstMatch(in: content, options: [], range: range) {
                    // Find end of the matched line and move to next line
                    let matchEnd = match.range.location + match.range.length
                    if let stringRange = Range(NSRange(location: matchEnd, length: 0), in: content) {
                        let searchRange = stringRange.lowerBound..<content.endIndex
                        if let newlineRange = content.range(of: "\n", range: searchRange) {
                            var currentPos = newlineRange.upperBound
                            var lastDashLineEnd: String.Index? = nil

                            // Find consecutive lines starting with "-"
                            while currentPos < content.endIndex {
                                let remainingRange = currentPos..<content.endIndex
                                if let nextNewline = content.range(of: "\n", range: remainingRange) {
                                    let lineRange = currentPos..<nextNewline.lowerBound
                                    let line = String(content[lineRange]).trimmingCharacters(in: .whitespaces)

                                    if line.hasPrefix("- ") || line.hasPrefix("-\t") {
                                        lastDashLineEnd = nextNewline.upperBound
                                    } else if !line.isEmpty {
                                        // Hit a non-empty, non-dash line, stop here
                                        break
                                    }
                                    currentPos = nextNewline.upperBound
                                } else {
                                    // No more newlines, check the last line
                                    let lineRange = currentPos..<content.endIndex
                                    let line = String(content[lineRange]).trimmingCharacters(in: .whitespaces)
                                    if line.hasPrefix("- ") || line.hasPrefix("-\t") {
                                        lastDashLineEnd = content.endIndex
                                    }
                                    break
                                }
                            }

                            if let dashEnd = lastDashLineEnd {
                                insertionPoint = content.distance(from: content.startIndex, to: dashEnd)
                            } else {
                                // No dash lines found after the match, insert right after the match
                                insertionPoint = content.distance(from: content.startIndex, to: newlineRange.upperBound)
                            }
                        } else {
                            insertionPoint = content.count
                        }
                    }
                } else {
                    insertionPoint = content.count
                }
            } catch {
                logError("Invalid file position regex: \(positionRegex)")
                insertionPoint = content.count
            }
        } else {
            insertionPoint = content.count
        }
    default:
        if let format = config.format {
            newEntry = format.replacingOccurrences(of: "$prompt", with: text) + "\n"
        } else {
            newEntry = "- [ ] \(text) \(timeString)\n"
        }
        insertionPoint = content.count
    }

    // Insert the new entry
    if insertionPoint >= content.count {
        content += newEntry
    } else if insertionPoint <= 0 {
        content = newEntry + content
    } else {
        let index = content.index(content.startIndex, offsetBy: insertionPoint)
        content.insert(contentsOf: newEntry, at: index)
    }

    do {
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    } catch { logError("Failed to write to file: \(error)") }
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
    let interval = config.intervalMinutes ?? 30
    return nextIntervalAligned(interval: interval, from: date)
}

func nextIntervalAligned(interval: Int, from date: Date) -> Date {
    let calendar = Calendar.current
    let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let currentMinute = comps.minute ?? 0

    // Calculate next interval aligned with top of hour (0 minutes)
    let nextMinute = ((currentMinute / interval) + 1) * interval

    if nextMinute < 60 {
        // Same hour
        var newComps = comps
        newComps.minute = nextMinute
        newComps.second = 0
        return calendar.date(from: newComps)!
    } else {
        // Next hour
        let nextHour = calendar.date(byAdding: .hour, value: 1, to: date)!
        var newComps = calendar.dateComponents([.year, .month, .day, .hour], from: nextHour)
        newComps.minute = nextMinute - 60
        newComps.second = 0
        return calendar.date(from: newComps)!
    }
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
    let interval = config.intervalMinutes ?? 30
    let t = Timer(fireAt: firstFire,
                  interval: TimeInterval(interval * 60),
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