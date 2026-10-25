import AppKit

struct WinItem {
    let app: NSRunningApplication
    let wid: CGWindowID?   // nil : app ouverte sans fenêtre
    let ax: AXUIElement?
    let title: String
    let minimized: Bool
    let otherSpace: Bool
    var frame: CGRect = .zero // coordonnées écran, origine en haut à gauche
    /// Onglets natifs de macOS (Terminal, Finder) : une fenêtre par onglet, superposées.
    var tabs: [WinItem] = []
    var badge: String?

    var id: String { wid.map { "w\($0)" } ?? "a\(app.processIdentifier)" }
    var appName: String { app.localizedName ?? "?" }
    var label: String { title.isEmpty ? appName : title }
}

/// Liste toutes les fenêtres de tous les bureaux, par ordre d'utilisation.
final class WindowStore {
    private let q = DispatchQueue(label: "windows", qos: .userInteractive)
    private var axCache: [CGWindowID: AXUIElement] = [:] // accès sur q
    private var junk = Set<CGWindowID>()                  // fenêtres CG sans équivalent AX
    private var mru: [CGWindowID] = []                    // la plus récente en premier
    private(set) var items: [WinItem] = []                // accès sur le fil principal

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.noteFocus(pid: app.processIdentifier)
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refresh() }
        }
    }

    /// Note la fenêtre active d'une app comme la plus récente.
    func noteFocus(pid: pid_t) {
        q.async {
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.25)
            if let w: AXUIElement = el.attr(kAXFocusedWindowAttribute), let id = w.windowID { self.bump(id) }
        }
    }

    func noteFocus(wid: CGWindowID) { q.async { self.bump(wid) } }

    private func bump(_ id: CGWindowID) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        if mru.count > 500 { mru.removeLast() }
    }

    func refresh(done: (() -> Void)? = nil) {
        let me = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        q.async {
            let list = self.build(apps: apps, front: front)
            DispatchQueue.main.async {
                self.items = list
                done?()
            }
        }
    }

    // MARK: - Construction de la liste (sur q)

    private func build(apps: [NSRunningApplication], front: pid_t?) -> [WinItem] {
        let byPid = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Toutes les fenêtres de tous les bureaux, sans leur titre (pas besoin d'enregistrer l'écran).
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var cg: [(wid: CGWindowID, pid: pid_t, onScreen: Bool)] = []
        for d in info {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let wid = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, byPid[pid] != nil,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  (b["Width"] ?? 0) >= 50, (b["Height"] ?? 0) >= 50 else { continue }
            if let a = d[kCGWindowAlpha as String] as? Double, a <= 0 { continue }
            cg.append((wid, pid, (d[kCGWindowIsOnscreen as String] as? Bool) ?? false))
        }
        let alive = Set(cg.map(\.wid))
        axCache = axCache.filter { alive.contains($0.key) }
        junk.formIntersection(alive)

        // 2. Éléments d'Accessibilité : bureau actuel d'abord, puis recherche des autres bureaux.
        var searches: [(pid_t, Set<CGWindowID>)] = []
        for app in apps {
            let pid = app.processIdentifier
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 0.25)
            let wins: [AXUIElement] = el.attr(kAXWindowsAttribute) ?? []
            for w in wins { if let id = w.windowID { axCache[id] = w } }
            if pid == front, let f: AXUIElement = el.attr(kAXFocusedWindowAttribute), let id = f.windowID,
               mru.first != id { bump(id) }
            let missing = Set(cg.filter { $0.pid == pid && axCache[$0.wid] == nil && !junk.contains($0.wid) }.map(\.wid))
            if !missing.isEmpty { searches.append((pid, missing)) }
        }

        // Recherche en parallèle, une app par cœur.
        if !searches.isEmpty {
            let lock = NSLock()
            var found: [CGWindowID: AXUIElement] = [:]
            DispatchQueue.concurrentPerform(iterations: searches.count) { k in
                let r = Self.findOnOtherSpaces(pid: searches[k].0, missing: searches[k].1)
                lock.lock(); found.merge(r) { a, _ in a }; lock.unlock()
            }
            axCache.merge(found) { a, _ in a }
            for (_, m) in searches { junk.formUnion(m.filter { found[$0] == nil }) }
        }

        // 3. Fenêtres retenues : vraies fenêtres (standard ou dialogue).
        var windows: [(WinItem, Int)] = []
        var onScreenTabs = Set<Int>()
        var tabGroups: [String: Int] = [:]
        var groupMembers: [String: [WinItem]] = [:] // onglets natifs (Terminal, Finder) : une seule tuile par fenêtre
        var appsWithWindows = Set<pid_t>()
        let mruIndex = Dictionary(mru.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for (z, w) in cg.enumerated() {
            guard let ax = axCache[w.wid], let app = byPid[w.pid] else { continue }
            let subrole: String? = ax.attr(kAXSubroleAttribute)
            guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
            let minimized: Bool = ax.attr(kAXMinimizedAttribute) ?? false
            var item = WinItem(app: app, wid: w.wid, ax: ax, title: ax.attr(kAXTitleAttribute) ?? "",
                               minimized: minimized, otherSpace: !w.onScreen && !minimized && !app.isHidden)
            var pos = CGPoint.zero, size = CGSize.zero
            if let v: AXValue = ax.attr(kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &pos) }
            if let v: AXValue = ax.attr(kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &size) }
            item.frame = CGRect(origin: pos, size: size)
            // Les onglets natifs de macOS sont des fenêtres superposées : n'en garder qu'une,
            // celle affichée, ou à défaut la plus récente. Chrome et Safari ont leurs propres onglets.
            // Deux fenêtres d'une même app exactement superposées = deux onglets.
            if !minimized, let bid = app.bundleIdentifier, bid != "com.google.Chrome", bid != "com.apple.Safari" {
                let key = "\(w.pid)|\(Int(pos.x)),\(Int(pos.y)),\(Int(size.width)),\(Int(size.height))"
                let rank = mruIndex[w.wid] ?? 10_000 + z
                groupMembers[key, default: []].append(item)
                if let j = tabGroups[key] {
                    let oldOn = onScreenTabs.contains(j)
                    if (w.onScreen && !oldOn) || (w.onScreen == oldOn && rank < windows[j].1) {
                        windows[j] = (item, rank)
                        if w.onScreen { onScreenTabs.insert(j) }
                    }
                    continue
                }
                tabGroups[key] = windows.count
                if w.onScreen { onScreenTabs.insert(windows.count) }
            }
            windows.append((item, mruIndex[w.wid] ?? 10_000 + z))
            appsWithWindows.insert(w.pid)
        }
        for (key, j) in tabGroups {
            let members = groupMembers[key] ?? []
            if members.count > 1 { windows[j].0.tabs = members.sorted { ($0.wid ?? 0) < ($1.wid ?? 0) } }
        }
        var out = windows.sorted { $0.1 < $1.1 }.map(\.0)

        // 4. Apps ouvertes sans fenêtre, à la fin.
        for app in apps where !appsWithWindows.contains(app.processIdentifier) {
            out.append(WinItem(app: app, wid: nil, ax: nil, title: "", minimized: false, otherSpace: false))
        }

        // 5. Pastilles de notification du Dock.
        let badges = dockBadges()
        for i in out.indices {
            if let path = out[i].app.bundleURL?.standardizedFileURL.path { out[i].badge = badges[path] }
        }
        return out
    }

    /// Les fenêtres des autres bureaux n'apparaissent pas dans kAXWindows :
    /// on essaie les identifiants internes un par un, comme AltTab.
    /// Les apps ouvertes depuis longtemps (VS Code, Chrome) dépassent 1 000 : on va jusqu'à 30 000.
    /// Une fois trouvées, les fenêtres restent en cache : la recherche n'a lieu qu'une fois.
    private static func findOnOtherSpaces(pid: pid_t, missing: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var left = missing
        var out: [CGWindowID: AXUIElement] = [:]
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        for eid: UInt64 in 0..<30_000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: eid) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            let sub: String? = el.attr(kAXSubroleAttribute)
            guard sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole else { continue }
            guard let id = el.windowID, left.contains(id) else { continue }
            out[id] = el
            left.remove(id)
            if left.isEmpty { break }
        }
        return out
    }

    private func dockBadges() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let el = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.25)
        guard let kids: [AXUIElement] = el.attr(kAXChildrenAttribute), let list = kids.first,
              let icons: [AXUIElement] = list.attr(kAXChildrenAttribute) else { return [:] }
        var out: [String: String] = [:]
        for i in icons {
            guard let label: String = i.attr("AXStatusLabel"), !label.isEmpty,
                  let url: URL = i.attr(kAXURLAttribute) else { continue }
            out[url.standardizedFileURL.path] = label
        }
        return out
    }
}

/// Actions sur une fenêtre ou une app.
enum WindowActions {
    static func focus(_ it: WinItem) {
        guard let wid = it.wid, let ax = it.ax else {
            // App sans fenêtre : la rouvrir, ce qui crée souvent une fenêtre.
            if let url = it.app.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else { it.app.activate() }
            return
        }
        if it.app.isHidden { it.app.unhide() }
        if it.minimized { AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        SkyLight.focus(pid: it.app.processIdentifier, wid: wid)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
    }

    static func close(_ it: WinItem) {
        guard let ax = it.ax, let b: AXUIElement = ax.attr(kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(b, kAXPressAction as CFString)
    }

    static func minimize(_ it: WinItem) {
        guard let ax = it.ax else { return }
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, (!it.minimized) as CFBoolean)
    }

    static func fullScreen(_ it: WinItem) {
        guard let ax = it.ax else { return }
        let on: Bool = ax.attr("AXFullScreen") ?? false
        AXUIElementSetAttributeValue(ax, "AXFullScreen" as CFString, (!on) as CFBoolean)
    }

    static func quit(_ it: WinItem) { it.app.terminate() }
}
