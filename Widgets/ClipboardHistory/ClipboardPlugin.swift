import DockDoorWidgetSDK
import SwiftUI
import AppKit

// MARK: - Unified keyboard table (OPTIMISATION 5: single source instead of two duplicated tables)

/// (name, virtual key code) pairs shared by parsing and display.
private let keyboardTable: [(String, UInt16)] = [
    ("a",0x00),("b",0x0B),("c",0x08),("d",0x02),("e",0x0E),("f",0x03),
    ("g",0x05),("h",0x04),("i",0x22),("j",0x26),("k",0x28),("l",0x25),
    ("m",0x2E),("n",0x2D),("o",0x1F),("p",0x23),("q",0x0C),("r",0x0F),
    ("s",0x01),("t",0x11),("u",0x20),("v",0x09),("w",0x0D),("x",0x07),
    ("y",0x10),("z",0x06),
    ("1",0x12),("2",0x13),("3",0x14),("4",0x15),("5",0x17),
    ("6",0x16),("7",0x1A),("8",0x1C),("9",0x19),("0",0x1D),
    ("return",0x24),("enter",0x24),("tab",0x30),("space",0x31),
    ("delete",0x33),("backspace",0x33),("escape",0x35),("esc",0x35),
    ("left",0x7B),("right",0x7C),("down",0x7D),("up",0x7E),
    ("f1",0x7A),("f2",0x78),("f3",0x63),("f4",0x76),("f5",0x60),
    ("f6",0x61),("f7",0x62),("f8",0x64),("f9",0x65),("f10",0x6D),
    ("f11",0x67),("f12",0x6F)
]

/// Display symbols for virtual key codes (derived from keyboardTable + specials)
private let displayTable: [UInt16: String] = {
    var table = [UInt16: String]()
    // Letters and digits: uppercase for display
    for (name, code) in keyboardTable where name.count == 1 { table[code] = name.uppercased() }
    // Special keys
    table[0x24] = "↩"; table[0x30] = "⇥"; table[0x31] = "Space"; table[0x33] = "⌫"; table[0x35] = "⎋"
    table[0x7B] = "←"; table[0x7C] = "→"; table[0x7D] = "↓"; table[0x7E] = "↑"
    table[0x7A] = "F1"; table[0x78] = "F2"; table[0x63] = "F3"; table[0x76] = "F4"
    table[0x60] = "F5"; table[0x61] = "F6"; table[0x62] = "F7"; table[0x64] = "F8"
    table[0x65] = "F9"; table[0x6D] = "F10"; table[0x67] = "F11"; table[0x6F] = "F12"
    return table
}()

private func keyCodeForString(_ s: String) -> UInt16? {
    keyboardTable.first(where: { $0.0 == s })?.1
}

// MARK: - Shortcut parsing helpers

struct ShortcutDescriptor {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: UInt16

    static let defaultRaw = "option+v"

    static func parse(_ raw: String) -> ShortcutDescriptor? {
        let parts = raw.lowercased().components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }

        var flags: NSEvent.ModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command":       flags.insert(.command)
            case "option", "opt", "alt": flags.insert(.option)
            case "shift":                flags.insert(.shift)
            case "ctrl", "control":      flags.insert(.control)
            default: return nil
            }
        }

        guard let keyCode = keyCodeForString(parts.last!) else { return nil }
        return ShortcutDescriptor(modifiers: flags, keyCode: keyCode)
    }

    /// Converts NSEvent modifier flags to CGEventFlags for comparison in the tap
    func toCGEventFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option)  { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift)   { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option)  { result += "⌥" }
        if modifiers.contains(.shift)   { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + (displayTable[keyCode] ?? "?")
    }
}

// MARK: - Plugin

final class ClipboardPlugin: WidgetPlugin, DockDoorWidgetProvider {
    // Static references accessible from the CGEvent callback (C context, no Swift capture)
    static weak var shared: ClipboardPlugin?
    static var activeShortcut: ShortcutDescriptor?

    var id: String { "clipboard-history" }
    var name: String { "Clipboard" }
    var iconSymbol: String { WidgetDefaults.string(key: "iconSymbol", widgetId: "clipboard-history", default: "clipboard.fill") }
    var widgetDescription: String { S("Accès rapide à l'historique du presse-papiers avec aperçu.", "Quick access to clipboard history with live preview.") }
    var supportedOrientations: [WidgetOrientation] { [.horizontal, .vertical] }

    private let monitor = ClipboardMonitor.shared
    // CGEvent tap (intercepts AND blocks the shortcut to avoid inserting a stray character)
    private var shortcutEventTap: CFMachPort?
    private var shortcutRunLoopSource: CFRunLoopSource?
    private var floatingPanel: EditablePanel?
    private var resignObserver: Any?
    /// When true the panel ignores focus loss and does not auto-close.
    private var isPinned: Bool = false

    // MARK: - Init / Deinit

    required init() {
        super.init()
        ClipboardPlugin.shared = self
        // OPTIMISATION 6: shortcut registered once at startup.
        // A settings change requires a restart — avoids reinstalling
        // a CGEventTap (heavy system operation) every 0.5 s during
        // history saves that triggered UserDefaults.didChangeNotification.
        registerShortcut()
    }

    deinit {
        removeShortcutTap()
        if let observer = resignObserver { NSEvent.removeMonitor(observer) }
    }

    // MARK: - Keyboard shortcut

    private func registerShortcut() {
        removeShortcutTap()

        let raw = UserDefaults.standard.string(forKey: "widget.clipboard-history.hotkey") ?? ShortcutDescriptor.defaultRaw
        guard let shortcut = ShortcutDescriptor.parse(raw) else { return }

        ClipboardPlugin.activeShortcut = shortcut

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, _ -> Unmanaged<CGEvent>? in
                guard let shortcut = ClipboardPlugin.activeShortcut else {
                    return Unmanaged.passRetained(event)
                }
                let pressed     = event.flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
                let wantedFlags: CGEventFlags = shortcut.toCGEventFlags()
                let keyCode     = event.getIntegerValueField(.keyboardEventKeycode)
                guard pressed == wantedFlags, keyCode == Int64(shortcut.keyCode) else {
                    return Unmanaged.passRetained(event)
                }
                DispatchQueue.main.async {
                    ClipboardPlugin.shared?.toggleFloatingPanel()
                }
                return nil // ← blocks the event, the ◊ character is not inserted
            },
            userInfo: nil
        )

        guard let tap else { return }
        shortcutEventTap      = tap
        shortcutRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), shortcutRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeShortcutTap() {
        if let tap = shortcutEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = shortcutRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
            shortcutEventTap      = nil
            shortcutRunLoopSource = nil
        }
    }

    // MARK: - Floating panel

    func toggleFloatingPanel() {
        if let existing = floatingPanel, existing.isVisible {
            closeFloatingPanel(force: true)
            return
        }
        openFloatingPanel()
    }

    // OPTIMISATION 7: hide/reopen animations were duplicated for picker and sequence.
    // Two shared private functions avoid repetition and centralise animation durations.

    private func animateHidePanel(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    private func animateReopenPanel(_ panel: NSPanel) {
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func openFloatingPanel() {
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
        if let observer = resignObserver { NSEvent.removeMonitor(observer); resignObserver = nil }

        let panel = EditablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 765, height: 500),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level           = .floating
        panel.backgroundColor = .clear
        panel.hasShadow       = true
        panel.isReleasedWhenClosed = false

        // Centre on the screen containing the mouse, or restore last position
        if let savedX = UserDefaults.standard.object(forKey: "clipboard.panel.x") as? Double,
           let savedY = UserDefaults.standard.object(forKey: "clipboard.panel.y") as? Double {
            panel.setFrameOrigin(NSPoint(x: savedX, y: savedY))
        } else {
            let screen = NSScreen.screens.first(where: {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            }) ?? NSScreen.main
            if let screen = screen {
                let x = screen.visibleFrame.midX - 765 / 2
                let y = screen.visibleFrame.midY - 500 / 2
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        panel.contentView = NSHostingView(rootView:
            ClipboardPanel(monitor: monitor, close: { [weak self] in
                self?.closeFloatingPanel(force: true)
            }, pinBinding: Binding(
                get: { [weak self] in self?.isPinned ?? false },
                set: { [weak self] val in self?.isPinned = val }
            ), hideForPicker: { [weak self] in
                guard let panel = self?.floatingPanel else { return }
                self?.animateHidePanel(panel)
            }, reopenAfterPicker: { [weak self] in
                guard let self, self.isPinned, let panel = self.floatingPanel else { return }
                self.animateReopenPanel(panel)
            }, hideForSequence: { [weak self] in
                guard let panel = self?.floatingPanel else { return }
                self?.animateHidePanel(panel)
            }, reopenAfterSequence: { [weak self] in
                guard let self, self.isPinned, let panel = self.floatingPanel else { return }
                self.animateReopenPanel(panel)
            })
        )

        floatingPanel = panel
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        // Close on click outside the panel — ignored when pinned
        resignObserver = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] _ in
            guard let self, !self.isPinned else { return }
            guard let panel, panel.isVisible else { return }
            self.closeFloatingPanel(force: false)
        }
    }

    /// - `force: true`  → explicit close (shortcut, ✕ button): resets isPinned and always closes.
    /// - `force: false` → automatic close (outside click): blocked when isPinned is true.
    private func closeFloatingPanel(force: Bool = false) {
        guard force || !isPinned else { return }
        if let panel = floatingPanel {
            UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: "clipboard.panel.x")
            UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: "clipboard.panel.y")
        }
        isPinned = false
        if let panel = floatingPanel {
            let capturedPanel = panel
            floatingPanel = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                capturedPanel.animator().alphaValue = 0
            }, completionHandler: {
                capturedPanel.orderOut(nil)
            })
        }
        if let observer = resignObserver { NSEvent.removeMonitor(observer); resignObserver = nil }
    }

    // MARK: - Settings

    func settingsSchema() -> [WidgetSetting] {
        let raw     = WidgetDefaults.string(key: "hotkey", widgetId: id, default: ShortcutDescriptor.defaultRaw)
        let display = ShortcutDescriptor.parse(raw)?.displayString ?? raw

        return [
            .picker(
                key: "langue",
                label: L.languageLabel,
                options: ["en", "fr"],
                defaultValue: "en"
            ),
            .picker(
                key: "iconSymbol",
                label: L.iconLabel,
                options: [
                    "clipboard.fill", "clipboard",
                    "doc.on.clipboard.fill", "doc.on.clipboard",
                    "list.clipboard.fill", "list.clipboard",
                    "tray.full.fill", "tray.full",
                    "doc.plaintext.fill", "doc.plaintext",
                    "doc.fill", "note.text", "scissors",
                    "bookmark.fill", "tag.fill", "pin.fill",
                    "paperclip", "archivebox.fill",
                    "clock.fill", "clock.arrow.circlepath",
                    "bolt.fill", "star.fill",
                ],
                defaultValue: "clipboard.fill"
            ),
            .toggle(
                key: "afficherIcone",
                label: S("Afficher l'icône dans la vue double", "Show icon in extended view"),
                defaultValue: false
            ),
            .textField(
                key: "hotkey",
                label: "\(L.shortcutLabel) (\(display))",
                placeholder: L.shortcutPlaceholder,
                defaultValue: ShortcutDescriptor.defaultRaw
            ),
        ]
    }

    // MARK: - Views

    @MainActor
    func makeBody(size: CGSize, isVertical: Bool) -> AnyView {
        let symbol   = WidgetDefaults.string(key: "iconSymbol", widgetId: id, default: "clipboard.fill")
        let showIcon = WidgetDefaults.bool(key: "afficherIcone", widgetId: id, default: false)
        return AnyView(ClipboardWidgetView(size: size, isVertical: isVertical, monitor: monitor, iconSymbol: symbol, showIcon: showIcon))
    }

    @MainActor
    func makePanelBody(dismiss: @escaping () -> Void) -> AnyView? {
        let ctx = PanelWindowContext()
        let guardedDismiss: () -> Void = {
            ctx.cancelScheduledClose()
            let workItem = DispatchWorkItem {
                let mouse = NSEvent.mouseLocation
                if let frame = ctx.window?.frame, frame.contains(mouse) { return }
                dismiss()
            }
            ctx.pendingWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: workItem)
        }
        return AnyView(ClipboardPanelSDK(monitor: monitor,
                                         dismiss: dismiss,
                                         guardedDismiss: guardedDismiss,
                                         context: ctx))
    }
}
