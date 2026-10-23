import AppKit
import Combine
import CoreImage
import QuartzCore

/// The dock itself, drawn with Core Animation layers that are positioned by hand on every display refresh,
/// the way the native Dock works. Nothing is diffed or laid out per frame, and the display link stops as soon
/// as everything has settled, so an idle dock costs nothing.
@MainActor
final class DockStrip: NSView {
    enum Item: Equatable {
        case app(DockApp)
        case separator(Int)
        case downloads
        case minimized(MinimizedWindow)
        case trash(full: Bool)

        var id: String {
            switch self {
            case .app(let app): app.id
            case .separator(let n): "separator-\(n)"
            case .downloads: "downloads"
            case .minimized(let window): "min-\(window.id)"
            case .trash: "trash"
            }
        }
        var isSeparator: Bool { if case .separator = self { true } else { false } }
        var app: DockApp? { if case .app(let app) = self { app } else { nil } }
        var displayName: String {
            switch self {
            case .app(let app): app.name
            case .downloads: "Downloads"
            case .minimized(let window): window.title
            case .trash: "Bin"
            case .separator: ""
            }
        }
    }

    /// Called when the icon under the cursor changes (drives previews).
    var onHoverChange: ((Item?) -> Void)?
    /// Called when a non-app item is clicked (Downloads stack, minimised window).
    var onActivate: ((Item) -> Void)?
    /// Builds the right-click menu for an item.
    var menuProvider: ((Item) -> NSMenu?)?
    /// Freezes the magnification while previews are open so the cards don't slide away.
    var holdsShape = false
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private let model: DockModel
    private let extras: DockExtras
    private let glass = NSGlassEffectView()
    private let iconHost = NSView()
    private let nameTag = NameTagView()
    private var items: [Item] = []
    private var layers: [String: IconLayer] = [:]
    private var cancellables: Set<AnyCancellable> = []

    // Proportions of the macOS 26 Dock, relative to the tile size.
    private var base: CGFloat { model.tileSize }
    private var peak: CGFloat { model.magnifies ? model.largeSize / model.tileSize : 1 }
    private var spacing: CGFloat { (base * 0.12).rounded() }
    private var sidePadding: CGFloat { (base * 0.26).rounded() }
    private var verticalPadding: CGFloat { (base * 0.2).rounded() }
    private var separatorWidth: CGFloat { (base * 0.4).rounded() }
    let bottomInset: CGFloat = 4
    var barHeight: CGFloat { base + verticalPadding * 2 }

    // Animation state
    private var cursorX: CGFloat?
    private var scales: [CGFloat] = []
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var enteredAt: CFTimeInterval?
    /// Leaving the dock: magnification relaxes along a timed ease-out from these scales.
    private var relaxFrom: [CGFloat]?
    private var relaxStart: CFTimeInterval = 0
    private static let relaxDuration: CFTimeInterval = 0.32
    private(set) var hovered: String?
    private(set) var dockFrame: CGRect = .zero
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    // Launch bounce: when each app started bouncing; a stopping app finishes its current hop.
    private var bounceStarts: [String: CFTimeInterval] = [:]
    private var bounceStops: [String: CFTimeInterval] = [:]
    private static let hopDuration: CFTimeInterval = 0.62

    // Press and drag
    private var pressedItem: Item?
    private var pressPoint: CGPoint?
    private var draggingID: String?
    private var dragPoint: CGPoint = .zero
    private var shownX: [String: CGFloat] = [:]
    private var reorderSettleUntil: CFTimeInterval = 0

    init(model: DockModel, extras: DockExtras) {
        self.model = model
        self.extras = extras
        super.init(frame: .zero)
        wantsLayer = true
        glass.style = .regular
        addSubview(glass)
        iconHost.wantsLayer = true
        iconHost.layerUsesCoreImageFilters = true
        addSubview(iconHost)
        addSubview(nameTag)
        registerForDraggedTypes([.fileURL])

        Publishers.CombineLatest4(model.$pinned, model.$others, model.$trashFull, extras.$minimized)
            .receive(on: RunLoop.main)
            .sink { [weak self] pinned, others, full, minimized in
                MainActor.assumeIsolated { self?.setItems(pinned: pinned, others: others, trashFull: full, minimized: minimized) }
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
        layers.values.forEach { $0.contentsScaleChanged(scale) }
        render()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layers.values.forEach { $0.setDark(dark) }
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    // MARK: Items

    private func setItems(pinned: [DockApp], others: [DockApp], trashFull: Bool, minimized: [MinimizedWindow]) {
        var new = pinned.map(Item.app)
        if !others.isEmpty {
            new.append(.separator(0))
            new += others.map(Item.app)
        }
        new.append(.separator(1))
        new.append(.downloads)
        new += minimized.map(Item.minimized)
        new.append(.trash(full: trashFull))

        let ids = Set(new.map(\.id))
        for (id, layer) in layers where !ids.contains(id) {
            layer.removeFromSuperlayer()
            layers[id] = nil
            bounceStarts[id] = nil
        }
        for item in new {
            let layer = layers[item.id] ?? {
                let layer = IconLayer()
                layer.tileSize = base
                layer.largeTile = base * peak
                layer.contentsScaleChanged(scale)
                layer.setDark(isDark)
                iconHost.layer?.addSublayer(layer)
                layers[item.id] = layer
                return layer
            }()
            layer.configure(item)
            if let app = item.app {
                if app.launching, bounceStarts[app.id] == nil { bounceStarts[app.id] = CACurrentMediaTime() }
            }
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
        let band = CGRect(x: dockFrame.minX - 8, y: 0, width: dockFrame.width + 16,
                          height: bottomInset + barHeight + base * (peak - 1) + 6)
        if band.contains(local) || draggingID != nil {
            if cursorX == nil { enteredAt = CACurrentMediaTime() }
            cursorX = local.x
            relaxFrom = nil
        } else if !holdsShape {
            beginRelax()
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
        guard cursorX != nil, let enteredAt, draggingID == nil, bounceStarts.isEmpty else { return false }
        return CACurrentMediaTime() - enteredAt > 0.12
    }

    func cursorLeft() {
        guard !holdsShape else { return }
        beginRelax()
        startAnimating()
    }

    private func beginRelax() {
        guard cursorX != nil else { return }
        cursorX = nil
        enteredAt = nil
        relaxFrom = scales
        relaxStart = CACurrentMediaTime()
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

        var settled = true
        if let from = relaxFrom, from.count == scales.count {
            // A smooth ease-out back to rest, the same length however magnified the dock was.
            let p = min(1, (link.targetTimestamp - relaxStart) / Self.relaxDuration)
            let eased = CGFloat(1 - pow(1 - p, 3))
            for i in scales.indices { scales[i] = from[i] + (1 - from[i]) * eased }
            if p < 1 { settled = false } else { relaxFrom = nil }
        } else {
            let target = targetScales()
            let k = isTracking ? 1 : CGFloat(1 - exp(-30 * dt))
            for i in scales.indices {
                let next = scales[i] + (target[i] - scales[i]) * k
                if abs(next - target[i]) > 0.002 { settled = false }
                scales[i] = abs(next - target[i]) > 0.002 ? next : target[i]
            }
        }
        let positionsSettled = render(time: link.targetTimestamp, dt: dt)

        if settled && positionsSettled && bounceStarts.isEmpty && draggingID == nil {
            link.invalidate()
            displayLink = nil
        }
    }

    // MARK: Layout

    private func restWidth(_ item: Item) -> CGFloat { item.isSeparator ? separatorWidth : base }

    /// The native magnification shape: a raised cosine about three icons wide, flat near its peak.
    private func magnification(around u: CGFloat?, restCenters: [CGFloat]) -> [CGFloat] {
        let reach = base * 3
        return items.indices.map { i in
            guard peak > 1, let u, !items[i].isSeparator else { return 1 }
            let d = abs(restCenters[i] - u)
            guard d < reach else { return 1 }
            return 1 + (peak - 1) * (1 + cos(.pi * d / reach)) / 2
        }
    }

    private func restLayout() -> (centers: [CGFloat], starts: [CGFloat], width: CGFloat) {
        var x = sidePadding
        var centers: [CGFloat] = []
        var starts: [CGFloat] = []
        for item in items {
            let w = restWidth(item)
            starts.append(x)
            centers.append(x + w / 2)
            x += w + spacing
        }
        return (centers, starts, x - spacing + sidePadding)
    }

    private func positions(for scales: [CGFloat], order: [Int]) -> (centers: [Int: CGFloat], width: CGFloat) {
        var centers: [Int: CGFloat] = [:]
        var x = sidePadding
        for i in order {
            let w = items[i].id == gapMarker ? base : restWidth(items[i]) * scales[i]
            centers[i] = x + w / 2
            x += w + spacing
        }
        return (centers, x - spacing + sidePadding)
    }

    private let gapMarker = "__gap__"

    /// Solves for the resting point that lands under the cursor once the dock has grown and re-centred.
    private func targetScales() -> [CGFloat] {
        guard let cursorX, !items.isEmpty else { return items.map { _ in 1 } }
        let rest = restLayout()
        var u = cursorX - (bounds.width - rest.width) / 2
        var result = magnification(around: u, restCenters: rest.centers)
        let order = Array(items.indices)
        for _ in 0..<4 {
            let (centers, width) = positions(for: result, order: order)
            let left = (bounds.width - width) / 2
            let k = rest.starts.lastIndex { $0 <= u } ?? 0
            let scaledStart = centers[k, default: 0] - restWidth(items[k]) * result[k] / 2
            let landed = left + scaledStart + (u - rest.starts[k]) * result[k]
            u += (cursorX - landed) / max(result[k], 1)
            result = magnification(around: u, restCenters: rest.centers)
        }
        return result
    }

    /// Order of items while one is being dragged: the dragged icon leaves a gap where it would land.
    private func dragOrder(left: CGFloat) -> (order: [Int], gapIndex: Int?) {
        guard let draggingID, let dragged = items.firstIndex(where: { $0.id == draggingID }),
              items[dragged].app?.pinned == true
        else { return (Array(items.indices), nil) }
        let pinnedIndices = items.indices.filter { items[$0].app?.pinned == true && $0 != dragged }
        let rest = restLayout()
        // Where the drag would insert among the pinned apps, from resting positions.
        let x = dragPoint.x - left
        var insertAt = pinnedIndices.count
        for (n, i) in pinnedIndices.enumerated() where x < rest.centers[i] {
            insertAt = n
            break
        }
        let offDock = dragPoint.y > dockFrame.maxY + 90
        var order = items.indices.filter { $0 != dragged }
        if !offDock {
            let anchor = insertAt < pinnedIndices.count ? order.firstIndex(of: pinnedIndices[insertAt])! : (order.firstIndex(of: pinnedIndices.last ?? 0).map { $0 + 1 } ?? 0)
            order.insert(dragged, at: anchor)
        }
        return (order, offDock ? nil : dragged)
    }

    /// Returns true when every icon has reached its target position (always, except while reordering).
    @discardableResult
    private func render(time: CFTimeInterval = CACurrentMediaTime(), dt: Double = 1.0 / 120) -> Bool {
        guard !items.isEmpty, scales.count == items.count else { return true }
        let snapScale = scale
        func snap(_ v: CGFloat) -> CGFloat { (v * snapScale).rounded() / snapScale }

        let provisional = positions(for: scales, order: Array(items.indices))
        let provisionalLeft = (bounds.width - provisional.width) / 2
        let (order, gap) = dragOrder(left: provisionalLeft)
        let (centers, width) = positions(for: scales, order: order)
        let left = snap((bounds.width - width) / 2)
        dockFrame = CGRect(x: left, y: bottomInset, width: snap(width), height: barHeight)

        let reordering = draggingID != nil || time < reorderSettleUntil
        let k = CGFloat(1 - exp(-22 * dt))
        var settled = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if glass.frame != dockFrame { glass.frame = dockFrame }
        let radius = (barHeight * 0.42).rounded()
        if glass.cornerRadius != radius { glass.cornerRadius = radius }
        let iconBottom = bottomInset + verticalPadding
        for (i, item) in items.enumerated() {
            guard let layer = layers[item.id] else { continue }
            let size = item.isSeparator ? base : base * scales[i]
            var centerX = left + (centers[i] ?? 0)
            // Icons glide into their new places while reordering instead of jumping.
            if reordering, i != gap, let shown = shownX[item.id] {
                let next = shown + (centerX - shown) * k
                if abs(next - centerX) > 0.3 { settled = false; centerX = next }
            }
            shownX[item.id] = centerX
            var y = iconBottom
            if i == gap {
                centerX = dragPoint.x
                y = max(iconBottom, dragPoint.y - size / 2)
            }
            if let start = bounceStarts[item.id] {
                y += bounceOffset(id: item.id, start: start, time: time, height: base * 0.6)
            }
            let w = item.isSeparator ? separatorWidth : size
            layer.frame = CGRect(x: snap(centerX - w / 2), y: snap(y), width: snap(w), height: snap(size))
            layer.zPosition = i == gap ? 10 : 0
            layer.layoutContents(dotRoom: verticalPadding, pixels: size * snapScale, separatorHeight: base * 0.74)
        }
        // While dragged off the dock, the icon floats free with a "Remove" tag.
        if let draggingID, gap == nil, let layer = layers[draggingID] {
            layer.frame = CGRect(x: snap(dragPoint.x - base / 2), y: snap(dragPoint.y - base / 2), width: base, height: base)
            layer.zPosition = 10
            layer.layoutContents(dotRoom: verticalPadding, pixels: base * snapScale, separatorHeight: base * 0.74)
        }
        updateHover(centers: centers, left: left)
        CATransaction.commit()
        return settled
    }

    /// Parabolic hops like the native launch bounce; once the app has launched, the hop in progress finishes
    /// and the icon lands (with Reduce Motion, a single hop).
    private func bounceOffset(id: String, start: CFTimeInterval, time: CFTimeInterval, height: CGFloat) -> CGFloat {
        let hop = Self.hopDuration
        let elapsed = time - start
        let launching = items.first { $0.id == id }?.app?.launching == true
        if !launching || (reduceMotion && elapsed >= hop) {
            let stop = bounceStops[id] ?? ((elapsed / hop).rounded(.down) + 1) * hop
            bounceStops[id] = stop
            if elapsed >= stop {
                bounceStarts[id] = nil
                bounceStops[id] = nil
                return 0
            }
        }
        let p = elapsed.truncatingRemainder(dividingBy: hop) / hop
        return height * CGFloat(4 * p * (1 - p))
    }

    private func updateHover(centers: [Int: CGFloat], left: CGFloat) {
        var id: String?
        if let cursorX, draggingID == nil {
            let nearest = items.indices.filter { !items[$0].isSeparator }
                .min { abs(left + (centers[$0] ?? 0) - cursorX) < abs(left + (centers[$1] ?? 0) - cursorX) }
            id = nearest.map { items[$0].id }
        }
        if id != hovered {
            hovered = id
            onHoverChange?(id.flatMap { id in items.first { $0.id == id } })
        }
        if let draggingID, let layer = layers[draggingID], dragPoint.y > dockFrame.maxY + 90 {
            nameTag.show("Remove", above: layer.frame, in: bounds)
        } else if let id, !holdsShape, let layer = layers[id], let item = items.first(where: { $0.id == id }) {
            nameTag.show(item.displayName, above: layer.frame, in: bounds)
        } else {
            nameTag.hide()
        }
    }

    func iconFrameOnScreen(_ id: String) -> CGRect? {
        guard let layer = layers[id], let window else { return nil }
        return window.convertToScreen(convert(layer.frame, to: nil))
    }

    // MARK: Mouse

    private func item(at point: CGPoint) -> Item? {
        items.first { item in
            guard !item.isSeparator, let layer = layers[item.id] else { return false }
            return layer.frame.insetBy(dx: -spacing / 2, dy: -verticalPadding).contains(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedItem = item(at: point)
        pressPoint = point
        if let pressed = pressedItem { layers[pressed.id]?.setPressed(true) }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pressed = pressedItem, let app = pressed.app, app.pinned, let start = pressPoint else { return }
        if draggingID == nil, hypot(point.x - start.x, point.y - start.y) > 5 {
            draggingID = app.id
            layers[app.id]?.setPressed(false)
            onHoverChange?(nil)
        }
        if draggingID != nil {
            dragPoint = point
            startAnimating()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let pressed = pressedItem { layers[pressed.id]?.setPressed(false) }
        defer {
            pressedItem = nil
            pressPoint = nil
            startAnimating()
        }
        if let id = draggingID, let app = items.first(where: { $0.id == id })?.app {
            draggingID = nil
            reorderSettleUntil = CACurrentMediaTime() + 0.35
            if point.y > dockFrame.maxY + 90 {
                // Dragged off the dock: the native "poof".
                if let layer = layers[id] { Poof.play(at: CGPoint(x: layer.frame.midX, y: layer.frame.midY), image: layer.currentImage, in: iconHost.layer, reduceMotion: reduceMotion) }
                layers[id]?.isHidden = true
                model.setPinned(app, false)
            } else {
                let rest = restLayout()
                let left = (bounds.width - rest.width) / 2
                let pinned = items.indices.filter { items[$0].app?.pinned == true && items[$0].id != id }
                let target = pinned.first { left + rest.centers[$0] > point.x }.flatMap { items[$0].app }
                model.move(app, before: target)
            }
            return
        }
        guard let pressed = pressedItem, item(at: point)?.id == pressed.id else { return }
        switch pressed {
        case .app(let app): model.open(app)
        case .trash: model.openTrash()
        case .downloads, .minimized: onActivate?(pressed)
        case .separator: break
        }
        onHoverChange?(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item = item(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menuProvider?(item)
    }

    // MARK: File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        cursorX = point.x
        if enteredAt == nil { enteredAt = CACurrentMediaTime() }
        startAnimating()
        switch item(at: point) {
        case .trash: return .move
        case .app, .downloads: return .generic
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
        case .downloads:
            for url in urls {
                try? FileManager.default.moveItem(at: url, to: DockExtras.downloadsFolder.appendingPathComponent(url.lastPathComponent))
            }
        default: return false
        }
        return true
    }
}

// MARK: - Icon layer

/// Rasterises an icon at exactly the pixel size it's shown at (in a few sizes), so it stays as crisp as the
/// native Dock's at rest and while magnified.
enum IconRaster {
    private static var cache: [String: CGImage] = [:]

    static func image(_ source: NSImage, key: String, pixels: CGFloat) -> CGImage? {
        // A handful of sizes: exact at rest, then steps while magnifying.
        let step = max(16, pixels.rounded(.up))
        let cacheKey = "\(key)@\(Int(step))"
        if let cached = cache[cacheKey] { return cached }
        let size = Int(step)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Asking NSImage for an exact pixel rect makes it pick the icon's own best artwork for that size.
        source.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1,
                    respectFlipped: false, hints: [.ctm: NSAffineTransform()])
        NSGraphicsContext.restoreGraphicsState()
        let image = rep.cgImage
        if cache.count > 600 { cache.removeAll() }
        cache[cacheKey] = image
        return image
    }
}

private final class IconLayer: CALayer {
    private let image = CALayer()
    private let dot = CALayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private let line = CALayer()
    private let miniBadge = CALayer()
    private var isSeparator = false
    private var hasBadge = false
    private var source: NSImage?
    private var sourceKey = ""
    private var lastPixels: CGFloat = 0
    private var restImage: CGImage?
    private var largeImage: CGImage?
    private var restPixels: CGFloat = 1
    private var usingLarge = false
    private var contentsScaleValue: CGFloat = 2
    var tileSize: CGFloat = 37
    var largeTile: CGFloat = 73
    private var pressed = false
    private(set) var currentImage: CGImage?

    override init() {
        super.init()
        image.contentsGravity = .resizeAspect
        image.minificationFilter = .trilinear
        addSublayer(image)
        dot.cornerRadius = 2
        addSublayer(dot)
        badge.backgroundColor = NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1).cgColor
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.3
        badge.shadowRadius = 1.5
        badge.shadowOffset = CGSize(width: 0, height: -0.5)
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor.white.cgColor
        badge.addSublayer(badgeText)
        addSublayer(badge)
        addSublayer(line)
        miniBadge.contentsGravity = .resizeAspect
        addSublayer(miniBadge)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func contentsScaleChanged(_ scale: CGFloat) {
        [self, image, dot, badge, badgeText, line, miniBadge].forEach { $0.contentsScale = scale }
        contentsScaleValue = scale
        prepareRasters()
    }

    /// Running dots and separators follow light/dark appearance like the native Dock.
    func setDark(_ dark: Bool) {
        dot.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.72) : NSColor(white: 0, alpha: 0.55)).cgColor
        line.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.28) : NSColor(white: 0, alpha: 0.2)).cgColor
    }

    /// The press highlight: the icon darkens while the mouse is down, like the native Dock.
    func setPressed(_ on: Bool) {
        guard on != pressed else { return }
        pressed = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if on, let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(-0.28, forKey: kCIInputBrightnessKey)
            image.filters = [filter]
        } else {
            image.filters = nil
        }
        CATransaction.commit()
    }

    func configure(_ item: DockStrip.Item) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isSeparator = item.isSeparator
        line.isHidden = !isSeparator
        image.isHidden = isSeparator
        miniBadge.isHidden = true
        hasBadge = false
        dot.isHidden = true
        switch item {
        case .app(let app):
            setSource(app.icon, key: app.id)
            dot.isHidden = !app.running
            hasBadge = app.badge != nil
            badgeText.string = app.badge
        case .trash(let full):
            if let art = TrashArt.image(full: full) { setSource(art, key: full ? "trash-full" : "trash") }
        case .downloads:
            setSource(NSWorkspace.shared.icon(forFile: DockExtras.downloadsFolder.path), key: "downloads")
        case .minimized(let window):
            if let thumb = window.thumbnail {
                setSource(thumb, key: "min-\(window.id)-thumb")
            } else {
                setSource(window.appIcon, key: "min-\(window.id)-icon")
            }
            miniBadge.contents = window.appIcon.cgImage(forProposedRect: nil, context: nil, hints: nil)
            miniBadge.isHidden = false
        case .separator:
            break
        }
        badge.isHidden = !hasBadge
        CATransaction.commit()
    }

    private func setSource(_ newSource: NSImage, key: String) {
        guard key != sourceKey || source !== newSource else { return }
        source = newSource
        sourceKey = key
        prepareRasters()
    }

    private func prepareRasters() {
        guard let source else { return }
        restPixels = tileSize * contentsScaleValue
        restImage = IconRaster.image(source, key: sourceKey, pixels: restPixels)
        largeImage = IconRaster.image(source, key: sourceKey, pixels: largeTile * contentsScaleValue)
        image.contents = nil
    }

    /// Positions children for the current size (called inside the frame loop's transaction).
    func layoutContents(dotRoom: CGFloat, pixels: CGFloat, separatorHeight: CGFloat) {
        let size = bounds.size
        if isSeparator {
            line.frame = CGRect(x: (size.width / 2).rounded() - 0.5, y: (size.height - separatorHeight) / 2, width: 1, height: separatorHeight)
            return
        }
        // Two rasters prepared ahead of time (exact at rest, exact when fully magnified); the frame loop only
        // picks one, never draws.
        let wantLarge = pixels > restPixels * 1.2
        if source != nil, wantLarge != usingLarge || image.contents == nil {
            usingLarge = wantLarge
            currentImage = wantLarge ? largeImage : restImage
            image.contents = currentImage
        }
        image.frame = bounds
        // The running dot sits centred in the bar's bottom padding.
        dot.frame = CGRect(x: (size.width / 2 - 2).rounded(), y: -(dotRoom / 2) - 2, width: 4, height: 4)
        if !miniBadge.isHidden {
            let d = size.width * 0.38
            miniBadge.frame = CGRect(x: size.width - d * 0.85, y: -d * 0.1, width: d, height: d)
        }
        if hasBadge {
            // A red capsule that widens to fit the count, centred on the top-right corner.
            let fontSize = max(9, (size.width * 0.24).rounded())
            if badgeText.fontSize != fontSize {
                badgeText.fontSize = fontSize
                badgeText.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            }
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let label = (badgeText.string as? String) ?? ""
            let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
            let height = (fontSize * 1.55).rounded()
            let width = max(height, textWidth + fontSize * 0.9)
            badge.frame = CGRect(x: size.width - width * 0.62, y: size.height - height * 0.72, width: width, height: height)
            badge.cornerRadius = height / 2
            let lineHeight = ceil(font.ascender - font.descender)
            badgeText.frame = CGRect(x: 0, y: (height - lineHeight) / 2 - font.descender * 0.15, width: width, height: lineHeight)
        }
    }
}

// MARK: - Name tag

/// The label above a hovered icon: a glass capsule in the system font, like the macOS 26 Dock.
private final class NameTagView: NSGlassEffectView {
    private let label = NSTextField(labelWithString: "")
    private var current: String?

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        let content = NSView()
        content.addSubview(label)
        contentView = content
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ name: String, above icon: CGRect, in bounds: CGRect) {
        if name != current {
            current = name
            label.stringValue = name
        }
        let width = ceil(label.intrinsicContentSize.width) + 24
        let height: CGFloat = 26
        let x = min(max(icon.midX - width / 2, 6), bounds.width - width - 6)
        let target = CGRect(x: x.rounded(), y: (icon.maxY + 10).rounded(), width: width, height: height)
        if frame != target { frame = target }
        cornerRadius = height / 2
        label.frame = CGRect(x: 0, y: (height - 17) / 2, width: width, height: 17)
        isHidden = false
    }

    func hide() {
        guard !isHidden else { return }
        current = nil
        isHidden = true
    }
}

// MARK: - Poof

enum Poof {
    /// The removal puff: the icon swells and vanishes in a small cloud.
    static func play(at point: CGPoint, image: CGImage?, in parent: CALayer?, reduceMotion: Bool) {
        guard let parent else { return }
        let ghost = CALayer()
        ghost.contents = image
        ghost.contentsGravity = .resizeAspect
        ghost.bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
        ghost.position = point
        ghost.zPosition = 30
        parent.addSublayer(ghost)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.toValue = reduceMotion ? 1 : 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.28
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ghost.add(group, forKey: "poof")
        CATransaction.commit()

        guard !reduceMotion else { return }
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = point
        emitter.emitterShape = .circle
        emitter.emitterSize = CGSize(width: 24, height: 24)
        emitter.zPosition = 31
        let cell = CAEmitterCell()
        cell.contents = puffImage
        cell.birthRate = 160
        cell.lifetime = 0.45
        cell.velocity = 70
        cell.velocityRange = 40
        cell.emissionRange = .pi * 2
        cell.scale = 0.35
        cell.scaleRange = 0.2
        cell.scaleSpeed = 0.6
        cell.alphaSpeed = -2.2
        emitter.emitterCells = [cell]
        parent.addSublayer(emitter)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { emitter.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { emitter.removeFromSuperlayer() }
    }

    private static let puffImage: CGImage? = {
        let size = 32
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [CGColor(gray: 1, alpha: 0.9), CGColor(gray: 1, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors, locations: [0, 1]) else { return nil }
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 16, y: 16), startRadius: 0,
                               endCenter: CGPoint(x: 16, y: 16), endRadius: 16, options: [])
        return ctx.makeImage()
    }()
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

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, state: NSControl.StateValue = .off, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.state = state
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
