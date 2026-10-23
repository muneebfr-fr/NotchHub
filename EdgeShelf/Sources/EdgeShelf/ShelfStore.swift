import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case file, link, text, image }

    var id = UUID()
    var kind: Kind
    /// Files are referenced, never copied: a path plus a bookmark that follows the file if it's moved.
    var path: String?
    var bookmark: Data?
    var url: String?
    var title: String?
    var text: String?
    /// Images pasted or dragged from apps (not files) are saved into the shelf's own folder.
    var imageFile: String?
    var added = Date()
}

@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    private var thumbnails: [UUID: NSImage] = [:]

    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EdgeShelf", isDirectory: true)
    private static let indexURL = folder.appendingPathComponent("items.json")
    private static let imagesFolder = folder.appendingPathComponent("Images", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: Self.imagesFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = saved.map(Self.refreshed)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.indexURL, options: .atomic) }
    }

    /// Follows bookmarks so moved or renamed files keep working.
    private static func refreshed(_ item: ShelfItem) -> ShelfItem {
        guard item.kind == .file, let bookmark = item.bookmark else { return item }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale) else { return item }
        var updated = item
        updated.path = url.path
        if stale { updated.bookmark = try? url.bookmarkData() }
        return updated
    }

    // MARK: Adding

    /// Accepts whatever a drag or paste carries: files, web links, images or text.
    @discardableResult
    func add(from pasteboard: NSPasteboard) -> Bool {
        var new: [ShelfItem] = []

        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            for file in files {
                new.append(ShelfItem(kind: .file, path: file.path, bookmark: try? file.bookmarkData(), title: file.lastPathComponent))
            }
        } else if let link = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, link.scheme?.hasPrefix("http") == true {
            let title = pasteboard.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            new.append(ShelfItem(kind: .link, url: link.absoluteString, title: title?.isEmpty == false ? title : link.host()))
        } else if let image = NSImage(pasteboard: pasteboard), pasteboard.string(forType: .string) == nil,
                  let png = image.pngData() {
            let name = "\(UUID().uuidString).png"
            try? png.write(to: Self.imagesFolder.appendingPathComponent(name))
            new.append(ShelfItem(kind: .image, title: "Image", imageFile: name))
        } else if let string = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            if let url = URL(string: string), url.scheme?.hasPrefix("http") == true, !string.contains(" ") {
                new.append(ShelfItem(kind: .link, url: url.absoluteString, title: url.host()))
            } else {
                new.append(ShelfItem(kind: .text, title: String(string.prefix(80)), text: string))
            }
        }

        guard !new.isEmpty else { return false }
        // Re-dropping the same file or link moves it to the top instead of duplicating it.
        let keys = Set(new.map(Self.dedupeKey))
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            items.removeAll { keys.contains(Self.dedupeKey($0)) }
            items.insert(contentsOf: new, at: 0)
        }
        save()
        return true
    }

    private static func dedupeKey(_ item: ShelfItem) -> String {
        switch item.kind {
        case .file: "file:" + (item.path ?? "")
        case .link: "link:" + (item.url ?? "")
        case .text: "text:" + (item.text ?? "")
        case .image: "image:" + item.id.uuidString
        }
    }

    // MARK: Actions

    func remove(_ item: ShelfItem) {
        withAnimation(.spring(duration: 0.35, bounce: 0)) { items.removeAll { $0.id == item.id } }
        if item.kind == .image, let name = item.imageFile {
            try? FileManager.default.removeItem(at: Self.imagesFolder.appendingPathComponent(name))
        }
        thumbnails[item.id] = nil
        save()
    }

    func clear() {
        for item in items where item.kind == .image { remove(item) }
        withAnimation(.spring(duration: 0.35, bounce: 0)) { items.removeAll() }
        thumbnails.removeAll()
        save()
    }

    func fileURL(_ item: ShelfItem) -> URL? {
        switch item.kind {
        case .file: item.path.map(URL.init(fileURLWithPath:))
        case .image: item.imageFile.map { Self.imagesFolder.appendingPathComponent($0) }
        default: nil
        }
    }

    func exists(_ item: ShelfItem) -> Bool {
        guard let url = fileURL(item) else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func open(_ item: ShelfItem) {
        switch item.kind {
        case .file, .image:
            if let url = fileURL(item) { NSWorkspace.shared.open(url) }
        case .link:
            if let url = item.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        case .text:
            copy(item)
        }
    }

    func copy(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .file, .image:
            if let url = fileURL(item) { pasteboard.writeObjects([url as NSURL]) }
        case .link:
            if let url = item.url.flatMap(URL.init(string:)) { pasteboard.writeObjects([url as NSURL]) }
        case .text:
            pasteboard.setString(item.text ?? "", forType: .string)
        }
    }

    func reveal(_ item: ShelfItem) {
        if let url = fileURL(item) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    /// What a card hands over when it's dragged out of the shelf.
    func dragProvider(_ item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file, .image:
            if let url = fileURL(item), let provider = NSItemProvider(contentsOf: url) { return provider }
        case .link:
            if let url = item.url.flatMap(URL.init(string:)) { return NSItemProvider(object: url as NSURL) }
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        }
        return NSItemProvider()
    }

    // MARK: Thumbnails

    func thumbnail(_ item: ShelfItem) -> NSImage {
        if let cached = thumbnails[item.id] { return cached }
        let image: NSImage
        switch item.kind {
        case .file:
            if let url = fileURL(item), let preview = Self.imageThumbnail(url) {
                image = preview
            } else {
                image = NSWorkspace.shared.icon(forFile: item.path ?? "")
            }
        case .image:
            image = fileURL(item).flatMap(Self.imageThumbnail) ?? NSWorkspace.shared.icon(for: .png)
        case .link:
            image = NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
        case .text:
            image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
        }
        thumbnails[item.id] = image
        return image
    }

    /// Small decoded previews for image files, so big photos never load at full size.
    private static func imageThumbnail(_ url: URL) -> NSImage? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
