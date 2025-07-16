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

    // 2. "config.json" in current directory
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

let logURL: URL = {
    if let path = config.logFile {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        } else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path)
        }
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("log.md")
}()

func logError(_ message: String) {
    print("ERROR: \(message)")
}

// Remove extractTags, tagCache, refreshTags

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
    var hotKeyID = EventHotKeyID(signature: OSType(0x7768646b), id: 1) // 'whdk'

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

final class PaletteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let onSubmit: (String) -> Void
    private let cfg: Config

    init(cfg: Config, onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        self.cfg = cfg
        let screen = NSScreen.main!.frame
        let width = cfg.width ?? 600
        let height = cfg.height ?? 60
        let xPos = cfg.offsetX ?? 40
        let yPos = cfg.offsetY ?? 40  // bottom-left alignment by default
        let frame = NSRect(x: xPos, y: yPos, width: width, height: height)

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

        if cfg.startSelected ?? false {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textField)
        } else {
            window.orderFrontRegardless()
        }

        window.delegate = self
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
            } catch {
                logError("Failed to create directory: \(error)")
                exit(1)
            }
        }
        do {
            try "".write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            logError("Failed to create log file: \(error)")
            exit(1)
        }
    }

    var content = ""
    do {
        content = try String(contentsOf: logURL, encoding: .utf8)
    } catch {
        logError("Failed to read existing log: \(error)")
    }

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
    } catch {
        logError("Failed to write log: \(error)")
        exit(1)
    }

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

func nextScheduledDate(interval: Int, from date: Date = Date()) -> Date {
    let calendar = Calendar.current
    var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let minute = comps.minute ?? 0
    let remainder = minute % interval
    comps.minute! += remainder == 0 ? interval : (interval - remainder)
    comps.second = 0
    return calendar.date(from: comps)!
}

let intervalMinutes = config.intervalMinutes ?? 30
let firstFire = nextScheduledDate(interval: intervalMinutes)
let timer = Timer(fireAt: firstFire,
                  interval: TimeInterval(intervalMinutes * 60),
                  target: BlockOperation { showPalette() },
                  selector: #selector(Operation.main),
                  userInfo: nil,
                  repeats: true)
RunLoop.main.add(timer, forMode: .common)

// Register global hot key
registerGlobalHotKey()
// Show prompt on start if enabled (default true)
if config.showOnStart ?? true {
    showPalette()
}
// Start app event loop
app.run() 