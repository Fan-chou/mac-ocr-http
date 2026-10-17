import Foundation

/// Vision occasionally reads short runs of rotation-ambiguous digits upside
/// down inside an upright page ("37" -> "LE", "620" -> "0Z9"). Such a line
/// comes back with its quad turned 180°: top-left is right of top-right and
/// below bottom-left (pixel space, y down).
public enum Orientation {
    /// Above this share of flipped lines the page itself is upside down and
    /// the lines are left alone.
    public static let maxFlippedShare = 0.3

    public static func isFlipped(_ quad: Quad) -> Bool {
        quad.topRight.x < quad.topLeft.x && quad.bottomLeft.y < quad.topLeft.y
    }

    /// Indices to keep, plus flipped lines that have no upright reading of the
    /// same spot (`orphans`). An upright line that covers a flipped one always
    /// wins, whatever the confidences. Orphans are not in `kept`; the caller
    /// re-reads or drops them.
    public static func resolve(_ lines: [OCRLine]) -> (kept: [Int], orphans: [Int]) {
        let flipped = lines.indices.filter { isFlipped(lines[$0].quad) }
        if flipped.isEmpty || Double(flipped.count) > maxFlippedShare * Double(lines.count) {
            return (Array(lines.indices), [])
        }
        let flippedSet = Set(flipped)
        let upright = lines.indices.filter { !flippedSet.contains($0) }
        var orphans: [Int] = []
        for index in flipped {
            let box = lines[index].bbox
            let covered = upright.contains { other in
                sameSpot(box, lines[other].bbox)
            }
            if !covered { orphans.append(index) }
        }
        return (upright, orphans)
    }

    /// IoU ≥ 0.3, or the smaller box at least half covered.
    static func sameSpot(_ a: BBox, _ b: BBox) -> Bool {
        let ix = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let iy = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let inter = ix * iy
        if inter <= 0 { return false }
        let areaA = a.width * a.height
        let areaB = b.width * b.height
        let union = areaA + areaB - inter
        if union > 0, inter / union >= 0.3 { return true }
        let smaller = min(areaA, areaB)
        return smaller > 0 && inter / smaller >= 0.5
    }
}
