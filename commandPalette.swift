import AppKit
import Foundation

struct Config: Decodable {
    var offsetX: CGFloat? = nil
    var offsetY: CGFloat? = nil
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var startSelected: Bool? = nil
    var intervalMinutes: Int? = nil
    var logFile: String? = nil
}

func loadConfig() -> Config {
    let fm = FileManager.default

    // 1. Path from environment variable CONFIG_PATH
    if let customPath = ProcessInfo.processInfo.environment["CONFIG_PATH"],
       let data = try? Data(contentsOf: URL(fileURLWithPath: customPath)),
       let cfg = try? JSONDecoder().decode(Config.self, from: data) {
        return cfg
    }

    // 2. "config.json" in current directory
    let url = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("config.json")
    if let data = try? Data(contentsOf: url),
       let cfg = try? JSONDecoder().decode(Config.self, from: data) {
        return cfg
    }

    // 3. Fallback defaults
    return Config()
}

let config = loadConfig()

let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class PaletteWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let onSubmit: (String) -> Void
    private let cfg: Config

    init(cfg: Config, onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        self.cfg = cfg
        let screenFrame = NSScreen.main!.frame
        let width: CGFloat = cfg.width ?? 600
        let height: CGFloat = cfg.height ?? 60
        let xPos: CGFloat = cfg.offsetX ?? 40
        let yPos: CGFloat = cfg.offsetY ?? (screenFrame.height - height) / 2
        let frame = NSRect(x: xPos,
                           y: yPos,
                           width: width,
                           height: height)

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
}

// MARK: - Logging

func appendEntry(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let fm = FileManager.default
    let logURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(config.logFile ?? "log.md")

    var content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""

    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "yyyy-MM-dd"
    let dayString = dayFormatter.string(from: Date())

    if !content.contains("# \(dayString)") {
        if !content.hasSuffix("\n") { content += "\n" }
        content += "# \(dayString)\n"
    }

    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm"
    let timeString = timeFormatter.string(from: Date())

    content += "- [ ] \(trimmed) \(timeString)\n"

    try? content.write(to: logURL, atomically: true, encoding: .utf8)
}

// MARK: - Scheduler

var activeControllers: [PaletteWindowController] = []

func showPalette() {
    // Use temporary optional for capture
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

func nextHalfHourDate(_ interval: Int, from date: Date = Date()) -> Date {
    let calendar = Calendar.current
    var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let minute = comps.minute ?? 0
    let remainder = minute % interval
    if remainder == 0 {
        comps.minute! += interval
    } else {
        comps.minute! += (interval - remainder)
    }
    comps.second = 0
    return calendar.date(from: comps)!
}

let intervalMinutes = config.intervalMinutes ?? 30
let firstFire = nextHalfHourDate(intervalMinutes)
let timer = Timer(fireAt: firstFire, interval: TimeInterval(intervalMinutes * 60), target: BlockOperation { showPalette() }, selector: #selector(Operation.main), userInfo: nil, repeats: true)
RunLoop.main.add(timer, forMode: .common)

// Show prompt immediately on first run
showPalette()

// Start app event loop
app.run() 