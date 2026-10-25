import AppKit

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Liste des onglets de la fenêtre sélectionnée, à côté de la grille.
final class TabsPanel {
    static let width: CGFloat = 320, rowH: CGFloat = 34, pad: CGFloat = 8, margin: CGFloat = 40
    var onPick: (Int) -> Void = { _ in }
    var onEnter: () -> Void = {}
    var onClose: (Int) -> Void = { _ in }

    private let panel: NSPanel
    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private var rows: [TabRow] = []

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let root = NSView()
        panel.contentView = root
        glass.cornerRadius = 22
        glass.style = .regular
        glass.contentView = content
        glass.wantsLayer = true
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.3
        glass.layer?.shadowRadius = 18
        glass.layer?.shadowOffset = CGSize(width: 0, height: -8)
        root.addSubview(glass)
    }

    /// Affiche les onglets à droite de `beside` (ou à gauche si l'écran est trop étroit).
    func show(_ tabs: [BrowserTab], icon: NSImage?, beside: NSRect, highlight: Int? = nil) {
        let screen = NSScreen.screens.first { $0.frame.intersects(beside) } ?? NSScreen.main!
        let maxRows = max(1, Int((beside.height - 2 * Self.pad) / Self.rowH))
        let shown = Array(tabs.prefix(maxRows))
        let h = CGFloat(shown.count) * Self.rowH + 2 * Self.pad
        let vf = screen.visibleFrame
        var x = beside.maxX + 10
        if x + Self.width > vf.maxX - 8 { x = beside.minX - 10 - Self.width }
        x = min(max(x, vf.minX + 8), vf.maxX - 8 - Self.width)
        let y = beside.maxY - h
        panel.setFrame(NSRect(x: x - Self.margin, y: y - Self.margin,
                              width: Self.width + 2 * Self.margin, height: h + 2 * Self.margin), display: false)
        glass.frame = NSRect(x: Self.margin, y: Self.margin, width: Self.width, height: h)

        while rows.count < shown.count {
            let r = TabRow()
            r.owner = self
            rows.append(r)
            content.addSubview(r)
        }
        for (i, r) in rows.enumerated() {
            r.isHidden = i >= shown.count
            guard i < shown.count else { continue }
            r.frame = NSRect(x: Self.pad, y: Self.pad + CGFloat(i) * Self.rowH, width: Self.width - 2 * Self.pad, height: Self.rowH)
            r.configure(shown[i], icon: icon, keyed: shown[i].index == highlight)
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    fileprivate func pick(_ i: Int) { onPick(i) }
    fileprivate func entered() { onEnter() }
    fileprivate func closeTab(_ i: Int) { onClose(i) }
}

private final class TabRow: NSView {
    weak var owner: TabsPanel?
    private var tabIndex = 0
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private var active = false
    private var hovered = false { didSet { paint() } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.alignment = .right
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer l'onglet")
        closeButton.isBordered = false
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Fermer l'onglet"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        [icon, title, detail, closeButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var keyed = false

    func configure(_ t: BrowserTab, icon img: NSImage?, keyed: Bool) {
        self.keyed = keyed
        tabIndex = t.index
        active = t.active
        icon.image = img
        let w = bounds.width
        icon.frame = NSRect(x: 8, y: 9, width: 16, height: 16)
        detail.frame = NSRect(x: w - 108, y: 9, width: 100, height: 16)
        closeButton.frame = NSRect(x: w - 28, y: 7, width: 20, height: 20)
        title.frame = NSRect(x: 32, y: 8, width: w - 32 - 114, height: 18)
        title.stringValue = t.title
        title.font = .systemFont(ofSize: 13, weight: t.active ? .semibold : .regular)
        detail.stringValue = t.detail
        toolTip = "\(t.title)\n\(t.detail)"
        paint()
    }

    private func paint() {
        let c: NSColor = hovered || keyed ? NSColor.controlAccentColor.withAlphaComponent(0.3)
            : active ? NSColor.labelColor.withAlphaComponent(0.08) : .clear
        layer?.backgroundColor = c.cgColor
        // Au survol, la croix remplace le domaine.
        closeButton.isHidden = !hovered
        detail.isHidden = hovered
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        owner?.entered()
    }
    override func mouseExited(with event: NSEvent) { hovered = false }
    @objc private func closeTapped() { owner?.closeTab(tabIndex) }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        hovered = false
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) && !closeButton.frame.contains(p) { owner?.pick(tabIndex) }
    }
}
