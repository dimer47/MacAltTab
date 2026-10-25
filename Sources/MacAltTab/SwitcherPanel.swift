import AppKit

enum TileAction { case close, minimize, fullScreen, quit }

/// Tailles S, M, L : seule la taille de l'icône change, le reste en découle.
enum TileSize: String, CaseIterable {
    case s = "S", m = "M", l = "L"
    var icon: CGFloat { switch self { case .s: 76; case .m: 96; case .l: 120 } }
    var font: CGFloat { switch self { case .s: 11; case .m: 12; case .l: 13 } }
    var tileW: CGFloat { icon + 40 }
    var tileH: CGFloat { icon + 66 }

    static var current: TileSize {
        get { TileSize(rawValue: UserDefaults.standard.string(forKey: "size") ?? "") ?? .m }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "size") }
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Fenêtre de bascule : grille d'icônes sur du Liquid Glass.
final class SwitcherPanel {
    static var tileW: CGFloat { TileSize.current.tileW }
    static var tileH: CGFloat { TileSize.current.tileH }
    static let gap: CGFloat = 6, sectionGap: CGFloat = 10, headerH: CGFloat = 22
    static let sectionNames = ["Fenêtres", "Réduites", "Sans fenêtre"]

    /// Regrouper en sections titrées, ou tout afficher d'un bloc.
    static var grouped: Bool {
        get { UserDefaults.standard.object(forKey: "grouped") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "grouped") }
    }
    static let pad: CGFloat = 14, searchH: CGFloat = 38, margin: CGFloat = 40
    /// Largeur maximale de la grille, en part de l'écran.
    static let widthRatio: CGFloat = 0.7

    var onHover: (Int) -> Void = { _ in }
    var onClick: (Int) -> Void = { _ in }
    var onAction: (Int, TileAction) -> Void = { _, _ in }

    private let panel: KeyPanel
    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private let grid = FlippedView()
    private let selector = NSGlassEffectView()
    private let searchIcon = NSImageView()
    private let searchLabel = NSTextField(labelWithString: "")
    private var tiles: [TileView] = []
    private var headers: [NSTextField] = []
    private(set) var capacity = 0

    init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true

        let root = NSView()
        panel.contentView = root
        glass.cornerRadius = 30
        glass.style = .regular
        glass.contentView = content
        glass.wantsLayer = true
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.3
        glass.layer?.shadowRadius = 18
        glass.layer?.shadowOffset = CGSize(width: 0, height: -8)
        root.addSubview(glass)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        searchLabel.font = .systemFont(ofSize: 15)
        searchLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(searchIcon)
        content.addSubview(searchLabel)

        selector.cornerRadius = 18
        selector.style = .regular
        selector.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.35)
        grid.addSubview(selector)
        content.addSubview(grid)
    }

    var isVisible: Bool { panel.isVisible }

    /// Place gardée à droite pour la liste des onglets ; la grille se décale vers la gauche.
    var reserveRight: CGFloat = 0

    /// Cadre du verre à l'écran, pour placer la liste des onglets à côté.
    var glassScreenFrame: NSRect { panel.convertToScreen(glass.frame) }

    /// Nombre de tuiles qui tiennent à l'écran.
    func computeCapacity() -> (cols: Int, rows: Int) {
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let avail = min(vf.width * Self.widthRatio, vf.width - 40 - reserveRight - 2 * Self.margin)
        let cols = max(1, Int((avail - 2 * Self.pad + Self.gap) / (Self.tileW + Self.gap)))
        let rows = max(1, Int((vf.height * 0.85 - Self.searchH - 2 * Self.pad + Self.gap) / (Self.tileH + Self.gap)))
        capacity = cols * rows
        return (cols, rows)
    }

    func show(_ items: [WinItem], selected: Int, query: String) {
        update(items, selected: selected, query: query)
        panel.orderFrontRegardless()
    }

    /// Position (ligne, colonne) de chaque tuile, pour les flèches haut et bas.
    private(set) var cells: [(row: Int, col: Int)] = []

    /// Section d'une tuile : fenêtres, fenêtres réduites, apps sans fenêtre.
    static func section(_ it: WinItem) -> Int { !grouped ? 0 : it.wid == nil ? 2 : it.minimized ? 1 : 0 }

    func update(_ items: [WinItem], selected: Int, query: String) {
        let (maxCols, _) = computeCapacity()
        let size = TileSize.current
        let cols = min(max(items.count, 1), maxCols)

        // Chaque section commence sur une nouvelle ligne.
        cells = []
        var row = 0, col = 0, extra: CGFloat = 0
        var offsets: [CGFloat] = []
        var heads: [(String, Int, CGFloat)] = [] // titre, ligne, décalage
        for (i, it) in items.enumerated() {
            let sec = Self.section(it)
            if Self.grouped && (i == 0 || sec != Self.section(items[i - 1])) {
                if i > 0 { if col != 0 { row += 1; col = 0 }; extra += Self.sectionGap }
                heads.append((Self.sectionNames[sec], row, extra))
                extra += Self.headerH
            } else if col == cols { row += 1; col = 0 }
            cells.append((row, col))
            offsets.append(extra)
            col += 1
        }
        let rows = items.isEmpty ? 0 : row + 1
        let gridW = CGFloat(cols) * Self.tileW + CGFloat(cols - 1) * Self.gap
        let gridH = items.isEmpty ? 60 : CGFloat(rows) * Self.tileH + CGFloat(rows - 1) * Self.gap + extra
        let w = max(gridW + 2 * Self.pad, 420)
        let h = Self.searchH + gridH + 2 * Self.pad

        let vf = (NSScreen.main ?? NSScreen.screens[0]).frame
        let frame = NSRect(x: vf.midX - (w + reserveRight) / 2 - Self.margin, y: vf.midY - h / 2 - Self.margin,
                           width: w + 2 * Self.margin, height: h + 2 * Self.margin)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        glass.frame = NSRect(x: Self.margin, y: Self.margin, width: w, height: h)

        // Barre de recherche
        searchIcon.frame = NSRect(x: Self.pad + 6, y: Self.pad + 2, width: 18, height: 22)
        searchLabel.frame = NSRect(x: Self.pad + 30, y: Self.pad + 3, width: w - 2 * Self.pad - 36, height: 20)
        if query.isEmpty {
            searchLabel.stringValue = "Tape pour filtrer"
            searchLabel.textColor = .tertiaryLabelColor
        } else {
            searchLabel.stringValue = query
            searchLabel.textColor = .labelColor
        }

        // Grille, centrée
        grid.frame = NSRect(x: (w - gridW) / 2, y: Self.pad + Self.searchH, width: gridW, height: gridH)
        while headers.count < heads.count {
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            l.textColor = .secondaryLabelColor
            headers.append(l)
            grid.addSubview(l)
        }
        for (i, l) in headers.enumerated() {
            l.isHidden = i >= heads.count
            guard i < heads.count else { continue }
            l.stringValue = heads[i].0.uppercased()
            l.frame = NSRect(x: 6, y: CGFloat(heads[i].1) * (Self.tileH + Self.gap) + heads[i].2 + 2,
                             width: gridW - 12, height: 16)
        }
        while tiles.count < items.count {
            let t = TileView()
            t.panel = self
            tiles.append(t)
            grid.addSubview(t)
        }
        for (i, t) in tiles.enumerated() {
            guard i < items.count else { t.isHidden = true; continue }
            t.isHidden = false
            t.index = i
            t.frame = NSRect(x: CGFloat(cells[i].col) * (Self.tileW + Self.gap),
                             y: CGFloat(cells[i].row) * (Self.tileH + Self.gap) + offsets[i],
                             width: Self.tileW, height: Self.tileH)
            t.configure(items[i], size: size)
        }
        select(selected, animated: false)
    }

    /// Tuile au-dessus ou en dessous, dans la colonne la plus proche.
    func neighbor(of i: Int, down: Bool) -> Int? {
        guard cells.indices.contains(i) else { return nil }
        let target = cells[i].row + (down ? 1 : -1)
        return cells.indices.filter { cells[$0].row == target }
            .min { abs(cells[$0].col - cells[i].col) < abs(cells[$1].col - cells[i].col) }
    }

    func select(_ i: Int, animated: Bool = true) {
        guard i >= 0, i < tiles.count, !tiles[i].isHidden else { selector.isHidden = true; return }
        selector.isHidden = false
        let f = tiles[i].frame
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                selector.animator().frame = f
            }
        } else { selector.frame = f }
    }

    func hide() {
        panel.orderOut(nil)
        tiles.forEach { $0.hovered = false }
    }

    fileprivate func hovered(_ i: Int) { onHover(i) }
    fileprivate func clicked(_ i: Int) { onClick(i) }
    fileprivate func action(_ i: Int, _ a: TileAction) { onAction(i, a) }
}

/// Une tuile : titre au-dessus, grande icône, boutons d'action en dessous au survol.
private final class TileView: NSView {
    weak var panel: SwitcherPanel?
    var index = 0
    private let smallIcon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let state = NSImageView()
    private let icon = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let dash = NSView()
    private let actions = NSStackView()
    private var windowButtons: [NSButton] = []
    private var tracking: NSTrackingArea?

    var hovered = false { didSet { actions.isHidden = !hovered } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        state.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown

        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.drawsBackground = true
        badge.backgroundColor = .systemRed
        badge.layer?.cornerRadius = 8
        badge.layer?.masksToBounds = true

        dash.wantsLayer = true
        dash.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        dash.layer?.cornerRadius = 1.5

        actions.orientation = .horizontal
        actions.spacing = 2
        actions.alignment = .centerY
        actions.distribution = .gravityAreas
        let defs: [(String, String, TileAction)] = [
            ("xmark", "Fermer la fenêtre", .close),
            ("minus", "Réduire / restaurer", .minimize),
            ("arrow.up.left.and.arrow.down.right", "Plein écran", .fullScreen),
            ("power", "Quitter l'app", .quit),
        ]
        for (sym, tip, a) in defs {
            let b = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: tip)!, target: self, action: #selector(tap(_:)))
            b.bezelStyle = .glass
            b.controlSize = .small
            b.toolTip = tip
            b.tag = [TileAction.close, .minimize, .fullScreen, .quit].firstIndex(of: a)!
            actions.addView(b, in: .center)
            if a != .quit { windowButtons.append(b) }
        }
        actions.isHidden = true

        [smallIcon, title, state, icon, badge, dash, actions].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ it: WinItem, size: TileSize) {
        let W = size.tileW, I = size.icon
        smallIcon.frame = NSRect(x: 8, y: 9, width: 14, height: 14)
        title.font = .systemFont(ofSize: size.font, weight: .medium)
        title.frame = NSRect(x: 25, y: 8, width: W - 33, height: size.font + 5)
        state.frame = NSRect(x: W - 21, y: 9, width: 13, height: 13)
        icon.frame = NSRect(x: (W - I) / 2, y: 30, width: I, height: I)
        dash.frame = NSRect(x: (W - 14) / 2, y: icon.frame.maxY + 3, width: 14, height: 3)
        actions.frame = NSRect(x: 0, y: icon.frame.maxY + 8, width: W, height: 24)
        let img = it.app.icon
        smallIcon.image = img
        icon.image = img
        title.stringValue = it.label
        title.toolTip = it.title.isEmpty ? it.appName : "\(it.appName) — \(it.title)"
        let sym: String? = it.wid == nil ? nil
            : it.minimized ? "minus.circle"
            : it.app.isHidden ? "eye.slash"
            : it.otherSpace ? "square.on.square" : nil
        state.image = sym.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        state.isHidden = sym == nil
        title.frame.size.width = W - 33 - (sym == nil ? 0 : 14)
        if let b = it.badge {
            badge.stringValue = b
            let bw = max(16, CGFloat(b.count) * 7 + 8)
            badge.frame = NSRect(x: icon.frame.maxX - bw + 4, y: icon.frame.minY - 2, width: bw, height: 16)
            badge.isHidden = false
        } else { badge.isHidden = true }
        dash.isHidden = it.wid != nil
        windowButtons.forEach { $0.isHidden = it.wid == nil }
    }

    @objc private func tap(_ b: NSButton) {
        panel?.action(index, [TileAction.close, .minimize, .fullScreen, .quit][b.tag])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        panel?.hovered(index)
    }

    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { panel?.clicked(index) }
    }
}
