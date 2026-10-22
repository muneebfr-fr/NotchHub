import AppKit
import Combine
import QuartzCore

/// The dock itself, drawn with Core Animation layers that are positioned by hand on every display refresh,
/// the way the native Dock works. Nothing is diffed or laid out per frame, and the display link stops as soon
/// as everything has settled, so an idle dock costs nothing.
@MainActor
final class DockStrip: NSView {
    enum Item: Equatable {
        case app(DockApp)
        case separator(Int)
        case trash(full: Bool)

        var id: String {
            switch self {
            case .app(let app): app.id
            case .separator(let n): "separator-\(n)"
            case .trash: "trash"
            }
        }
        var isSeparator: Bool { if case .separator = self { true } else { false } }
        var app: DockApp? { if case .app(let app) = self { app } else { nil } }
    }

    /// Called when the icon under the cursor changes (drives previews and name tags).
    var onHoverChange: ((Item?) -> Void)?
    /// Freezes the magnification while previews are open so the cards don't slide away.
    var holdsShape = false

    private let model: DockModel
    private let glass = NSGlassEffectView()
    private let iconHost = NSView()
    private var items: [Item] = []
    private var layers: [String: IconLayer] = [:]
    private let nameTag = NameTagLayer()
    private var cancellables: Set<AnyCancellable> = []

    private var base: CGFloat { model.tileSize }
    private var peak: CGFloat { model.largeSize / model.tileSize }
    private let padding: CGFloat = 5
    private let spacing: CGFloat = 3
    private let separatorWidth: CGFloat = 14
    private let bottomInset: CGFloat = 4
    var barHeight: CGFloat { base + padding * 2 + 4 }

    // Animation state
    private var cursorX: CGFloat?
    private var scales: [CGFloat] = []
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// When the cursor entered the dock; magnification eases in briefly, then tracks the cursor exactly.
    private var enteredAt: CFTimeInterval?
    private(set) var hovered: String?
    private(set) var dockFrame: CGRect = .zero

    // Dragging
    private var pressedItem: Item?
    private var pressPoint: CGPoint?
    private var draggingID: String?
    private var dragX: CGFloat = 0

    init(model: DockModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        glass.cornerRadius = 20
        addSubview(glass)
        iconHost.wantsLayer = true
        addSubview(iconHost)
        iconHost.layer?.addSublayer(nameTag)
        registerForDraggedTypes([.fileURL])

        Publishers.CombineLatest3(model.$pinned, model.$others, model.$trashFull)
            .receive(on: RunLoop.main)
            .sink { [weak self] pinned, others, full in
                MainActor.assumeIsolated { self?.setItems(pinned: pinned, others: others, trashFull: full) }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        iconHost.frame = bounds
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layers.values.forEach { $0.setScale(scale) }
        nameTag.contentsScale = scale
        nameTag.text.contentsScale = scale
    }

    // MARK: Items

    private func setItems(pinned: [DockApp], others: [DockApp], trashFull: Bool) {
        var new = pinned.map(Item.app)
        if !others.isEmpty {
            new.append(.separator(0))
            new += others.map(Item.app)
        }
        new.append(.separator(1))
        new.append(.trash(full: trashFull))

        let ids = Set(new.map(\.id))
        for (id, layer) in layers where !ids.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
        }
        let scale = window?.backingScaleFactor ?? 2
        for item in new {
            let layer = layers[item.id] ?? {
                let layer = IconLayer()
                layer.setScale(scale)
                iconHost.layer?.insertSublayer(layer, below: nameTag)
                layers[item.id] = layer
                return layer
            }()
            layer.configure(item, tile: base)
        }
        // Keep current magnification for surviving items so a launch doesn't snap the dock.
        let old = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), scales))
        items = new
        scales = new.map { old[$0.id] ?? 1 }
        startAnimating()
    }

    // MARK: Cursor input (fed by the app delegate's mouse monitors, in screen coordinates)

    func cursorMoved(toScreen point: CGPoint) {
        guard let window else { return }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let band = CGRect(x: dockFrame.minX - 8, y: 0, width: dockFrame.width + 16, height: bottomInset + barHeight + base * (peak - 1) + 6)
        if band.contains(local) || draggingID != nil {
            if cursorX == nil { enteredAt = CACurrentMediaTime() }
            cursorX = local.x
        } else if !holdsShape {
            cursorX = nil
            enteredAt = nil
        }
        // Once settled in, redraw immediately on every mouse event instead of waiting for the next frame tick.
        if isTracking {
            scales = targetScales()
            render()
        } else {
            startAnimating()
        }
    }

    private var isTracking: Bool {
        guard cursorX != nil, let enteredAt, draggingID == nil else { return false }
        return CACurrentMediaTime() - enteredAt > 0.12
    }

    func cursorLeft() {
        guard !holdsShape else { return }
        cursorX = nil
        enteredAt = nil
        startAnimating()
    }

    // MARK: Frame loop

    private func startAnimating() {
        guard displayLink == nil, let window else { render(); return }
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? 1.0 / 120 : min(1.0 / 30, link.targetTimestamp - lastTimestamp)
        lastTimestamp = link.targetTimestamp

        let target = targetScales()
        // Follows the cursor almost immediately while hovering; relaxes more gently when it leaves.
        let rate: Double = cursorX == nil ? 16 : 30
        let k = isTracking ? 1 : CGFloat(1 - exp(-rate * dt))
        var settled = true
        for i in scales.indices {
            let next = scales[i] + (target[i] - scales[i]) * k
            if abs(next - target[i]) > 0.002 { settled = false }
            scales[i] = abs(next - target[i]) > 0.002 ? next : target[i]
        }
        let bouncing = items.contains { $0.app?.launching == true }
        render(time: link.targetTimestamp)

        if settled && !bouncing && draggingID == nil {
            link.invalidate()
            displayLink = nil
        }
    }

    // MARK: Layout

    private func restWidths() -> [CGFloat] { items.map { $0.isSeparator ? separatorWidth : base } }

    private func positions(for scales: [CGFloat]) -> (centers: [CGFloat], width: CGFloat) {
        let widths = restWidths()
        var centers: [CGFloat] = []
        var x = padding
        for i in items.indices {
            let w = widths[i] * scales[i]
            centers.append(x + w / 2)
            x += w + spacing
        }
        return (centers, x - spacing + padding)
    }

    private func gaussian(around u: CGFloat?) -> [CGFloat] {
        let widths = restWidths()
        var x = padding
        let restCenters = widths.map { w -> CGFloat in defer { x += w + spacing }; return x + w / 2 }
        let sigma = base * 1.25
        return items.indices.map { i in
            guard model.magnifies, let u, !items[i].isSeparator else { return 1 }
            let d = restCenters[i] - u
            return 1 + (peak - 1) * exp(-(d * d) / (2 * sigma * sigma))
        }
    }

    /// Scales for the cursor's position: solves for the resting point that lands under the cursor once the
    /// dock has grown and re-centred, so the icon under the cursor stays under it.
    private func targetScales() -> [CGFloat] {
        guard let cursorX, !items.isEmpty else { return items.map { _ in 1 } }
        let widths = restWidths()
        var x = padding
        let restStarts = widths.map { w -> CGFloat in defer { x += w + spacing }; return x }
        let restWidth = x - spacing + padding
        var u = cursorX - (bounds.width - restWidth) / 2
        var result = gaussian(around: u)
        for _ in 0..<4 {
            let (centers, width) = positions(for: result)
            let left = (bounds.width - width) / 2
            let k = restStarts.lastIndex { $0 <= u } ?? 0
            let scaledStart = centers[k] - widths[k] * result[k] / 2
            let landed = left + scaledStart + (u - restStarts[k]) * result[k]
            u += (cursorX - landed) / max(result[k], 1)
            result = gaussian(around: u)
        }
        return result
    }

    private func render(time: CFTimeInterval = CACurrentMediaTime()) {
        guard !items.isEmpty, scales.count == items.count else { return }
        let (centers, width) = positions(for: scales)
        let left = ((bounds.width - width) / 2).rounded()
        dockFrame = CGRect(x: left, y: bottomInset, width: width, height: barHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = dockFrame
        let iconBottom = bottomInset + padding + 4
        for (i, item) in items.enumerated() {
            guard let layer = layers[item.id] else { continue }
            let size = item.isSeparator ? base : base * scales[i]
            var centerX = left + centers[i]
            if item.id == draggingID { centerX = dragX }
            var bounce: CGFloat = 0
            if item.app?.launching == true { bounce = abs(sin(time * 5.5)) * 16 }
            let width = item.isSeparator ? separatorWidth : size
            layer.frame = CGRect(x: centerX - width / 2, y: iconBottom + bounce, width: width, height: size)
            layer.zPosition = item.id == draggingID ? 10 : 0
            layer.layoutContents()
        }
        updateHover(centers: centers, left: left)
        CATransaction.commit()
    }

    private func updateHover(centers: [CGFloat], left: CGFloat) {
        var id: String?
        if let cursorX, draggingID == nil {
            let nearest = items.indices.filter { !items[$0].isSeparator }
                .min { abs(left + centers[$0] - cursorX) < abs(left + centers[$1] - cursorX) }
            id = nearest.map { items[$0].id }
        }
        if id != hovered {
            hovered = id
            onHoverChange?(id.flatMap { id in items.first { $0.id == id } })
        }
        // Name tag above the hovered icon, tracking it every frame.
        if let id, !holdsShape, let index = items.firstIndex(where: { $0.id == id }),
           let layer = layers[id], case let name = items[index].displayName, !name.isEmpty {
            nameTag.show(name, centeredAt: CGPoint(x: layer.frame.midX, y: layer.frame.maxY + 10))
        } else {
            nameTag.hide()
        }
    }

    func iconCenterOnScreen(_ id: String) -> CGPoint? {
        guard let layer = layers[id], let window else { return nil }
        return window.convertPoint(toScreen: convert(CGPoint(x: layer.frame.midX, y: layer.frame.maxY), to: nil))
    }

    // MARK: Mouse

    private func item(at point: CGPoint) -> Item? {
        items.first { item in
            guard !item.isSeparator, let layer = layers[item.id] else { return false }
            return layer.frame.insetBy(dx: -spacing / 2, dy: -4).contains(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedItem = item(at: point)
        pressPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed = pressedItem, let app = pressed.app, app.pinned, let start = pressPoint else { return }
        if draggingID == nil, hypot(point.x - start.x, point.y - start.y) > 5 { draggingID = app.id }
        if draggingID != nil {
            dragX = point.x
            layers[app.id]?.opacity = point.y > dockFrame.maxY + 90 ? 0.4 : 1
            startAnimating()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            pressedItem = nil
            pressPoint = nil
            if let id = draggingID { layers[id]?.opacity = 1 }
            draggingID = nil
            startAnimating()
        }
        if let id = draggingID, let app = items.first(where: { $0.id == id })?.app {
            if point.y > dockFrame.maxY + 90 {
                // Dragged off the dock, like the native "Remove from Dock".
                model.setPinned(app, false)
            } else {
                let pinnedItems = items.compactMap(\.app).filter(\.pinned).filter { $0.id != id }
                let target = pinnedItems.first { (layers[$0.id]?.frame.midX ?? 0) > point.x }
                model.move(app, before: target)
            }
            return
        }
        guard let pressed = pressedItem, item(at: point)?.id == pressed.id else { return }
        switch pressed {
        case .app(let app): model.open(app)
        case .trash: model.openTrash()
        case .separator: break
        }
        onHoverChange?(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item = item(at: convert(event.locationInWindow, from: nil)), let app = item.app else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, action: action)
            menu.addItem(entry)
        }
        if app.pinned {
            add("Remove from Dock") { [weak self] in self?.model.setPinned(app, false) }
        } else {
            add("Keep in Dock") { [weak self] in self?.model.setPinned(app, true) }
        }
        add("Show in Finder") { [weak self] in self?.model.showInFinder(app) }
        if app.running, !app.id.hasSuffix("Finder.app") {
            menu.addItem(.separator())
            add("Quit") { [weak self] in self?.model.quit(app) }
        }
        return menu
    }

    // MARK: File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        cursorX = point.x
        startAnimating()
        switch item(at: point) {
        case .trash: return .move
        case .app: return .generic
        default: return []
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { cursorLeft() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        switch item(at: convert(sender.draggingLocation, from: nil)) {
        case .trash: model.trash(urls)
        case .app(let app): model.open(urls, with: app)
        default: return false
        }
        return true
    }
}

private extension DockStrip.Item {
    var displayName: String {
        switch self {
        case .app(let app): app.name
        case .trash: "Bin"
        case .separator: ""
        }
    }
}

// MARK: - Layers

private final class IconLayer: CALayer {
    private let image = CALayer()
    private let dot = CALayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private let line = CALayer()
    private var isSeparator = false
    private var hasBadge = false

    override init() {
        super.init()
        image.contentsGravity = .resizeAspect
        image.minificationFilter = .trilinear
        addSublayer(image)
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        dot.cornerRadius = 2
        addSublayer(dot)
        badge.backgroundColor = NSColor.systemRed.cgColor
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor.white.cgColor
        badge.addSublayer(badgeText)
        addSublayer(badge)
        line.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        addSublayer(line)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setScale(_ scale: CGFloat) {
        [self, image, dot, badge, badgeText, line].forEach { $0.contentsScale = scale }
    }

    func configure(_ item: DockStrip.Item, tile: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch item {
        case .app(let app):
            isSeparator = false
            image.contents = app.icon.cgImage(forProposedRect: nil, context: nil, hints: nil)
            dot.isHidden = !app.running
            hasBadge = app.badge != nil
            badgeText.string = app.badge
            line.isHidden = true
        case .trash(let full):
            isSeparator = false
            image.contents = TrashArt.image(full: full)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            dot.isHidden = true
            hasBadge = false
            line.isHidden = true
        case .separator:
            isSeparator = true
            image.contents = nil
            dot.isHidden = true
            hasBadge = false
            line.isHidden = false
        }
        badge.isHidden = !hasBadge
        CATransaction.commit()
    }

    /// Positions children for the current frame size (called inside the frame loop's transaction).
    func layoutContents() {
        let size = bounds.size
        if isSeparator {
            line.frame = CGRect(x: size.width / 2 - 0.5, y: size.height * 0.1, width: 1, height: size.height * 0.8)
            return
        }
        image.frame = bounds
        dot.frame = CGRect(x: size.width / 2 - 2, y: -7, width: 4, height: 4)
        if hasBadge {
            let d = max(16, size.width * 0.38)
            badge.frame = CGRect(x: size.width - d * 0.75, y: size.height - d * 0.8, width: d, height: d)
            badge.cornerRadius = d / 2
            // Text is re-rasterised only when its whole-point size changes, not on every frame.
            let fontSize = max(10, (size.width * 0.26).rounded())
            if badgeText.fontSize != fontSize {
                badgeText.fontSize = fontSize
                badgeText.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            }
            badgeText.frame = CGRect(x: 0, y: (d - fontSize * 1.25) / 2, width: d, height: fontSize * 1.25)
        }
    }
}

private final class NameTagLayer: CALayer {
    let text = CATextLayer()
    private var current: String?

    override init() {
        super.init()
        backgroundColor = NSColor(white: 0.12, alpha: 0.82).cgColor
        borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        borderWidth = 0.5
        text.alignmentMode = .center
        text.foregroundColor = NSColor.white.cgColor
        text.fontSize = 12
        text.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        addSublayer(text)
        opacity = 0
        zPosition = 20
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ name: String, centeredAt point: CGPoint) {
        if name != current {
            current = name
            text.string = name
            let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width + 22
            bounds = CGRect(x: 0, y: 0, width: width.rounded(.up), height: 24)
            cornerRadius = 12
            text.frame = CGRect(x: 0, y: 4, width: bounds.width, height: 16)
        }
        position = CGPoint(x: point.x.rounded(), y: point.y + 12)
        opacity = 1
    }

    func hide() {
        current = nil
        opacity = 0
    }
}

enum TrashArt {
    private static var cache: [Bool: NSImage] = [:]

    static func image(full: Bool) -> NSImage? {
        if let cached = cache[full] { return cached }
        let name = full ? "FullTrashIcon.icns" : "TrashIcon.icns"
        let image = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(name)")
        cache[full] = image
        return image
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
