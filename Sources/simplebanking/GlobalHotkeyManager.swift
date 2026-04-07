import AppKit
import Carbon

// MARK: - GlobalHotkeyManager

final class GlobalHotkeyManager {
    nonisolated(unsafe) static let shared = GlobalHotkeyManager()

    var onTriggered: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let signature: FourCharCode = 0x73626B79 // 'sbky'

    private init() {}

    func register(keyCode: Int, carbonModifiers: Int) {
        unregister()

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
                let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
                if let cb = mgr.onTriggered { DispatchQueue.main.async(execute: cb) }
                return noErr
            },
            1, &spec, selfPtr, &eventHandlerRef
        )
        guard status == noErr else { return }

        var hkID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(keyCode), UInt32(carbonModifiers),
            hkID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let ref = eventHandlerRef { RemoveEventHandler(ref); eventHandlerRef = nil }
    }

    // MARK: Carbon modifier helpers

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var c = 0
        if flags.contains(.command) { c |= cmdKey }
        if flags.contains(.shift)   { c |= shiftKey }
        if flags.contains(.option)  { c |= optionKey }
        if flags.contains(.control) { c |= controlKey }
        return c
    }

    static func nsFlags(from carbonMods: Int) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbonMods & cmdKey     != 0 { f.insert(.command) }
        if carbonMods & shiftKey   != 0 { f.insert(.shift) }
        if carbonMods & optionKey  != 0 { f.insert(.option) }
        if carbonMods & controlKey != 0 { f.insert(.control) }
        return f
    }

    static func displayString(keyCode: Int, carbonModifiers: Int) -> String {
        let flags = nsFlags(from: carbonModifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += keyName(for: UInt32(keyCode))
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        let table: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
            51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
            100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
            117: "⌦", 118: "F4", 120: "F2", 122: "F1"
        ]
        return table[keyCode] ?? "?"
    }
}

// MARK: - HotkeyButton (NSButton subclass for recording)

final class HotkeyButton: NSButton {
    var keyCode: Int = 1
    var modifiers: Int = 4352
    var onHotkeyRecorded: ((Int, Int) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        bezelStyle = .rounded
        font = NSFont.systemFont(ofSize: 12)
        wantsLayer = true
        target = self
        action = #selector(buttonClicked)
        updateTitle()
    }

    @objc private func buttonClicked() {
        if isRecording { stopRecording(discard: true) } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        title = "Drücke eine Taste…"
        updateColors()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.capture(event: event)
            return nil
        }
    }

    private func capture(event: NSEvent) {
        let kc = Int(event.keyCode)
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let carbonMods = GlobalHotkeyManager.carbonModifiers(from: flags)
        // Require at least one modifier to avoid swallowing normal keypresses
        guard carbonMods != 0 else { return }
        keyCode = kc
        modifiers = carbonMods
        onHotkeyRecorded?(kc, carbonMods)
        stopRecording(discard: false)
    }

    func stopRecording(discard: Bool) {
        isRecording = false
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        updateTitle()
        updateColors()
    }

    func updateTitle() {
        guard !isRecording else { return }
        title = GlobalHotkeyManager.displayString(keyCode: keyCode, carbonModifiers: modifiers)
    }

    private func updateColors() {
        if isRecording {
            contentTintColor = NSColor.controlAccentColor
        } else {
            contentTintColor = nil
        }
    }
}

// MARK: - HotkeyRecorderView (SwiftUI wrapper)

import SwiftUI

struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    func makeNSView(context: Context) -> HotkeyButton {
        let btn = HotkeyButton()
        btn.keyCode = keyCode
        btn.modifiers = modifiers
        btn.updateTitle()
        btn.onHotkeyRecorded = { kc, mods in
            keyCode = kc
            modifiers = mods
        }
        return btn
    }

    func updateNSView(_ btn: HotkeyButton, context: Context) {
        btn.keyCode = keyCode
        btn.modifiers = modifiers
        btn.updateTitle()
    }
}
