import AppKit
import Carbon.HIToolbox

/// Déroulé d'une bascule : ⌥ ⇥ ouvre, ⇥ avance, relâcher ⌥ valide.
final class Switcher {
    let store = WindowStore()
    private let panel = SwitcherPanel()
    private let tabsPanel = TabsPanel()
    private var hoverWork: DispatchWorkItem?
    private var tabsShown: (TabWindow, String, WinItem)?
    /// Onglet choisi au clavier (⇧ ↓ / ⇧ ↑), numéro AppleScript.
    private var tabSel: Int?
    private(set) var active = false
    private var all: [WinItem] = []
    private var list: [WinItem] = []
    private var sel = 0
    private var query = ""
    private var showWork: DispatchWorkItem?
    /// Ouvert sans ⌥ maintenu (clic sur l'app) : reste ouvert jusqu'au choix.
    private var sticky = false
    private var clickMonitor: Any?

    /// Ordre fixe (alphabétique) plutôt que par utilisation récente.
    static var alphabetical: Bool {
        get { UserDefaults.standard.bool(forKey: "alphabetical") }
        set { UserDefaults.standard.set(newValue, forKey: "alphabetical") }
    }

    init() {
        // Survol : on attend que la souris s'arrête, sinon aller vers la liste
        // des onglets en traversant d'autres tuiles changerait la sélection.
        panel.onHover = { [weak self] i in
            self?.hoverWork?.cancel()
            let w = DispatchWorkItem { self?.setSel(i) }
            self?.hoverWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
        }
        panel.onClick = { [weak self] i in self?.setSel(i); self?.confirm() }
        panel.onAction = { [weak self] i, a in self?.perform(a, on: i) }
        tabsPanel.onPick = { [weak self] k in self?.pickTab(k) }
        tabsPanel.onEnter = { [weak self] in self?.hoverWork?.cancel() }
        tabsPanel.onClose = { [weak self] k in self?.closeTab(k) }
        store.refresh()
    }

    func trigger(reverse: Bool) {
        if active { move(reverse ? -1 : 1); return }
        active = true
        query = ""
        all = store.items
        applyFilter()
        // Sélection de départ : la fenêtre utilisée juste avant, quel que soit le tri.
        let target = all.count > 1 ? all[reverse ? all.count - 1 : 1].id : all.first?.id
        sel = list.firstIndex { $0.id == target } ?? 0
        // Un ⌥ ⇥ rapide bascule sans afficher la fenêtre, comme macOS.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.panel.show(self.list, selected: self.sel, query: self.query)
            self.updateTabs()
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        store.refresh { [weak self] in self?.reload() }
        Tabs.refresh(all.map(\.app)) { [weak self] in self?.tabsLoaded() }
    }

    /// Si une fenêtre a des onglets, garder la place à droite pour leur liste.
    /// La valeur reste d'une ouverture à l'autre : la grille ne saute pas.
    private func tabsLoaded() {
        let need: CGFloat = list.contains { Tabs.of($0) != nil } ? TabsPanel.width + 10 : 0
        if need != panel.reserveRight {
            panel.reserveRight = need
            applyFilter()
            if active && panel.isVisible { panel.update(list, selected: sel, query: query) }
        }
        updateTabs()
    }

    /// Affiche les onglets de la fenêtre sélectionnée, s'il y en a plusieurs.
    private func updateTabs() {
        guard active, panel.isVisible, list.indices.contains(sel), let (w, id) = Tabs.of(list[sel]) else {
            tabsPanel.hide()
            tabsShown = nil
            tabSel = nil
            return
        }
        if tabsShown?.2.id != list[sel].id { tabSel = nil }
        tabsShown = (w, id, list[sel])
        tabsPanel.show(w.tabs, icon: list[sel].app.icon, beside: panel.glassScreenFrame, highlight: tabSel)
    }

    private func closeTab(_ k: Int) {
        guard let (w, _, it) = tabsShown, let tab = w.tabs.first(where: { $0.index == k }) else { return }
        tabSel = nil
        Tabs.close(tab, in: w, app: it.app) { [weak self] in
            guard let self, self.active else { return }
            self.store.refresh { self.reload() }
            self.updateTabs()
        }
    }

    private func moveTab(_ d: Int) {
        guard let (w, _, _) = tabsShown, !w.tabs.isEmpty else { return }
        let n = w.tabs.count
        let cur = tabSel ?? (w.tabs.first { $0.active }?.index ?? 1)
        tabSel = tabSel == nil ? (d > 0 ? min(cur + 1, n) : max(cur - 1, 1)) : min(max(cur + d, 1), n)
        updateTabs()
    }

    private func pickTab(_ k: Int) {
        guard let (w, id, it) = tabsShown, let tab = w.tabs.first(where: { $0.index == k }) else { return }
        close()
        Tabs.select(tab, in: w, app: id)
        WindowActions.focus(it)
        if let wid = it.wid { store.noteFocus(wid: wid) }
    }

    /// Nouvelle liste reçue : garder la même sélection.
    private func reload() {
        guard active else { return }
        let keep = list.indices.contains(sel) ? list[sel].id : nil
        all = store.items
        applyFilter()
        if let keep, let i = list.firstIndex(where: { $0.id == keep }) { sel = i }
        sel = min(sel, max(list.count - 1, 0))
        if panel.isVisible { panel.update(list, selected: sel, query: query) }
        updateTabs()
    }

    private func applyFilter() {
        let words = norm(query).split(separator: " ").map(String.init)
        list = words.isEmpty ? all : all.filter { it in
            let hay = norm(it.appName + " " + it.title)
            return words.allSatisfy { hay.contains($0) }
        }
        if Self.alphabetical {
            list.sort {
                let a = $0.appName.localizedStandardCompare($1.appName)
                return a != .orderedSame ? a == .orderedAscending : $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        list = list.enumerated().sorted {
            let a = SwitcherPanel.section($0.element), b = SwitcherPanel.section($1.element)
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        _ = panel.computeCapacity()
        if list.count > panel.capacity { list = Array(list.prefix(panel.capacity)) }
    }

    private func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private func move(_ d: Int) {
        guard !list.isEmpty else { return }
        setSel((sel + d + list.count) % list.count)
    }

    private func setSel(_ i: Int) {
        guard list.indices.contains(i) else { return }
        sel = i
        panel.select(i)
        updateTabs()
    }

    func key(_ e: NSEvent) {
        switch Int(e.keyCode) {
        case kVK_Escape: close()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let k = tabSel { pickTab(k) } else { confirm() }
        case kVK_DownArrow where e.modifierFlags.contains(.shift), kVK_UpArrow where e.modifierFlags.contains(.shift):
            moveTab(Int(e.keyCode) == kVK_DownArrow ? 1 : -1)
        case kVK_LeftArrow: move(-1)
        case kVK_RightArrow: move(1)
        case kVK_UpArrow, kVK_DownArrow:
            if let t = panel.neighbor(of: sel, down: Int(e.keyCode) == kVK_DownArrow) { setSel(t) }
        case kVK_Delete where e.modifierFlags.contains(.shift):
            if let k = tabSel { closeTab(k) }
        case kVK_Delete:
            guard !query.isEmpty else { return }
            query.removeLast()
            refilter()
        default:
            guard !e.modifierFlags.contains(.command),
                  let c = e.charactersIgnoringModifiers, !c.isEmpty,
                  c.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "." })
            else { return }
            query += c
            refilter()
        }
    }

    private func refilter() {
        applyFilter()
        sel = 0
        showNow()
    }

    private func showNow() {
        showWork?.cancel()
        if panel.isVisible { panel.update(list, selected: sel, query: query) }
        else if active { panel.show(list, selected: sel, query: query) }
        updateTabs()
    }

    /// Relâcher ⌥ garde la grille ouverte (clic ou Entrée pour valider).
    /// Un ⌥ ⇥ tapé vite, avant l'apparition de la grille, bascule quand même aussitôt.
    static var holdOpen: Bool {
        get { UserDefaults.standard.object(forKey: "holdOpen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "holdOpen") }
    }

    func release() {
        guard !sticky else { return }
        if Self.holdOpen && panel.isVisible { makeSticky() } else { confirm() }
    }

    private func makeSticky() {
        sticky = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    /// Ouvre la bascule sans touche maintenue : clic, Entrée ou Échap pour sortir.
    func openSticky() {
        if active { return }
        trigger(reverse: false)
        showNow()
        makeSticky()
    }

    func confirm() {
        guard active else { return }
        let it = list.indices.contains(sel) ? list[sel] : nil
        close()
        guard let it else { return }
        WindowActions.focus(it)
        if let w = it.wid { store.noteFocus(wid: w) }
    }

    func close() {
        active = false
        sticky = false
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        showWork?.cancel()
        panel.hide()
        tabsPanel.hide()
        tabsShown = nil
        tabSel = nil
    }

    private func perform(_ a: TileAction, on i: Int) {
        guard list.indices.contains(i) else { return }
        let it = list[i]
        switch a {
        case .close: WindowActions.close(it)
        case .minimize: WindowActions.minimize(it)
        case .fullScreen:
            close()
            WindowActions.focus(it)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { WindowActions.fullScreen(it) }
            return
        case .quit: WindowActions.quit(it)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.store.refresh { self?.reload() }
        }
    }

    /// Affiche la fenêtre sans clavier, pour les captures de test (DEMO=1).
    func demo() {
        store.refresh { [weak self] in
            guard let self else { return }
            self.active = true
            self.all = self.store.items
            self.applyFilter()
            self.sel = min(1, self.list.count - 1)
            self.showNow()
        }
    }
}
