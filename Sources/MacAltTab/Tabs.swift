import AppKit

struct BrowserTab {
    let title: String
    let detail: String   // domaine de l'URL, ou processus pour Terminal
    let active: Bool
    let index: Int       // 1, 2, 3… (numérotation AppleScript)
}

struct TabWindow {
    let scriptID: String // identifiant AppleScript de la fenêtre
    let frame: CGRect
    let tabs: [BrowserTab]
}

/// Onglets de Chrome, Safari et Terminal, lus par AppleScript (autorisation « Automatisation »).
enum Tabs {
    static let supported: Set<String> = ["com.google.Chrome", "com.apple.Safari"]
    private static let q = DispatchQueue(label: "tabs", qos: .userInitiated)
    private static var cache: [String: [TabWindow]] = [:] // accès sur le fil principal

    /// Lit les onglets des apps prises en charge qui sont ouvertes, puis appelle done.
    static func refresh(_ apps: [NSRunningApplication], done: @escaping () -> Void) {
        let ids = Set(apps.compactMap(\.bundleIdentifier)).intersection(supported)
        guard !ids.isEmpty else { return }
        q.async {
            var res: [String: [TabWindow]] = [:]
            for id in ids { if let w = read(id) { res[id] = w } }
            DispatchQueue.main.async {
                cache.merge(res) { _, b in b }
                done()
            }
        }
    }

    /// Onglets de la fenêtre, retrouvée par sa position à l'écran. Rien si un seul onglet.
    static func of(_ it: WinItem) -> (TabWindow, String)? {
        guard it.wid != nil, let id = it.app.bundleIdentifier, let wins = cache[id] else { return nil }
        let f = it.frame
        guard let w = wins.first(where: {
            abs($0.frame.minX - f.minX) < 4 && abs($0.frame.minY - f.minY) < 4
                && abs($0.frame.width - f.width) < 4 && abs($0.frame.height - f.height) < 4
        }), w.tabs.count > 1 else { return nil }
        return (w, id)
    }

    /// Passe sur l'onglet choisi ; la fenêtre est mise au premier plan à part.
    static func select(_ tab: BrowserTab, in w: TabWindow, app id: String) {
        let script: String
        switch id {
        case "com.google.Chrome":
            script = "tell application id \"\(id)\" to set active tab index of (first window whose id is \(w.scriptID)) to \(tab.index)"
        case "com.apple.Safari":
            script = "tell application id \"\(id)\" to tell (first window whose id is \(w.scriptID)) to set current tab to tab \(tab.index)"
        default:
            script = "tell application id \"\(id)\" to set selected of tab \(tab.index) of (first window whose id is \(w.scriptID)) to true"
        }
        q.async { _ = run(script) }
    }

    /// Ferme un onglet. Terminal n'a pas de commande pour ça : on affiche l'onglet,
    /// puis on appuie sur le bouton de fermeture de sa fenêtre (chaque onglet en est une).
    static func close(_ tab: BrowserTab, in w: TabWindow, app: NSRunningApplication, done: @escaping () -> Void) {
        guard let id = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        q.async {
            if id == "com.apple.Terminal" {
                _ = run("tell application id \"\(id)\" to set selected of tab \(tab.index) of (first window whose id is \(w.scriptID)) to true")
                usleep(150_000)
                let el = AXUIElementCreateApplication(pid)
                let wins: [AXUIElement] = el.attr(kAXWindowsAttribute) ?? []
                for win in wins {
                    var pos = CGPoint.zero, size = CGSize.zero
                    if let v: AXValue = win.attr(kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &pos) }
                    if let v: AXValue = win.attr(kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &size) }
                    guard abs(pos.x - w.frame.minX) < 4, abs(pos.y - w.frame.minY) < 4,
                          let b: AXUIElement = win.attr(kAXCloseButtonAttribute) else { continue }
                    AXUIElementPerformAction(b, kAXPressAction as CFString)
                    break
                }
            } else {
                _ = run("tell application id \"\(id)\" to close tab \(tab.index) of (first window whose id is \(w.scriptID))")
            }
            usleep(250_000)
            if let r = read(id) { DispatchQueue.main.async { cache[id] = r; done() } }
            else { DispatchQueue.main.async(execute: done) }
        }
    }

    // MARK: - Lecture

    private static let sep = "\u{1F}"

    private static func read(_ id: String) -> [TabWindow]? {
        let body: String
        switch id {
        case "com.google.Chrome":
            body = """
            repeat with w in windows
              set b to bounds of w
              set out to out & "W" & S & (id of w) & S & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & S & (active tab index of w) & linefeed
              repeat with t in tabs of w
                set out to out & "T" & S & (title of t) & S & (URL of t) & linefeed
              end repeat
            end repeat
            """
        case "com.apple.Safari":
            body = """
            repeat with w in windows
              try
                set b to bounds of w
                set out to out & "W" & S & (id of w) & S & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & S & (index of current tab of w) & linefeed
                repeat with t in tabs of w
                  set out to out & "T" & S & (name of t) & S & (URL of t) & linefeed
                end repeat
              end try
            end repeat
            """
        default:
            body = """
            repeat with w in windows
              set b to bounds of w
              set k to 0
              set i to 0
              repeat with t in tabs of w
                set i to i + 1
                if selected of t then set k to i
              end repeat
              set out to out & "W" & S & (id of w) & S & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & S & k & linefeed
              repeat with t in tabs of w
                set p to ""
                try
                  set p to last item of (processes of t)
                end try
                set ct to ""
                try
                  set ct to custom title of t
                end try
                set out to out & "T" & S & ct & S & p & linefeed
              end repeat
            end repeat
            """
        }
        let script = "set S to ASCII character 31\nset out to \"\"\ntell application id \"\(id)\"\n\(body)\nend tell\nreturn out"
        guard let text = run(script) else { return nil }
        return parse(text, terminal: id == "com.apple.Terminal")
    }

    private static func parse(_ text: String, terminal: Bool) -> [TabWindow] {
        var out: [TabWindow] = []
        var cur: (id: String, frame: CGRect, active: Int)?
        var tabs: [BrowserTab] = []
        func flush() { if let c = cur { out.append(TabWindow(scriptID: c.id, frame: c.frame, tabs: tabs)) } }
        for line in text.split(separator: "\n") {
            let f = line.components(separatedBy: sep)
            if f.first == "W", f.count >= 4 {
                flush()
                tabs = []
                let n = f[2].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                let r = n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1]) : .zero
                cur = (f[1], r, Int(f[3]) ?? 0)
            } else if f.first == "T", f.count >= 3, let c = cur {
                let i = tabs.count + 1
                var title = f[1], detail = f[2]
                if terminal {
                    if title.isEmpty { title = detail.isEmpty ? "Onglet \(i)" : detail }
                } else {
                    detail = URL(string: f[2])?.host ?? f[2]
                    if title.isEmpty { title = detail }
                }
                tabs.append(BrowserTab(title: title, detail: detail, active: i == c.active, index: i))
            }
        }
        flush()
        return out
    }

    private static func run(_ source: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? r?.stringValue : nil
    }
}
