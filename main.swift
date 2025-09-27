import AppKit
import Foundation
import Carbon

// MARK: - Configuration Models

enum InsertBehavior: String, CaseIterable {
    case prepend = "prepend"
    case append = "append"
    case endoflist = "endoflist"
    case date = "date"
}

enum ExitBehavior: String, CaseIterable {
    case finish = "finish"
    case `continue` = "continue"
}

struct FileDestination {
    enum Mode {
        case file(URL)
        case directory(URL, NSRegularExpression?)
    }

    enum Resolution {
        case success(URL)
        case failure(String)
    }

    let mode: Mode

    func resolve(using fileManager: FileManager = .default) -> Resolution {
        switch mode {
        case .file(let url):
            return .success(url)
        case .directory(let directoryURL, let pattern):
            return resolveLatestFile(in: directoryURL, matching: pattern, fileManager: fileManager)
        }
    }

    var allowsCreationIfMissing: Bool {
        switch mode {
        case .file:
            return true
        case .directory:
            return false
        }
    }

    private func resolveLatestFile(in directoryURL: URL,
                                   matching pattern: NSRegularExpression?,
                                   fileManager: FileManager) -> Resolution {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                return .failure("Directory not found at \(directoryURL.path)")
            }
            return .failure("Unable to read directory \(directoryURL.lastPathComponent): \(error.localizedDescription)")
        }

        let files = contents.filter { url in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return false
            }

            guard let pattern = pattern else { return true }
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            return pattern.firstMatch(in: name, options: [], range: range) != nil
        }

        guard !files.isEmpty else {
            if let pattern = pattern {
                return .failure("No files in \(directoryURL.lastPathComponent) matched pattern \(pattern.pattern)")
            }
            return .failure("No files found in directory \(directoryURL.lastPathComponent)")
        }

        func modificationDate(for url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate ?? .distantPast
        }

        let selected = files.sorted { lhs, rhs in
            let lhsDate = modificationDate(for: lhs)
            let rhsDate = modificationDate(for: rhs)
            if lhsDate == rhsDate {
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            return lhsDate > rhsDate
        }.first

        guard let resolved = selected else {
            return .failure("No selectable files found in \(directoryURL.lastPathComponent)")
        }

        return .success(resolved)
    }
}

struct FileRule {
    let promptPattern: String
    let promptMatch: NSRegularExpression
    let filePositionMatch: NSRegularExpression?
    let insertBehavior: InsertBehavior
    let exitBehavior: ExitBehavior
    let destination: FileDestination
    let format: String?
}

struct FilesDefault {
    let insertBehavior: InsertBehavior
    let filePath: URL
}

struct UITheme {
    let backgroundColor: NSColor
    let borderColor: NSColor
    let borderWidth: CGFloat
    let cornerRadius: CGFloat
    let textColor: NSColor
    let placeholderColor: NSColor
    let fontSize: CGFloat
}

struct AppConfig {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let width: CGFloat
    let height: CGFloat
    let startSelected: Bool
    let intervalMinutes: Int
    let hotKey: String
    let closeOnBlur: Bool
    let showOnStart: Bool
    let showDockIcon: Bool
    let showMenuBarIcon: Bool
    let showInsideClock: Bool
    let showOutsideClock: Bool
    let updateURL: String?
    let theme: UITheme

    let filesDefault: FilesDefault
    let fileRules: [FileRule]
}

// MARK: - Configuration Loading & Validation

private struct RawUITheme: Decodable {
    var backgroundColor: String?
    var borderColor: String?
    var borderWidth: Double?
    var cornerRadius: Double?
    var textColor: String?
    var placeholderColor: String?
    var fontSize: Double?
}

private struct RawConfig: Decodable {
    var offsetX: CGFloat?
    var offsetY: CGFloat?
    var width: CGFloat?
    var height: CGFloat?
    var startSelected: Bool?
    var intervalMinutes: Int?
    var logFile: String?
    var hotKey: String?
    var closeOnBlur: Bool?
    var showOnStart: Bool?
    var showDockIcon: Bool?
    var showMenuBarIcon: Bool?
    var updateURL: String?
    var showInsideClock: Bool?
    var showOutsideClock: Bool?
    var theme: RawUITheme?
    var filesDefault: RawFilesDefault?
    var files: [String: RawFileConfig]?
}

private struct RawFilesDefault: Decodable {
    var insertBehaviour: String?
    var file: String?
}

private struct RawFileConfig: Decodable {
    var promptMatch: String?
    var filePositionMatch: String?
    var insertBehavior: String?
    var exitBehaviour: String?
    var file: String?
    var directory: String?
    var fileMatch: String?
    var format: String?
}

func loadAndValidateConfig() -> AppConfig {
    let rawConfig = loadRawConfig()
    return validateConfig(rawConfig)
}

private func loadRawConfig() -> RawConfig {
    let cwdConfig = FileManager.default.currentDirectoryPath + "/config.json"
    let homeConfig = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/wrud.json").path

    let envConfig = ProcessInfo.processInfo.environment["CONFIG_PATH"].flatMap { $0.isEmpty ? nil : $0 }

    let configPaths: [String] = [
        envConfig,
        cwdConfig,
        homeConfig
    ].compactMap { $0 }

    for path in configPaths {
        guard FileManager.default.fileExists(atPath: path) else { continue }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(RawConfig.self, from: data)
        } catch {
            print("⚠️  Skipping config at \(path): \(error.localizedDescription)")
            continue
        }
    }

    return RawConfig() // Use defaults
}

private func validateConfig(_ raw: RawConfig) -> AppConfig {
    let filesDefault = validateFilesDefault(raw.filesDefault)
    let fileRules = validateFileRules(raw.files)
    let theme = validateTheme(raw.theme)

    return AppConfig(
        offsetX: raw.offsetX ?? 40,
        offsetY: raw.offsetY ?? 40,
        width: raw.width ?? 800,
        height: raw.height ?? 64,
        startSelected: raw.startSelected ?? true,
        intervalMinutes: max(1, raw.intervalMinutes ?? 30),
        hotKey: raw.hotKey ?? "cmd+shift+=",
        closeOnBlur: raw.closeOnBlur ?? true,
        showOnStart: raw.showOnStart ?? true,
        showDockIcon: raw.showDockIcon ?? false,
        showMenuBarIcon: raw.showMenuBarIcon ?? true,
        showInsideClock: raw.showInsideClock ?? false,
        showOutsideClock: raw.showOutsideClock ?? false,
        updateURL: raw.updateURL,
        theme: theme,
        filesDefault: filesDefault,
        fileRules: fileRules
    )
}

private func validateFilesDefault(_ raw: RawFilesDefault?) -> FilesDefault {
    let defaultFile = raw?.file ?? {
        let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: true)
            .appendingPathComponent("wrud")
        return appSupport?.appendingPathComponent("log.md").path
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("wrud-log.md").path
    }()

    let behavior = InsertBehavior(rawValue: raw?.insertBehaviour ?? "date") ?? .date

    return FilesDefault(
        insertBehavior: behavior,
        filePath: expandPath(defaultFile)
    )
}

private func validateFileRules(_ rawFiles: [String: RawFileConfig]?) -> [FileRule] {
    guard let rawFiles = rawFiles else { return [] }

    return rawFiles
        .sorted { Int($0.key) ?? 999 < Int($1.key) ?? 999 }
        .compactMap { validateFileRule($1) }
}

private func validateFileRule(_ raw: RawFileConfig) -> FileRule? {
    guard let promptPattern = raw.promptMatch else {
        print("⚠️  Invalid file rule: missing promptMatch")
        return nil
    }

    guard let promptRegex = try? NSRegularExpression(pattern: promptPattern) else {
        print("⚠️  Invalid regex pattern: \(promptPattern)")
        return nil
    }

    let positionRegex = raw.filePositionMatch.flatMap {
        try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines])
    }

    let insertBehavior = InsertBehavior(rawValue: raw.insertBehavior ?? "append") ?? .append
    let exitBehavior = ExitBehavior(rawValue: raw.exitBehaviour ?? "finish") ?? .finish

    let destination: FileDestination
    if let file = raw.file {
        destination = FileDestination(mode: .file(expandPath(file)))
    } else if let directory = raw.directory {
        let directoryURL = expandPath(directory)
        var matchRegex: NSRegularExpression?

        if let pattern = raw.fileMatch {
            matchRegex = try? NSRegularExpression(pattern: pattern)
            if matchRegex == nil {
                print("⚠️  Invalid fileMatch regex: \(pattern)")
                return nil
            }
        }

        destination = FileDestination(mode: .directory(directoryURL, matchRegex))
    } else {
        print("⚠️  Invalid file rule: missing file or directory for pattern \(promptPattern)")
        return nil
    }

    return FileRule(
        promptPattern: promptPattern,
        promptMatch: promptRegex,
        filePositionMatch: positionRegex,
        insertBehavior: insertBehavior,
        exitBehavior: exitBehavior,
        destination: destination,
        format: raw.format
    )
}

private func validateTheme(_ raw: RawUITheme?) -> UITheme {
    return UITheme(
        backgroundColor: parseColor(raw?.backgroundColor) ?? NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 0.95),
        borderColor: parseColor(raw?.borderColor) ?? NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 0.6),
        borderWidth: CGFloat(raw?.borderWidth ?? 1.0),
        cornerRadius: CGFloat(raw?.cornerRadius ?? 12.0),
        textColor: parseColor(raw?.textColor) ?? NSColor.white,
        placeholderColor: parseColor(raw?.placeholderColor) ?? NSColor(calibratedRed: 0.7, green: 0.7, blue: 0.7, alpha: 0.6),
        fontSize: CGFloat(raw?.fontSize ?? 18.0)
    )
}

private func parseColor(_ hexString: String?) -> NSColor? {
    guard let hex = hexString?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return nil
    }

    let cleanHex = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard cleanHex.count == 6 || cleanHex.count == 8 else { return nil }

    var rgbValue: UInt64 = 0
    Scanner(string: cleanHex).scanHexInt64(&rgbValue)

    if cleanHex.count == 6 {
        return NSColor(
            calibratedRed: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    } else {
        return NSColor(
            calibratedRed: CGFloat((rgbValue & 0xFF000000) >> 24) / 255.0,
            green: CGFloat((rgbValue & 0x00FF0000) >> 16) / 255.0,
            blue: CGFloat((rgbValue & 0x0000FF00) >> 8) / 255.0,
            alpha: CGFloat(rgbValue & 0x000000FF) / 255.0
        )
    }
}

private func expandPath(_ path: String) -> URL {
    if path.hasPrefix("~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = path.replacingOccurrences(of: "~", with: home)
        return URL(fileURLWithPath: expanded)
    }
    return URL(fileURLWithPath: path)
}

// MARK: - File Writing System

struct EntryWriter {
    private let fileManager = FileManager.default

    @discardableResult
    func writeEntry(_ text: String, using rule: FileRule) -> Bool {
        switch rule.destination.resolve(using: fileManager) {
        case .success(let targetURL):
            if rule.destination.allowsCreationIfMissing {
                ensureFileExists(targetURL)
            } else if !fileManager.fileExists(atPath: targetURL.path) {
                print("⚠️  Rule \(rule.promptPattern) skipped '\(text)': target file does not exist at \(targetURL.path)")
                return false
            }

            let content = readFileContent(targetURL)
            let formattedEntry = formatEntry(text, using: rule)
            let insertionPoint = findInsertionPoint(in: content, for: rule)
            let newContent = insertEntry(formattedEntry, at: insertionPoint, in: content)
            writeFileContent(newContent, to: targetURL)
            print("✓ Rule \(rule.promptPattern) appended to \(targetURL.lastPathComponent): \(text)")
            return true
        case .failure(let message):
            print("⚠️  Rule \(rule.promptPattern) skipped '\(text)': \(message)")
            return false
        }
    }

    func writeToDefault(_ text: String, using defaultConfig: FilesDefault) {
        ensureFileExists(defaultConfig.filePath)
        let content = readFileContent(defaultConfig.filePath)
        let formattedEntry = formatDefaultEntry(text, behavior: defaultConfig.insertBehavior)
        let insertionPoint = findDefaultInsertionPoint(in: content, behavior: defaultConfig.insertBehavior)
        let newContent = insertEntry(formattedEntry, at: insertionPoint, in: content)
        writeFileContent(newContent, to: defaultConfig.filePath)
        print("✓ Default log appended to \(defaultConfig.filePath.lastPathComponent): \(text)")
    }

    private func ensureFileExists(_ fileURL: URL) {
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }

        let dir = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func readFileContent(_ fileURL: URL) -> String {
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    private func writeFileContent(_ content: String, to fileURL: URL) {
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Entry Formatting

extension EntryWriter {
    private func formatEntry(_ text: String, using rule: FileRule) -> String {
        if let format = rule.format {
            return format.replacingOccurrences(of: "$prompt", with: text) + "\n"
        }
        return text + "\n"
    }

    private func formatDefaultEntry(_ text: String, behavior: InsertBehavior) -> String {
        guard behavior == .date else {
            return text + "\n"
        }

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeString = timeFormatter.string(from: Date())
        return "- [ ] \(text) \(timeString)\n"
    }
}

// MARK: - Insertion Point Logic

extension EntryWriter {
    private func findInsertionPoint(in content: String, for rule: FileRule) -> Int {
        switch rule.insertBehavior {
        case .prepend:
            return 0
        case .append:
            return content.count
        case .endoflist:
            return findEndOfListPosition(in: content, after: rule.filePositionMatch)
        case .date:
            return findDateInsertionPoint(in: content)
        }
    }

    private func findDefaultInsertionPoint(in content: String, behavior: InsertBehavior) -> Int {
        switch behavior {
        case .prepend: return 0
        case .append, .endoflist: return content.count
        case .date: return findDateInsertionPoint(in: content)
        }
    }

    private func findEndOfListPosition(in content: String, after positionRegex: NSRegularExpression?) -> Int {
        guard let regex = positionRegex else { return content.count }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range) else {
            return content.count
        }

        let matchEnd = match.range.location + match.range.length
        guard let stringRange = Range(NSRange(location: matchEnd, length: 0), in: content) else {
            return content.count
        }

        let searchRange = stringRange.lowerBound..<content.endIndex
        guard let newlineRange = content.range(of: "\n", range: searchRange) else {
            return content.count
        }

        return scanForLastListItem(in: content, startingFrom: newlineRange.upperBound)
    }

    private func scanForLastListItem(in content: String, startingFrom startIndex: String.Index) -> Int {
        var currentPos = startIndex
        var lastListItemEnd: String.Index?

        while currentPos < content.endIndex {
            let remainingRange = currentPos..<content.endIndex
            guard let nextNewline = content.range(of: "\n", range: remainingRange) else {
                let finalLine = String(content[currentPos...]).trimmingCharacters(in: .whitespaces)
                if finalLine.hasPrefix("- ") || finalLine.hasPrefix("-\t") {
                    lastListItemEnd = content.endIndex
                }
                break
            }

            let lineRange = currentPos..<nextNewline.lowerBound
            let line = String(content[lineRange]).trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("- ") || line.hasPrefix("-\t") {
                lastListItemEnd = nextNewline.upperBound
            } else if !line.isEmpty {
                break
            }

            currentPos = nextNewline.upperBound
        }

        return lastListItemEnd.map { content.distance(from: content.startIndex, to: $0) }
            ?? content.distance(from: content.startIndex, to: startIndex)
    }

    private func findDateInsertionPoint(in content: String) -> Int {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayString = dayFormatter.string(from: Date())

        if content.contains("# \(dayString)") {
            return content.count
        }

        var updatedContent = content
        if !content.hasSuffix("\n") { updatedContent += "\n" }
        updatedContent += "# \(dayString)\n"

        // This is a bit hacky - we need to update the content for date behavior
        // In a real refactor, we'd handle this differently
        return updatedContent.count
    }

    private func insertEntry(_ entry: String, at insertionPoint: Int, in content: String) -> String {
        var mutableContent = content

        // Handle date insertion specially
        if insertionPoint > content.count {
            return content + entry
        }

        if insertionPoint >= content.count {
            return content + entry
        }

        if insertionPoint <= 0 {
            return entry + content
        }

        let index = content.index(content.startIndex, offsetBy: insertionPoint)
        mutableContent.insert(contentsOf: entry, at: index)
        return mutableContent
    }
}

// MARK: - Entry Processing

func processEntry(_ text: String, config: AppConfig) {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }

    let writer = EntryWriter()
    var matchedRule = false
    var handledByRule = false

    // Process file rules in order
    for rule in config.fileRules {
        let range = NSRange(trimmedText.startIndex..<trimmedText.endIndex, in: trimmedText)
        if rule.promptMatch.firstMatch(in: trimmedText, options: [], range: range) != nil {
            matchedRule = true
            print("→ Rule \(rule.promptPattern) matched '\(trimmedText)', attempting write")
            let didWrite = writer.writeEntry(trimmedText, using: rule)
            handledByRule = handledByRule || didWrite

            if rule.exitBehavior == .finish {
                if didWrite {
                    return
                }
                break
            }
        }
    }

    // Fallback to default
    if !handledByRule {
        if matchedRule {
            print("ℹ️ Matched rule(s) but no file was updated; falling back to default log")
        } else {
            print("ℹ️ No file rules matched '\(trimmedText)', using default log")
        }
        writer.writeToDefault(trimmedText, using: config.filesDefault)
    }
}

// MARK: - Utility Functions

func logError(_ message: String) {
    print("ERROR: \(message)")
}

func formatMMSS(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    let minutes = total / 60
    let seconds = total % 60
    return String(format: "%02d:%02d", minutes, seconds)
}

func getVersionString() -> String {
    let now = Date()
    let calendar = Calendar.current
    let dayOfYear = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
    let hour = calendar.component(.hour, from: now)
    return String(format: "%03d%02d", dayOfYear, hour)
}

func formatHotKeyForDisplay(_ hotKey: String) -> String {
    return hotKey
        .replacingOccurrences(of: "cmd", with: "⌘")
        .replacingOccurrences(of: "shift", with: "⇧")
        .replacingOccurrences(of: "option", with: "⌥")
        .replacingOccurrences(of: "alt", with: "⌥")
        .replacingOccurrences(of: "ctrl", with: "⌃")
        .replacingOccurrences(of: "control", with: "⌃")
        .replacingOccurrences(of: "+", with: "")
        .uppercased()
}

// MARK: - Global Configuration

let config = loadAndValidateConfig()
var isPaused: Bool = false

// MARK: - HotKey System

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
            case "=": keyCode = 24
            default: break
            }
        }
    }

    guard let kc = keyCode else { return nil }
    return (kc, modifiers)
}

func registerGlobalHotKey() {
    guard let (keyCode, modifiers) = parseHotKey(config.hotKey) else {
        logError("Unsupported hotkey string: \(config.hotKey)")
        return
    }

    var hotKeyRef: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x7768646b), id: 1)

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

// MARK: - Application Setup

let app = NSApplication.shared
if config.showDockIcon {
    app.setActivationPolicy(.regular)
} else {
    app.setActivationPolicy(.accessory)
}

// MARK: - Status Bar Controller

final class StatusBarController: NSObject {
    private var item: NSStatusItem?
    private var statusMenu: NSMenu?
    private var statusItem: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var startAtLoginItem: NSMenuItem?
    private var nextItem: NSMenuItem?
    private var countdownTimer: Timer?

    func setup() {
        guard config.showMenuBarIcon else { return }

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

        // Add version display
        let version = NSMenuItem(title: "v\(getVersionString())", action: nil, keyEquivalent: "")
        version.isEnabled = false
        // Make version text muted by setting it as attributed string
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        version.attributedTitle = NSAttributedString(string: "v\(getVersionString())", attributes: attributes)
        menu.addItem(version)

        menu.addItem(NSMenuItem.separator())

        let showNow = NSMenuItem(title: "Show Now", action: #selector(showNowAction), keyEquivalent: "")
        showNow.keyEquivalentModifierMask = []
        // Set the correct hotkey display from config
        let hotkeyDisplay = formatHotKeyForDisplay(config.hotKey)
        showNow.title = "Show Now \t\(hotkeyDisplay)"
        showNow.target = self
        menu.addItem(showNow)

        let toggle = NSMenuItem(title: "Pause", action: #selector(togglePauseAction), keyEquivalent: "")
        toggle.target = self
        self.toggleItem = toggle
        menu.addItem(toggle)

        let startAtLogin = NSMenuItem(title: "Start at Login", action: #selector(toggleStartAtLoginAction), keyEquivalent: "")
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
            button.title = isPaused ? "🕒⏸" : (config.showOutsideClock ? "🕒 \(mmss)" : "🕒")
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

// MARK: - Text Input UI

final class CommandTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        let action: Selector?
        switch chars {
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: action = nil
        }

        if let action = action, NSApp.sendAction(action, to: nil, from: self) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let chars = event.charactersIgnoringModifiers {
            switch chars.lowercased() {
            case "a":
                NSApp.sendAction(#selector(NSTextView.moveToBeginningOfLine(_:)), to: nil, from: self)
                return
            case "e", "r":
                NSApp.sendAction(#selector(NSTextView.moveToEndOfLine(_:)), to: nil, from: self)
                return
            case "w":
                NSApp.sendAction(#selector(NSTextView.deleteWordBackward(_:)), to: nil, from: self)
                return
            case "d":
                NSApp.sendAction(#selector(NSTextView.deleteForward(_:)), to: nil, from: self)
                return
            case "h":
                NSApp.sendAction(#selector(NSText.deleteBackward(_:)), to: nil, from: self)
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
    private let appConfig: AppConfig
    private var globalClickMonitor: Any?
    private weak var inputField: NSTextField?
    private let previousApp: NSRunningApplication?
    private var hasRestoredFocus = false

    init(appConfig: AppConfig, onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
        self.appConfig = appConfig
        let screenFrame: NSRect = (NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]).visibleFrame
        let width = appConfig.width
        let height = appConfig.height
        let centerX = screenFrame.midX - (width / 2)
        let centerY = screenFrame.midY - (height / 2)
        let deltaX: CGFloat = appConfig.offsetX
        let deltaY: CGFloat = appConfig.offsetY
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
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.titleVisibility = .hidden

        // Create a background view with proper styling
        let backgroundView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = appConfig.theme.backgroundColor.cgColor
        backgroundView.layer?.cornerRadius = appConfig.theme.cornerRadius
        backgroundView.layer?.borderWidth = appConfig.theme.borderWidth
        backgroundView.layer?.borderColor = appConfig.theme.borderColor.cgColor
        window.contentView?.addSubview(backgroundView)

        self.previousApp = NSWorkspace.shared.frontmostApplication

        super.init(window: window)

        // Calculate text field dimensions proportionally
        let textFieldHeight = height * 0.5  // 50% of window height
        let textFieldY = (height - textFieldHeight) / 2
        let padding: CGFloat = 20

        let textField = CommandTextField(frame: NSRect(x: padding,
                                                  y: textFieldY,
                                                  width: width - (padding * 2),
                                                  height: textFieldHeight))
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: appConfig.theme.fontSize, weight: .medium)
        textField.textColor = appConfig.theme.textColor
        textField.alignment = .left

        // Configure cell for proper text centering and placeholder
        if let cell = textField.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
            cell.lineBreakMode = .byClipping

            // Set placeholder with same font size as input text
            let placeholderAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: appConfig.theme.placeholderColor,
                .font: NSFont.systemFont(ofSize: appConfig.theme.fontSize, weight: .medium)
            ]
            cell.placeholderAttributedString = NSAttributedString(
                string: "Add item",
                attributes: placeholderAttributes
            )
        }

        // Simple vertical centering using transform
        let verticalCenter = (textFieldHeight - appConfig.theme.fontSize) / 2
        if verticalCenter > 0 {
            textField.frame = NSRect(
                x: padding,
                y: textFieldY + verticalCenter / 2,
                width: width - (padding * 2),
                height: textFieldHeight - verticalCenter
            )
        }

        textField.delegate = self
        window.contentView?.addSubview(textField)
        self.inputField = textField

        if appConfig.startSelected {
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

        if appConfig.closeOnBlur {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                self?.window?.close()
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func restorePreviousFocusIfNeeded() {
        guard !hasRestoredFocus,
              let previousApp,
              previousApp != NSRunningApplication.current else { return }

        hasRestoredFocus = true
        DispatchQueue.main.async {
            previousApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if appConfig.closeOnBlur {
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
            restorePreviousFocusIfNeeded()
            return true
        default:
            return false
        }
    }
}

// MARK: - Scheduling System

var activeControllers: [PaletteWindowController] = []

func showPalette() {
    if let existing = activeControllers.last?.window {
        existing.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return
    }

    var ctrl: PaletteWindowController? = nil
    ctrl = PaletteWindowController(appConfig: config) { text in
        processEntry(text, config: config)
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
    let interval = config.intervalMinutes
    let calendar = Calendar.current
    let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let currentMinute = comps.minute ?? 0

    let nextMinute = ((currentMinute / interval) + 1) * interval

    if nextMinute < 60 {
        var newComps = comps
        newComps.minute = nextMinute
        newComps.second = 0
        return calendar.date(from: newComps)!
    } else {
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
    let interval = config.intervalMinutes
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

// MARK: - Launch Agent Management

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

// MARK: - Application Startup

registerGlobalHotKey()
if config.showOnStart {
    showPalette()
}
app.run()
