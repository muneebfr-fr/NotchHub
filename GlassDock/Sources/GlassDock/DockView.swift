import AppKit
import SwiftUI

@MainActor
final class StackState: ObservableObject {
    @Published var isOpen = false
    @Published var anchorX: CGFloat = 0
}

/// The overlay above the dock: window preview cards, or the Downloads stack grid. Only this part is SwiftUI:
/// it changes when something opens, not on every frame.
struct PreviewsView: View {
    @EnvironmentObject var previews: PreviewModel
    @EnvironmentObject var stack: StackState
    @EnvironmentObject var extras: DockExtras

    var body: some View {
        GeometryReader { geo in
            Group {
                if stack.isOpen {
                    StackGrid()
                        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                } else {
                    previewRow
                }
            }
            .fixedSize()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { previews.rowRect = $0 }
            .offset(x: clampedX(in: geo.size.width) - geo.size.width / 2)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: stack.isOpen)
    }

    private var previewRow: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(previews.thumbnails) { thumbnail in
                    Button { previews.focus(thumbnail) } label: {
                        VStack(spacing: 6) {
                            DropTargetThumbnail(thumbnail: thumbnail)
                            Text(thumbnail.title.isEmpty ? " " : thumbnail.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: 180)
                        }
                        .padding(8)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    /// Centred over the icon, but kept on screen at the dock's ends.
    private func clampedX(in width: CGFloat) -> CGFloat {
        let half = previews.rowRect.width / 2 + 8
        let anchor = stack.isOpen ? stack.anchorX : previews.anchorX
        return min(max(anchor, half), width - half)
    }
}

/// The Downloads stack: recent downloads in a glass grid, like the native Dock's grid view.
private struct StackGrid: View {
    @EnvironmentObject var extras: DockExtras
    @EnvironmentObject var stack: StackState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Open in Finder") {
                    NSWorkspace.shared.open(DockExtras.downloadsFolder)
                    stack.isOpen = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
            if extras.recentDownloads.isEmpty {
                Text("No downloads")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 340, height: 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: 6), count: 4), spacing: 8) {
                    ForEach(extras.recentDownloads, id: \.self) { url in
                        StackTile(url: url)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 370)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct StackTile: View {
    @EnvironmentObject var stack: StackState
    let url: URL
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 48, height: 48)
            Text(url.lastPathComponent)
                .font(.system(size: 10.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76)
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            NSWorkspace.shared.open(url)
            stack.isOpen = false
        }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.path)
    }
}

/// A preview thumbnail that shows a marker where a dragged file is (driven by the app delegate's drag tracking).
private struct DropTargetThumbnail: View {
    @EnvironmentObject var previews: PreviewModel
    let thumbnail: WindowThumbnail

    var body: some View {
        let marker = previews.dragMarker?.id == thumbnail.id ? previews.dragMarker?.point : nil
        Image(nsImage: thumbnail.image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 180, maxHeight: 120)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { previews.imageFrames[thumbnail.id] = $0 }
            .overlay(alignment: .topLeading) {
                if let marker {
                    Image(nsImage: previews.dragIcon ?? NSWorkspace.shared.icon(for: .data))
                        .resizable()
                        .frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                        .position(marker)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(marker == nil ? 0 : 0.85), lineWidth: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(marker == nil ? 1 : 1.06)
            .animation(.spring(duration: 0.25, bounce: 0.2), value: marker == nil)
    }
}
