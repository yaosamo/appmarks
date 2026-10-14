import AppKit
import SwiftUI

struct StripItem: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    let icon: NSImage?
    let thumbnail: NSImage?
}

final class StripModel: ObservableObject {
    @Published var items: [StripItem] = []
}

final class StripPanel: NSPanel {
    init(model: StripModel, onSelect: @escaping (CGWindowID, Bool) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        contentView = FirstClickHostingView(rootView: StripView(model: model, onSelect: onSelect))
        reposition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition() {
        let visible = NSScreen.screens[0].visibleFrame
        setFrame(NSRect(x: visible.minX, y: visible.minY, width: Geometry.stripWidth, height: visible.height), display: true)
    }
}

/// The panel never becomes key, so without this the first click on a thumbnail would be swallowed.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct StripView: View {
    @ObservedObject var model: StripModel
    let onSelect: (CGWindowID, Bool) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 26) {
                ForEach(model.items) { item in
                    Thumbnail(item: item)
                        .onTapGesture { onSelect(item.id, NSEvent.modifierFlags.contains(.option)) }
                        .contextMenu {
                            Button("Add to Stage") { onSelect(item.id, false) }
                            Button("Show Only This Window") { onSelect(item.id, true) }
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .animation(.spring(duration: 0.3), value: model.items.map(\.id))
    }
}

private struct Thumbnail: View {
    let item: StripItem
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                preview
                    .frame(maxWidth: 128, maxHeight: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                    .rotation3DEffect(.degrees(hovering ? 0 : 18), axis: (0, 1, 0), perspective: 0.55)
                if let icon = item.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                        .offset(x: -10, y: 12)
                }
            }
            Text(hovering ? item.title : item.appName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .lineLimit(1)
                .frame(maxWidth: 150)
        }
        .scaleEffect(hovering ? 1.07 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var preview: some View {
        if let thumbnail = item.thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(.regularMaterial)
                .aspectRatio(1.5, contentMode: .fit)
                .overlay(Text(item.title).font(.caption2).lineLimit(2).padding(8))
        }
    }
}
