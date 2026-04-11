import AppKit
import SwiftUI

enum ClipboardContent {
    case text(String)
    case image(NSImage)
    case fileURL(URL)
    case unknown
}

/// Detected sub-category for text items.
/// All share the blue color; only the icon and label differ.
enum TextSubtype {
    case email
    case phone
    case date
    case code
    case url
    case text   // generic fallback
}

extension TextSubtype {
    var icon: String {
        switch self {
        case .email:  return "envelope"
        case .phone:  return "phone"
        case .date:   return "calendar"
        case .code:   return "chevron.left.forwardslash.chevron.right"
        case .url:    return "globe.americas.fill"
        case .text:   return "doc.plaintext"
        }
    }

    var label: String {
        switch self {
        case .email:  return "Email"
        case .phone:  return "Phone"
        case .date:   return "Date"
        case .code:   return "Code"
        case .url:    return "Link"
        case .text:   return "Text"
        }
    }
}

struct ClipboardItem: Identifiable {
    let id = UUID()
    let content: ClipboardContent
    let source: String
    let date: Date
    var isPinned: Bool = false

    // OPTIMISATION 9: detection results cached at creation time
    // avoids re-running regex on every view re-render
    let cachedColor: Color?
    /// Detected subtype for text items (email, phone, date, code, url, text)
    let cachedSubtype: TextSubtype?

    init(content: ClipboardContent, source: String, date: Date, isPinned: Bool = false) {
        self.content  = content
        self.source   = source
        self.date     = date
        self.isPinned = isPinned
        // Computed once at item creation
        if case .text(let t) = content {
            self.cachedColor   = ClipboardItem.detectColorStatic(in: t)
            self.cachedSubtype = ClipboardItem.detectSubtype(in: t)
        } else {
            self.cachedColor   = nil
            self.cachedSubtype = nil
        }
    }

    // Regex compiled once (shared with ClipboardPanel via static access)
    private static let regexHex = try! NSRegularExpression(pattern: "^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$")
    private static let regexRGB = try! NSRegularExpression(pattern: "^rgb\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})\\s*\\)$", options: .caseInsensitive)
    private static let regexHSL = try! NSRegularExpression(pattern: "^hsl\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})%\\s*,\\s*(\\d{1,3})%\\s*\\)$", options: .caseInsensitive)

    static func detectColorStatic(in text: String) -> Color? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)

        if regexHex.firstMatch(in: trimmed, range: range) != nil {
            var hex = trimmed.dropFirst()
            if hex.count == 3 { hex = Substring(hex.map { "\($0)\($0)" }.joined()) }
            let scanner = Scanner(string: String(hex))
            var rgb: UInt64 = 0
            scanner.scanHexInt64(&rgb)
            return Color(
                red:   Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8)  & 0xFF) / 255,
                blue:  Double( rgb        & 0xFF) / 255
            )
        }

        if regexRGB.firstMatch(in: trimmed, range: range) != nil {
            let nums = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            if nums.count >= 3 {
                return Color(red: Double(nums[0])/255, green: Double(nums[1])/255, blue: Double(nums[2])/255)
            }
        }

        if regexHSL.firstMatch(in: trimmed, range: range) != nil {
            let nums = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            if nums.count >= 3 {
                return Color(hue: Double(nums[0])/360, saturation: Double(nums[1])/100, brightness: Double(nums[2])/100)
            }
        }

        return nil
    }

    // MARK: - Text subtype detection (email, phone, date, code, url)

    // Regex compiled once for subtype detection
    private static let regexEmail = try! NSRegularExpression(pattern: "^[A-Z0-9a-z._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$")
    private static let regexURL   = try! NSRegularExpression(pattern: "^https?://\\S+|^www\\.\\S+", options: .caseInsensitive)
    // Phone: international (+33, +1, +44…) and common formats
    private static let regexPhone = try! NSRegularExpression(
        pattern: #"^\+?(?:(?:\d[\s.\-]?){6,14}\d)$|^(?:0[1-9])(?:[\s.\-]?\d{2}){4}$|^0[1-9]\d{8}$"#
    )
    // Date: common formats dd/mm/yyyy, yyyy-mm-dd, "March 12 2025", etc.
    private static let regexDate  = try! NSRegularExpression(
        pattern: #"^\d{1,2}[\/\-\.]\d{1,2}[\/\-\.]\d{2,4}$|^\d{4}[\/\-\.]\d{1,2}[\/\-\.]\d{1,2}$|^(?:\d{1,2}\s)?(?:jan(?:uary|vier)?|feb(?:ruary|rier)?|mar(?:ch|s)?|apr(?:il|il)?|may|mai|jun(?:e|)?|jul(?:y|let)?|aug(?:ust|)?|ao[uû]t|sep(?:tember|tembre)?|oct(?:ober|obre)?|nov(?:ember|embre)?|dec(?:ember|embre)?)\s*\d{1,2}?,?\s*\d{2,4}$"#,
        options: .caseInsensitive
    )
    // Code: presence of keywords or typical code structures
    private static let regexCode  = try! NSRegularExpression(
        pattern: #"(?:func |let |var |const |class |struct |enum |import |return |if |else|switch |case |for |while |def |async |await|\{|\}|=>|->|\(\)|<\/?\w+>|;\s*$)"#,
        options: .caseInsensitive
    )

    static func detectSubtype(in text: String) -> TextSubtype {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range   = NSRange(trimmed.startIndex..., in: trimmed)

        // URL first (before email to avoid false positives)
        if regexURL.firstMatch(in: trimmed, range: range)   != nil { return .url }
        // Email
        if regexEmail.firstMatch(in: trimmed, range: range) != nil { return .email }
        // Phone
        if regexPhone.firstMatch(in: trimmed, range: range) != nil { return .phone }
        // Date
        if regexDate.firstMatch(in: trimmed, range: range)  != nil { return .date }
        // Code (only if text contains multiple words or lines)
        if trimmed.count > 3 && regexCode.firstMatch(in: trimmed, range: range) != nil { return .code }

        return .text
    }

    var displayTitle: String {
        switch content {
        case .text(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(60))
        case .image:            return "Image"
        case .fileURL(let url): return url.deletingPathExtension().lastPathComponent
        case .unknown:          return "Unknown"
        }
    }

    var typeIcon: String {
        switch content {
        case .text:             return cachedSubtype?.icon ?? "doc.plaintext"
        case .image:            return "photo"
        case .fileURL:          return "doc"
        case .unknown:          return "questionmark"
        }
    }

    var typeLabel: String {
        switch content {
        case .text:             return cachedSubtype?.label ?? "Text"
        case .image:            return "Image"
        case .fileURL(let url): return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
        case .unknown:          return "Unknown"
        }
    }

    var typeColor: Color {
        switch content {
        case .text:    return Color.blue
        case .image:   return Color.purple
        case .fileURL: return Color.orange
        case .unknown: return Color.gray
        }
    }
}

final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()

    @Published var items: [ClipboardItem] = [] { didSet { scheduleSave() } }

    // OPTIMISATION 2: cancellable DispatchWorkItem — lighter than recreating a Timer on every change
    private var saveWorkItem: DispatchWorkItem?

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.saveHistory() }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - Sequence state (published so the UI can observe it)
    @Published private(set) var sequenceQueue: [ClipboardItem] = []
    @Published private(set) var sequenceIndex: Int = 0

    var isSequenceActive: Bool { !sequenceQueue.isEmpty }
    var sequenceProgress: (current: Int, total: Int) { (sequenceIndex, sequenceQueue.count) }

    private var pollingTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private let storageKey = "clipboard.history.v2"

    // MARK: - CGEventTap
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Protection against concurrent calls to advanceSequence() triggered by fast ⌘V
    private var isAdvancing: Bool = false

    private init() {
        loadHistory()
        startPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        // Do not record changes we triggered ourselves (sequence writing)
        guard !isSequenceActive else { return }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"

        // 1. File URLs — must precede image check
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let first = urls.first, first.isFileURL {
            addItem(ClipboardItem(content: .fileURL(first), source: appName, date: Date()))
            return
        }

        // 2. True bitmap images
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png,
            NSPasteboard.PasteboardType("com.adobe.pdf"),
            NSPasteboard.PasteboardType("public.jpeg")]
        let hasImageData = imageTypes.contains { pb.data(forType: $0) != nil }
        if hasImageData,
           let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let first = imgs.first {
            addItem(ClipboardItem(content: .image(first), source: appName, date: Date()))
            return
        }

        // 3. Plain text
        if let text = pb.string(forType: .string), !text.isEmpty {
            if let last = items.first(where: { !$0.isPinned }), case .text(let t) = last.content, t == text { return }
            addItem(ClipboardItem(content: .text(text), source: appName, date: Date()))
        }
    }

    private func addItem(_ item: ClipboardItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // OPTIMISATION 3: single pass over the list instead of two successive .filter() calls
            var pinned   = [ClipboardItem]()
            var unpinned = [ClipboardItem]()
            for entry in self.items {
                if entry.isPinned { pinned.append(entry) } else { unpinned.append(entry) }
            }
            unpinned.insert(item, at: 0)
            if unpinned.count > 150 { unpinned = Array(unpinned.prefix(150)) }
            self.items = pinned + unpinned
        }
    }

    // MARK: - Basic clipboard actions

    func paste(item: ClipboardItem) {
        copyToClipboard(item: item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            keyDown?.flags = .maskCommand; keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cgSessionEventTap); keyUp?.post(tap: .cgSessionEventTap)
        }
    }

    func copyToClipboard(item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.content {
        case .text(let t):      pb.setString(t, forType: .string)
        case .image(let img):   pb.writeObjects([img])
        case .fileURL(let url): pb.writeObjects([url as NSURL])
        case .unknown: break
        }
        // Sync lastChangeCount so polling ignores this write
        lastChangeCount = pb.changeCount
    }

    func togglePin(item: ClipboardItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isPinned.toggle()
            items = items.filter { $0.isPinned } + items.filter { !$0.isPinned }
        }
    }

    func delete(item: ClipboardItem) { items.removeAll { $0.id == item.id } }
    func clearAll() { items.removeAll { !$0.isPinned } }

    // MARK: - Panel open request

    static let panelOpenNotification = Notification.Name("ClipboardMonitor.openPanel")

    func requestPanelOpen() {
        NotificationCenter.default.post(name: Self.panelOpenNotification, object: self)
    }

    // MARK: - Multi-paste sequence

    func startSequence(items: [ClipboardItem]) {
        guard !items.isEmpty else { return }
        sequenceQueue = items
        sequenceIndex = 0
        isAdvancing   = false
        copyToClipboard(item: items[0])
        installEventTap()
    }

    func cancelSequence() {
        sequenceQueue = []
        sequenceIndex = 0
        isAdvancing   = false
        removeEventTap()
    }

    fileprivate func advanceSequence() {
        guard isSequenceActive, !isAdvancing else { return }
        isAdvancing = true

        sequenceIndex += 1
        if sequenceIndex < sequenceQueue.count {
            copyToClipboard(item: sequenceQueue[sequenceIndex])
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.cancelSequence()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.isAdvancing = false
        }
    }

    // MARK: - CGEventTap installation

    private func installEventTap() {
        removeEventTap()

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let monitor = Unmanaged<ClipboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                if keyCode == 9, event.flags.contains(.maskCommand) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        monitor.advanceSequence()
                    }
                }
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            let alert = NSAlert()
            alert.messageText     = L.accessibilityTitle
            alert.informativeText = L.accessibilityText
            alert.alertStyle      = .warning
            alert.addButton(withTitle: L.openSettings)
            alert.addButton(withTitle: L.cancel)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            cancelSequence()
            return
        }

        eventTap      = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            eventTap      = nil
            runLoopSource = nil
        }
    }

    // MARK: - Persistence

    private func saveHistory() {
        let dicts = items.compactMap { item -> [String: Any]? in
            var dict: [String: Any] = ["source": item.source, "date": item.date.timeIntervalSince1970, "pinned": item.isPinned]
            switch item.content {
            case .text(let t):      dict["type"] = "text"; dict["value"] = t
            case .fileURL(let url): dict["type"] = "file"; dict["value"] = url.absoluteString
            default: return nil  // images intentionally not persisted
            }
            return dict
        }
        UserDefaults.standard.set(dicts, forKey: storageKey)
    }

    private func loadHistory() {
        guard let dicts = UserDefaults.standard.object(forKey: storageKey) as? [[String: Any]] else { return }
        items = dicts.compactMap { dict in
            guard let type   = dict["type"] as? String,
                  let value  = dict["value"] as? String,
                  let source = dict["source"] as? String,
                  let ts     = dict["date"] as? TimeInterval else { return nil }
            let content: ClipboardContent
            if type == "file", let url = URL(string: value) {
                content = .fileURL(url)
            } else {
                content = .text(value)
            }
            var item = ClipboardItem(content: content, source: source, date: Date(timeIntervalSince1970: ts))
            item.isPinned = dict["pinned"] as? Bool ?? false
            return item
        }
    }
}
