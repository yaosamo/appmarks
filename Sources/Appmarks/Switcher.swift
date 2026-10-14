import AppKit
import SwiftUI

struct SwitcherItem: Identifiable, Equatable {
    let id: CGWindowID
    let title: String
    let icon: NSImage?
    let thumbnail: NSImage?

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.title == b.title && a.thumbnail === b.thumbnail
    }
}

final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
}

/// Previews of the other windows on stage, pinned to a corner of the focused window. It follows focus
/// rather than sitting on every window, since a window behind would cover its own copy anyway.
final class SwitcherPanel: NSPanel {
    private let host: NSView
    private var attachedID: CGWindowID = 0
    private var placedFor = CGRect.null
    private var style = Style()
    private var size = CGSize.zero
    private var link: CADisplayLink?
    private var lastChange = Date.distantPast

    init(model: SwitcherModel, onSelect: @escaping (CGWindowID) -> Void) {
        host = FirstClickHostingView(rootView: SwitcherView(model: model, onSelect: onSelect))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `window` is the focused window's frame in Accessibility coordinates (top-left origin). Ordered
    /// directly above that window at normal level, so windows in front of it also cover the switcher.
    func attach(to window: CGRect, id: CGWindowID, style: Style) {
        host.layoutSubtreeIfNeeded()
        size = host.fittingSize
        self.style = style
        attachedID = id
        place(window)
        order(.above, relativeTo: Int(id))
    }

    func isAttached(to id: CGWindowID, frame: CGRect, style: Style) -> Bool {
        attachedID == id && placedFor == frame && self.style == style
    }

    /// Apps report moves at their own pace, often 10–20 times a second or only on release, while the
    /// window server has the real frame every refresh; follow that until the window is still for 300ms.
    func follow() {
        lastChange = Date()
        guard link == nil, isVisible else { return }
        link = NSScreen.screens[0].displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    override func orderOut(_ sender: Any?) {
        link?.invalidate()
        link = nil
        super.orderOut(sender)
    }

    @objc private func tick() {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], attachedID) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String], let frame = CGRect(dictionaryRepresentation: bounds as! CFDictionary)
        else { return orderOut(nil) }
        if frame != placedFor {
            place(frame)
            lastChange = Date()
        } else if Date().timeIntervalSince(lastChange) > 0.3 {
            link?.invalidate()
            link = nil
        }
    }

    private func place(_ window: CGRect) {
        placedFor = window
        let x = switch style.switcherPlacement {
        case .outsideLeft: window.minX - style.switcherOffsetX - size.width
        case .insideTopLeft: window.minX + style.switcherOffsetX
        case .insideTopRight: window.maxX - style.switcherOffsetX - size.width
        }
        let y = window.minY + style.switcherOffsetY
        let primaryHeight = NSScreen.screens[0].frame.height
        setFrame(NSRect(x: x, y: primaryHeight - y - size.height, width: size.width, height: size.height), display: true)
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var settings = Settings.shared
    let onSelect: (CGWindowID) -> Void

    var body: some View {
        let style = settings.style
        let layout = style.switcherVertical
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: style.switcherSpacing))
            : AnyLayout(HStackLayout(spacing: style.switcherSpacing))
        layout {
            ForEach(model.items) { item in
                SwitcherChip(item: item, style: style)
                    .onTapGesture { onSelect(item.id) }
            }
        }
        .padding(style.switcherBackground ? 5 : 0)
        .background {
            if style.switcherBackground {
                RoundedRectangle(cornerRadius: style.switcherCornerRadius + 4).fill(.ultraThinMaterial)
            }
        }
        .padding(style.switcherHoverScale * 4)
        .fixedSize()
    }
}

private struct SwitcherChip: View {
    let item: SwitcherItem
    let style: Style
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: style.switcherCornerRadius).fill(.regularMaterial)
                        .aspectRatio(1.5, contentMode: .fit)
                }
            }
            .frame(height: style.switcherHeight)
            .clipShape(RoundedRectangle(cornerRadius: style.switcherCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: style.switcherCornerRadius).stroke(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            if style.switcherShowIcon, let icon = item.icon {
                Image(nsImage: icon).resizable()
                    .frame(width: style.switcherHeight * 0.5, height: style.switcherHeight * 0.5)
                    .offset(x: 4, y: 4)
            }
        }
        .scaleEffect(hovering ? style.switcherHoverScale : 1)
        .animation(.easeOut(duration: style.hoverDuration), value: hovering)
        .onHover { hovering = $0 }
        .help(item.title)
    }
}
