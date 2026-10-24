import AppKit
import SwiftUI

/// Window preview cards shown above the hovered Dock icon. Only this part is SwiftUI: it changes when a
/// preview opens, not on every frame.
struct PreviewsView: View {
    @EnvironmentObject var previews: PreviewModel

    var body: some View {
        GeometryReader { geo in
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
            .fixedSize()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { previews.rowRect = $0 }
            .offset(x: clampedX(in: geo.size.width) - geo.size.width / 2)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }

    /// Centred over the icon, but kept on screen at the edges.
    private func clampedX(in width: CGFloat) -> CGFloat {
        let half = previews.rowRect.width / 2 + 8
        return min(max(previews.anchorX, half), width - half)
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
