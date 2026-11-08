import AppKit
import SwiftUI

/// A file being copied, downloaded or received over AirDrop, as the app doing it publishes its progress.
struct Transfer: Identifiable, Equatable {
    let id: ObjectIdentifier
    let url: URL?
    let label: String
    /// 0...1, or nil while the total is not known yet.
    var fraction: Double?
}

/// File operations in progress, from the progress Finder, Safari and AirDrop publish on the files they
/// write. macOS only hands that progress to a subscriber watching the file's own folder, never its parents,
/// so this watches the places transfers usually land: Downloads (AirDrop, Safari), Desktop, Documents, the
/// home folder, the top of each mounted drive, and one folder level inside each of those.
@MainActor
final class Transfers: ObservableObject {
    static let shared = Transfers()

    @Published private(set) var items: [Transfer] = []

    private var subscribers: [URL: Any] = [:]
    private var running: [ObjectIdentifier: (progress: Progress, label: String)] = [:]
    private var poll: Timer?
    private var rescan: Timer?
    /// Enough for the usual places and their subfolders; each one is a registration with the system.
    private static let maxFolders = 300

    func start() {
        guard rescan == nil else { return }
        watchFolders()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchFolders() }
            }
        }
        // New folders appear without a notification; picking them up within half a minute is enough.
        rescan = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchFolders() }
        }
    }

    private func watchFolders() {
        let wanted = Set(Self.folders())
        for (url, token) in subscribers where !wanted.contains(url) {
            Progress.removeSubscriber(token)
            subscribers[url] = nil
        }
        for url in wanted where subscribers[url] == nil {
            subscribers[url] = Progress.addSubscriber(forFileURL: url) { [weak self] progress in
                let id = ObjectIdentifier(progress)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.began(progress) } }
                return { DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(id) } } }
            }
        }
    }

    private static func folders() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let roots = [home.appending(path: "Downloads"), home.appending(path: "Desktop"),
                     home.appending(path: "Documents"), home] + volumes.filter { $0.path != "/" }
        var result = roots.map(\.standardizedFileURL)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        for root in roots {
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
            for child in children {
                guard result.count < maxFolders else { return result }
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true, values?.isPackage != true { result.append(child.standardizedFileURL) }
            }
        }
        return Array(Set(result))
    }

    private func began(_ progress: Progress) {
        let id = ObjectIdentifier(progress)
        guard running[id] == nil, !progress.isFinished, !progress.isCancelled else { return }
        // A watched folder can be the item itself as well as its parent's child, and each subscription gets
        // its own copy of the progress: one bar per file.
        let url = (progress.userInfo[.fileURLKey] as? URL)?.standardizedFileURL
        if let url, running.values.contains(where: { ($0.progress.userInfo[.fileURLKey] as? URL)?.standardizedFileURL == url }) {
            return
        }
        running[id] = (progress, Self.label(progress))
        Log.write("transfer: \(running[id]!.label)")
        refresh()
        guard poll == nil else { return }
        // Read on a timer rather than observing: a big copy reports thousands of steps a second.
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func ended(_ id: ObjectIdentifier) {
        guard running[id] != nil else { return }
        running[id] = nil
        refresh()
    }

    private func refresh() {
        for (id, entry) in running where entry.progress.isFinished || entry.progress.isCancelled { running[id] = nil }
        let next = running.map { id, entry in
            let p = entry.progress
            let known = p.totalUnitCount > 0 && !p.isIndeterminate
            return Transfer(id: id, url: p.userInfo[.fileURLKey] as? URL, label: entry.label,
                            fraction: known ? min(max(p.fractionCompleted, 0), 1) : nil)
        }.sorted { $0.label < $1.label }
        if next != items { items = next }
        if running.isEmpty {
            poll?.invalidate()
            poll = nil
        }
    }

    private static func label(_ progress: Progress) -> String {
        let url = progress.userInfo[.fileURLKey] as? URL
        let name = url?.lastPathComponent ?? "file"
        let count = (progress.userInfo[.fileTotalCountKey] as? Int).map { $0 > 1 ? " (\($0) items)" : "" } ?? ""
        let kind = progress.userInfo[.fileOperationKindKey] as? Progress.FileOperationKind
        let verb = switch kind {
        case .receiving: "AirDrop:"
        case .downloading: "Downloading"
        case .decompressingAfterDownloading: "Unzipping"
        case .uploading: "Uploading"
        case .duplicating: "Duplicating"
        default: "Copying"
        }
        let destination = url.map { " to \($0.deletingLastPathComponent().lastPathComponent)" } ?? ""
        return kind == .receiving ? "\(verb) \(name)\(count)" : "\(verb) \(name)\(count)\(destination)"
    }
}

/// Thin bars riding the top border of the bubbles' backdrop, one segment per transfer.
enum TransferBars {
    static let thickness: CGFloat = 3
    private static let gap: CGFloat = 3
    /// How far past the outer bars the pointer still counts as on them: the bars are thin.
    private static let reach: CGFloat = 6

    /// Each transfer's bar, the first straddling the backdrop's top edge between its rounded corners and the
    /// rest stacked above it, as many as the room above the backdrop holds.
    static func frames(count: Int, on backdrop: CGRect, cornerRadius: CGFloat) -> [CGRect] {
        guard count > 0, !backdrop.isNull else { return [] }
        let inset = max(cornerRadius, 6)
        let width = backdrop.width - 2 * inset
        guard width > 2 else { return [] }
        return (0..<count).map { i in
            CGRect(x: backdrop.minX + inset, y: backdrop.minY - thickness / 2 - CGFloat(i) * (thickness + gap),
                   width: width, height: thickness)
        }.filter { $0.minY >= 1 }
    }

    /// The bar under `point`: the nearest one, while the point is on the stack or just around it.
    static func index(at point: CGPoint, in bars: [CGRect]) -> Int? {
        let stack = bars.reduce(CGRect.null) { $0.union($1) }
        guard !stack.isNull, stack.insetBy(dx: -2, dy: -reach).contains(point) else { return nil }
        return bars.indices.min { abs(bars[$0].midY - point.y) < abs(bars[$1].midY - point.y) }
    }
}

struct TransferBar: View {
    let fraction: Double?
    let size: CGSize
    let highlighted: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.primary.opacity(0.18))
            if let fraction {
                Capsule().fill(Color.accentColor)
                    .frame(width: max(size.width * fraction, size.height))
                    .animation(.linear(duration: 0.1), value: fraction)
            } else {
                // Total not known yet: a short piece sweeping back and forth.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (sin(t * 3) + 1) / 2
                    let piece = size.width * 0.3
                    Capsule().fill(Color.accentColor.opacity(0.8))
                        .frame(width: piece)
                        .offset(x: (size.width - piece) * phase)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 1)
        .scaleEffect(y: highlighted ? 1.6 : 1)
    }
}

/// What the hovered bar is: name, destination and how far along.
struct TransferLabel: View {
    @ObservedObject var tip: TransferTip
    @ObservedObject var transfers = Transfers.shared

    var body: some View {
        if let transfer = transfers.items.first(where: { $0.id == tip.id }) {
            HStack(spacing: 6) {
                Text(transfer.label).lineLimit(1).truncationMode(.middle)
                Text(transfer.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Backdrop(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.12)))
            .fixedSize()
        }
    }
}

/// The hovered bar's label, in a window of its own: the bubbles' panel is often a column too narrow for it.
@MainActor
final class TransferTip: ObservableObject {
    @Published var id: ObjectIdentifier?
    private static let maxWidth: CGFloat = 340
    private lazy var window: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TransferLabel(tip: self))
        return panel
    }()

    /// Centred above `bar`, given in screen coordinates (bottom-left origin), kept on its screen.
    func show(_ id: ObjectIdentifier, above bar: CGRect, level: NSWindow.Level) {
        self.id = id
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let size = CGSize(width: min(view.fittingSize.width, Self.maxWidth), height: view.fittingSize.height)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: bar.midX, y: bar.midY)) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .infinite
        var origin = CGPoint(x: bar.midX - size.width / 2, y: bar.maxY + 6)
        origin.x = min(max(origin.x, area.minX + 4), area.maxX - size.width - 4)
        // No room above, near the top of the screen: under the bars instead.
        if origin.y + size.height > area.maxY { origin.y = bar.minY - 6 - size.height }
        window.level = level
        window.setFrame(CGRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }

    func hide() {
        id = nil
        if window.isVisible { window.orderOut(nil) }
    }
}
