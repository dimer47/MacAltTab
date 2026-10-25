import AppKit
import Carbon.HIToolbox

/// Raccourci : une touche + des modificateurs à maintenir (⌥ pour ⌥ ⇥).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // modificateurs Carbon
    var label: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey), label: "⌥ ⇥")

    /// Modificateurs à maintenir enfoncés pendant la bascule (hors ⇧, qui sert à reculer).
    var hold: CGEventFlags {
        var f: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.maskControl) }
        return f
    }
    var needsShift: Bool { modifiers & UInt32(shiftKey) != 0 }

    static func from(event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        var label = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); label += "⌘" }
        // Il faut un modificateur à maintenir : ⌘, ⌥ ou ⌃.
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        label += " " + keyName(event)
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods, label: label)
    }

    private static func keyName(_ e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case kVK_Space: return "Espace"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_ANSI_Grave: return "`"
        default:
            let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            if let i = fKeys.firstIndex(of: Int(e.keyCode)) { return "F\(i + 1)" }
            return (e.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    static func load() -> Shortcut {
        guard let d = UserDefaults.standard.data(forKey: "shortcut"),
              let s = try? JSONDecoder().decode(Shortcut.self, from: d) else { return .default }
        return s
    }

    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "shortcut") }
}

/// Écoute le clavier (autorisation Accessibilité) pour savoir quand ⌥ est relâché
/// et intercepter les touches pendant la bascule.
final class KeyTap {
    var shortcut: Shortcut
    var paused = false
    var isActive: () -> Bool = { false }
    var onTrigger: (_ reverse: Bool) -> Void = { _ in }
    var onKey: (_ event: NSEvent) -> Void = { _ in }
    var onRelease: () -> Void = {}
    private var tap: CFMachPort?

    init(shortcut: Shortcut) { self.shortcut = shortcut }

    var running: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            let me = Unmanaged<KeyTap>.fromOpaque(info!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private static let strict: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if paused { return pass }
        let flags = event.flags
        let active = isActive()
        switch type {
        case .keyDown:
            let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            let held = flags.intersection(Self.strict)
            if code == shortcut.keyCode && held == shortcut.hold && (!shortcut.needsShift || flags.contains(.maskShift)) {
                onTrigger(!shortcut.needsShift && flags.contains(.maskShift))
                return nil
            }
            if active {
                if let e = NSEvent(cgEvent: event) { onKey(e) }
                return nil
            }
        case .keyUp:
            if active { return nil }
        case .flagsChanged:
            if active && !flags.intersection(Self.strict).isSuperset(of: shortcut.hold) { onRelease() }
        default: break
        }
        return pass
    }
}
