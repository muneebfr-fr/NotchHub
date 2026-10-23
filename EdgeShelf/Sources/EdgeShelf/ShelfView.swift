import AppKit
import SwiftUI

@MainActor
final class ShelfState: ObservableObject {
    @Published var dropTargeted = false
}

struct ShelfView: View {
    @EnvironmentObject var store: ShelfStore
    @EnvironmentObject var state: ShelfState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shelf")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                if !store.items.isEmpty {
                    Button("Clear") { store.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 6)

            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24, weight: .light))
                        .symbolEffect(.bounce, value: state.dropTargeted)
                    Text("Drop files, links,\nimages or text here")
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.items) { item in
                            ShelfCard(item: item)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .move(edge: .trailing).combined(with: .opacity)
                                ))
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: shape)
        .overlay(
            shape.strokeBorder(Color.white.opacity(state.dropTargeted ? 0.7 : 0), lineWidth: 1.5)
                .animation(.easeOut(duration: 0.15), value: state.dropTargeted)
        )
        .scaleEffect(state.dropTargeted ? 1.015 : 1)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: state.dropTargeted)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }
}

private struct ShelfCard: View {
    @EnvironmentObject var store: ShelfStore
    let item: ShelfItem
    @State private var hovering = false
    @State private var copied = false

    private var subtitle: String {
        switch item.kind {
        case .file:
            guard store.exists(item) else { return "Missing" }
            let url = store.fileURL(item)
            let size = (try? url?.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            return size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Folder"
        case .link: return URL(string: item.url ?? "")?.host() ?? "Link"
        case .text: return copied ? "Copied" : "Text"
        case .image: return "Image"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: store.thumbnail(item))
                .resizable()
                .aspectRatio(contentMode: item.kind == .image ? .fill : .fit)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(.white.opacity(0.8))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? "Untitled")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(store.exists(item) ? Color.white.opacity(0.5) : Color.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if hovering {
                Button { store.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Remove from shelf")
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.05))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture(count: 1) {
            store.open(item)
            if item.kind == .text { copied = true }
        }
        .onDrag { store.dragProvider(item) }
        .contextMenu {
            Button("Open") { store.open(item) }
            Button("Copy") { store.copy(item) }
            if item.kind == .file || item.kind == .image { Button("Show in Finder") { store.reveal(item) } }
            Divider()
            Button("Remove from Shelf") { store.remove(item) }
        }
        .help(item.kind == .text ? (item.text ?? "") : (item.path ?? item.url ?? ""))
    }
}
