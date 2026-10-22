import AppKit
import SwiftUI

/// Window preview cards. Only this part is SwiftUI: it changes when a preview opens, not on every frame.
struct PreviewsView: View {
    @EnvironmentObject var previews: PreviewModel

    var body: some View {
        GeometryReader { geo in
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(previews.thumbnails) { thumbnail in
                        Button { previews.focus(thumbnail) } label: {
                            VStack(spacing: 6) {
                                Image(nsImage: thumbnail.image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 180, maxHeight: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(thumbnail.title.isEmpty ? " " : thumbnail.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
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
            .position(x: clampedX(in: geo.size.width), y: geo.size.height - 80)
        }
        .environment(\.colorScheme, .dark)
    }

    /// Centred over the icon, but kept on screen at the dock's ends.
    private func clampedX(in width: CGFloat) -> CGFloat {
        let half = previews.rowRect.width / 2 + 8
        return min(max(previews.anchorX, half), width - half)
    }
}
