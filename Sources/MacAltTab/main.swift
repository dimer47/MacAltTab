import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var switcher: Switcher!
    private var tap: KeyTap!
    private var statusItem: NSStatusItem!
    private var shortcut = Shortcut.load()
    private var recorder: ShortcutRecorder?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        switcher = Switcher()
        tap = KeyTap(shortcut: shortcut)
        tap.isActive = { [weak self] in self?.switcher.active ?? false }
        tap.onTrigger = { [weak self] rev in self?.switcher.trigger(reverse: rev) }
        tap.onKey = { [weak self] e in self?.switcher.key(e) }
        tap.onRelease = { [weak self] in self?.switcher.release() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "MacAltTab")
        let menu = NSMenu()
        menu.delegate = self
        Updater.shared.start()
        statusItem.menu = menu

        startWhenTrusted(prompt: true)
        if !launchedAtLogin && ProcessInfo.processInfo.environment["DEMO"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.openSwitcher() }
        }
        if ProcessInfo.processInfo.environment["DEMO"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.switcher.demo() }
        }
    }

    /// Cliquer sur l'app (Finder, lanceur) ouvre la bascule, comme ⌥ ⇥.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSwitcher()
        return false
    }

    private func openSwitcher() {
        guard tap.running else { return }
        switcher.openSticky()
    }

    private var launchedAtLogin: Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return ev.eventID == kAEOpenApplication
            && ev.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Sans Accessibilité, impossible d'écouter le clavier : on demande puis on réessaie.
    private func startWhenTrusted(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) && tap.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            switcher.store.refresh()
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.startWhenTrusted(prompt: false)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !tap.running {
            let w = item("⚠︎ Autoriser dans Accessibilité…", #selector(openAccessibility))
            menu.addItem(w)
            menu.addItem(.separator())
        }
        let sc = item("Raccourci : \(shortcut.label)", nil)
        sc.isEnabled = false
        menu.addItem(sc)
        menu.addItem(item("Modifier le raccourci…", #selector(editShortcut)))
        menu.addItem(item("Raccourci par défaut (⌥ ⇥)", #selector(resetShortcut)))
        menu.addItem(.separator())
        let sizeItem = NSMenuItem(title: "Taille", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for sz in TileSize.allCases {
            let i = item(sz.rawValue, #selector(setSize(_:)))
            i.representedObject = sz.rawValue
            i.state = sz == TileSize.current ? .on : .off
            sizes.addItem(i)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)
        let g = item("Séparer réduites et sans fenêtre", #selector(toggleGrouped))
        g.state = SwitcherPanel.grouped ? .on : .off
        menu.addItem(g)
        let relItem = NSMenuItem(title: "Au relâchement de ⌥", action: nil, keyEquivalent: "")
        let rel = NSMenu()
        let v = item("Valider la sélection", #selector(setValidate))
        v.state = Switcher.holdOpen ? .off : .on
        let h = item("Garder ouvert (clic ou Entrée)", #selector(setHoldOpen))
        h.state = Switcher.holdOpen ? .on : .off
        rel.addItem(v)
        rel.addItem(h)
        relItem.submenu = rel
        menu.addItem(relItem)
        let orderItem = NSMenuItem(title: "Ordre", action: nil, keyEquivalent: "")
        let order = NSMenu()
        let recent = item("Utilisation récente", #selector(setRecent))
        recent.state = Switcher.alphabetical ? .off : .on
        let alpha = item("Alphabétique (disposition fixe)", #selector(setAlpha))
        alpha.state = Switcher.alphabetical ? .on : .off
        order.addItem(recent)
        order.addItem(alpha)
        orderItem.submenu = order
        menu.addItem(orderItem)
        let login = item("Lancer à l'ouverture de session", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Rechercher les mises à jour…", #selector(checkUpdates)))
        let au = item("Mises à jour automatiques", #selector(toggleAutoUpdate))
        au.state = Updater.auto ? .on : .off
        menu.addItem(au)
        let ver = item("Version \(Updater.installed)", nil)
        ver.isEnabled = false
        menu.addItem(ver)
        menu.addItem(.separator())
        menu.addItem(item("Quitter", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func setValidate() { Switcher.holdOpen = false }
    @objc private func setHoldOpen() { Switcher.holdOpen = true }

    @objc private func setRecent() { Switcher.alphabetical = false }
    @objc private func setAlpha() { Switcher.alphabetical = true }

    @objc private func toggleGrouped() { SwitcherPanel.grouped.toggle() }

    @objc private func setSize(_ i: NSMenuItem) {
        if let raw = i.representedObject as? String, let sz = TileSize(rawValue: raw) { TileSize.current = sz }
    }

    @objc private func checkUpdates() { Updater.shared.check(silent: false) }

    @objc private func toggleAutoUpdate() {
        Updater.auto.toggle()
        Updater.shared.start()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func editShortcut() {
        tap.paused = true
        recorder = ShortcutRecorder(current: shortcut) { [weak self] new in
            guard let self else { return }
            if let new {
                self.shortcut = new
                self.tap.shortcut = new
                new.save()
            }
            self.tap.paused = false
            self.recorder = nil
        }
        recorder?.show()
    }

    @objc private func resetShortcut() {
        shortcut = .default
        tap.shortcut = shortcut
        shortcut.save()
    }
}

/// Petite fenêtre qui capture la prochaine combinaison de touches.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var monitor: Any?
    private let done: (Shortcut?) -> Void
    private var finished = false
    private let label = NSTextField(labelWithString: "")

    init(current: Shortcut, done: @escaping (Shortcut?) -> Void) {
        self.done = done
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Raccourci de MacAltTab"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let info = NSTextField(wrappingLabelWithString: "Tape la nouvelle combinaison (avec ⌘, ⌥ ou ⌃).\nÉchap pour annuler.")
        info.alignment = .center
        label.stringValue = "Actuel : \(current.label)"
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.alignment = .center
        let stack = NSStackView(views: [info, label])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        window.contentView = stack
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.finish(nil); return nil }
            if let s = Shortcut.from(event: e) {
                self.label.stringValue = s.label
                self.finish(s)
            } else { NSSound.beep() }
            return nil
        }
    }

    private func finish(_ s: Shortcut?) {
        guard !finished else { return }
        finished = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (s == nil ? 0 : 0.4)) { self.window.close() }
        done(s)
    }

    func windowWillClose(_ notification: Notification) { finish(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
