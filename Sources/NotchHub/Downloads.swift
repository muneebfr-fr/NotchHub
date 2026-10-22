import AppKit
import OSLog
import SwiftUI

private let log = Logger(subsystem: "local.notchhub", category: "downloads")

/// Keeps ~/Downloads tidy: sorts new files into type folders, moves files untouched for 30 days into
/// Downloads/Old, and surfaces leftover installers. Nothing is ever deleted.
@MainActor
final class DownloadsTidier: ObservableObject {
    @Published private(set) var leftovers: [URL] = []
    @Published private(set) var leftoverBytes: Int64 = 0

    var hasLeftovers: Bool { !leftovers.isEmpty }

    nonisolated static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

    private let worker = DownloadsWorker()
    private var source: DispatchSourceFileSystemObject?
    private var pendingWork: DispatchWorkItem?
    private var timer: Timer?
    private var dismissed: Set<URL> = []

    init() {
        watch()
        schedule(after: 2)
        // Ageing and leftover checks don't need to be immediate.
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: 0) }
        }
    }

    private func watch() {
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule(after: 3) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func schedule(after seconds: Double) {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runPass() }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func runPass() {
        worker.pass { [weak self] result in
            guard let self else { return }
            let visible = result.leftovers.filter { !self.dismissed.contains($0) }
            if visible != self.leftovers {
                withAnimation(.spring(duration: 0.45, bounce: 0.15)) {
                    self.leftovers = visible
                    self.leftoverBytes = result.leftoverBytes
                }
            }
            // Something was still downloading or too fresh; look again shortly.
            if result.retrySoon { self.schedule(after: 10) }
        }
    }

    // MARK: Actions

    func showLeftovers() {
        NSWorkspace.shared.activateFileViewerSelecting(leftovers)
    }

    func moveLeftoversToOld() {
        let urls = leftovers
        withAnimation(.spring(duration: 0.4, bounce: 0)) { leftovers = [] }
        worker.moveToOld(urls) { [weak self] in self?.schedule(after: 0.5) }
    }

    func dismissLeftovers() {
        dismissed.formUnion(leftovers)
        withAnimation(.spring(duration: 0.4, bounce: 0)) { leftovers = [] }
    }
}

/// All file-system work, on its own queue so the notch never waits on the disk.
private final class DownloadsWorker: @unchecked Sendable {
    struct Result: Sendable {
        var leftovers: [URL] = []
        var leftoverBytes: Int64 = 0
        var retrySoon = false
    }

    private let queue = DispatchQueue(label: "local.notchhub.downloads", qos: .utility)
    private let fm = FileManager.default
    private var root: URL { DownloadsTidier.folder }

    private static let categories: [(name: String, extensions: Set<String>)] = [
        ("Images", ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2", "nef", "arw", "psd", "ai"]),
        ("Videos", ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv"]),
        ("Audio", ["mp3", "m4a", "wav", "aac", "flac", "aif", "aiff", "ogg"]),
        ("Documents", ["pdf", "doc", "docx", "txt", "rtf", "pages", "key", "numbers", "xls", "xlsx", "csv", "ppt", "pptx", "md", "odt", "ods", "odp", "epub"]),
        ("Installers", ["dmg", "pkg", "mpkg"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
    ]
    private static let sortedFolders = Set(categories.map(\.name) + ["Other", "Old"])
    /// Partial downloads from Chrome, Firefox, Safari and others.
    private static let inProgress: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload", "filepart"]

    private static let settleTime: TimeInterval = 10
    private static let oldAfter: TimeInterval = 30 * 24 * 60 * 60
    private static let leftoverAfter: TimeInterval = 24 * 60 * 60

    func pass(completion: @escaping @MainActor (Result) -> Void) {
        queue.async {
            var result = Result()
            result.retrySoon = self.sortNewFiles()
            self.ageOldFiles()
            (result.leftovers, result.leftoverBytes) = self.findLeftovers()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    func moveToOld(_ urls: [URL], completion: @escaping @MainActor () -> Void) {
        queue.async {
            let destination = self.root.appendingPathComponent("Old/Installers", isDirectory: true)
            for url in urls { self.move(url, into: destination) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    /// Returns true if some file wasn't ready yet.
    private func sortNewFiles() -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return false
        }
        var notReady = false
        var moved = 0
        for url in items {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true, values.isPackage != true
            else { continue }
            let ext = url.pathExtension.lowercased()
            if Self.inProgress.contains(ext) {
                notReady = true
                continue
            }
            if let modified = values.contentModificationDate, Date().timeIntervalSince(modified) < Self.settleTime {
                notReady = true
                continue
            }
            let category = Self.categories.first { $0.extensions.contains(ext) }?.name ?? "Other"
            if move(url, into: root.appendingPathComponent(category, isDirectory: true)) { moved += 1 }
        }
        if moved > 0 { log.info("Sorted \(moved, privacy: .public) download(s)") }
        return notReady
    }

    /// Untouched means neither opened nor (re)added for 30 days; sorting a file counts as adding it.
    private func ageOldFiles() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentAccessDateKey, .isDirectoryKey]
        var moved = 0
        for category in Self.categories.map(\.name) + ["Other"] {
            let folder = root.appendingPathComponent(category, isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                continue
            }
            for url in items {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let lastTouched = [values.addedToDirectoryDate, values.contentAccessDate].compactMap { $0 }.max() ?? Date()
                guard Date().timeIntervalSince(lastTouched) > Self.oldAfter else { continue }
                if move(url, into: root.appendingPathComponent("Old/\(category)", isDirectory: true)) { moved += 1 }
            }
        }
        if moved > 0 { log.info("Moved \(moved, privacy: .public) old download(s) to Old") }
    }

    private func findLeftovers() -> ([URL], Int64) {
        let folder = root.appendingPathComponent("Installers", isDirectory: true)
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return ([], 0)
        }
        var urls: [URL] = []
        var bytes: Int64 = 0
        for url in items {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let added = values.addedToDirectoryDate,
                  Date().timeIntervalSince(added) > Self.leftoverAfter
            else { continue }
            urls.append(url)
            bytes += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return (urls.sorted { $0.lastPathComponent < $1.lastPathComponent }, bytes)
    }

    /// Moves without ever overwriting: a clash gets " 2", " 3", … like Finder does.
    @discardableResult
    private func move(_ url: URL, into folder: URL) -> Bool {
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var destination = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            try fm.moveItem(at: url, to: destination)
            return true
        } catch {
            log.error("Couldn't move a download: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

// MARK: - View

struct LeftoversStrip: View {
    @EnvironmentObject var downloads: DownloadsTidier

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app"))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(downloads.leftovers.count) leftover installer\(downloads.leftovers.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .semibold))
                Text(ByteCountFormatter.string(fromByteCount: downloads.leftoverBytes, countStyle: .file) + " in Downloads/Installers")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            pill("Show", "magnifyingglass") { downloads.showLeftovers() }
            pill("Move to Old", "archivebox") { downloads.moveLeftoversToOld() }
            Button { downloads.dismissLeftovers() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.1), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
