import CoreGraphics

/// Two windows glued edge to edge: side by side with `first` on the left, or stacked with `first` on top.
struct GlueSeam: Hashable {
    let first: CGWindowID
    let second: CGWindowID
    let beside: Bool

    func contains(_ id: CGWindowID) -> Bool { first == id || second == id }
}

/// Window frames in Accessibility coordinates (top-left origin).
enum GlueGeometry {
    /// How close a dropped window's side has to come to another's to glue on.
    static let reach: CGFloat = 16
    /// How far apart glued sides can drift, an app rounding its frame, before the seam counts as pulled apart.
    static let slack: CGFloat = 6

    struct Snap: Equatable {
        /// How far the dropped window moves to sit flush.
        let offset: CGVector
        let movingFirst: Bool
        let beside: Bool
    }

    /// A corner brushing another window isn't a seam: they have to share a good part of the side.
    private static func sharesEnough(_ shared: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool {
        shared >= min(80, min(a, b) * 0.25)
    }

    /// Where `moving` goes to sit flush against the nearest side of `fixed` within reach, if any.
    static func snap(_ moving: CGRect, to fixed: CGRect) -> Snap? {
        let sharedY = min(moving.maxY, fixed.maxY) - max(moving.minY, fixed.minY)
        let sharedX = min(moving.maxX, fixed.maxX) - max(moving.minX, fixed.minX)
        let besideOK = sharesEnough(sharedY, moving.height, fixed.height)
        let stackedOK = sharesEnough(sharedX, moving.width, fixed.width)
        let options: [(gap: CGFloat, ok: Bool, snap: Snap)] = [
            (fixed.minX - moving.maxX, besideOK, Snap(offset: CGVector(dx: fixed.minX - moving.maxX, dy: 0), movingFirst: true, beside: true)),
            (moving.minX - fixed.maxX, besideOK, Snap(offset: CGVector(dx: fixed.maxX - moving.minX, dy: 0), movingFirst: false, beside: true)),
            (fixed.minY - moving.maxY, stackedOK, Snap(offset: CGVector(dx: 0, dy: fixed.minY - moving.maxY), movingFirst: true, beside: false)),
            (moving.minY - fixed.maxY, stackedOK, Snap(offset: CGVector(dx: 0, dy: fixed.maxY - moving.minY), movingFirst: false, beside: false)),
        ]
        return options.filter { $0.ok && abs($0.gap) < reach }.min { abs($0.gap) < abs($1.gap) }?.snap
    }

    /// Still edge to edge, give or take `slack`.
    static func touching(_ first: CGRect, _ second: CGRect, beside: Bool) -> Bool {
        if beside {
            let shared = min(first.maxY, second.maxY) - max(first.minY, second.minY)
            return abs(second.minX - first.maxX) <= slack && shared >= 20
        }
        let shared = min(first.maxX, second.maxX) - max(first.minX, second.minX)
        return abs(second.minY - first.maxY) <= slack && shared >= 20
    }

    /// The middle of the stretch the two windows share, on the seam.
    static func seamPoint(_ first: CGRect, _ second: CGRect, beside: Bool) -> CGPoint {
        if beside {
            return CGPoint(x: (first.maxX + second.minX) / 2,
                           y: (max(first.minY, second.minY) + min(first.maxY, second.maxY)) / 2)
        }
        return CGPoint(x: (max(first.minX, second.minX) + min(first.maxX, second.maxX)) / 2,
                       y: (first.maxY + second.minY) / 2)
    }

    /// Every window glued to `id`, directly or through others, `id` included.
    static func group(of id: CGWindowID, in seams: Set<GlueSeam>) -> Set<CGWindowID> {
        var group: Set<CGWindowID> = [id], frontier = [id]
        while let next = frontier.popLast() {
            for seam in seams where seam.contains(next) {
                for member in [seam.first, seam.second] where group.insert(member).inserted { frontier.append(member) }
            }
        }
        return group
    }
}
