import Foundation

public struct PageText: Sendable {
    public var lines: [OCRLine]
    public var rows: [OCRRow]
    public var blocks: [OCRBlock]
    public var text: String

    public init(lines: [OCRLine], rows: [OCRRow], blocks: [OCRBlock], text: String) {
        self.lines = lines
        self.rows = rows
        self.blocks = blocks
        self.text = text
    }
}

/// Dedupe and row grouping. Foundation only, so tests can compile this file
/// with `TextTypes.swift` and no Vision.
public enum LineMerge {
    /// NFKC, strip every Unicode whitespace character, then lowercase.
    public static func matchKey(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        var output = ""
        output.reserveCapacity(compatible.count)
        for character in compatible where !character.isWhitespace && !character.isNewline {
            output.append(contentsOf: character.lowercased())
        }
        return output
    }

    /// `tiles` is parallel to `lines` and names the tile that produced each
    /// observation. An empty array, or a count that does not match, means the
    /// lines are untagged.
    public static func assemble(_ lines: [OCRLine], tiles: [TileFrame?] = []) -> PageText {
        let frames: [TileFrame?]
        if tiles.count == lines.count {
            frames = tiles
        } else {
            frames = Array(repeating: nil, count: lines.count)
        }
        let median = medianHeight(lines)
        let unique = dedupe(lines, tiles: frames, median: median)
        return pack(unique, median: median)
    }

    /// Row grouping for observations that are already deduped. `assemble`
    /// dedupes first; this entry point does not, so a saved `lines[]` array
    /// can be rebuilt without a second untagged dedupe pass.
    /// `tiles` is parallel to `lines`. Saved observations can be regrouped
    /// with the tile rectangles reconstructed, without a second dedupe pass.
    public static func group(_ lines: [OCRLine], tiles: [TileFrame?] = []) -> PageText {
        let frames: [TileFrame?]
        if tiles.count == lines.count {
            frames = tiles
        } else {
            frames = Array(repeating: nil, count: lines.count)
        }
        let median = medianHeight(lines)
        let nodes = lines.indices.map { index in
            let line = lines[index]
            return Node(
                line: line,
                key: matchKey(line.text),
                tile: frames[index],
                centerY: line.bbox.y + line.bbox.height / 2,
                interior: false,
                stripID: nil
            )
        }.sorted { lhs, rhs in
            if lhs.centerY != rhs.centerY { return lhs.centerY < rhs.centerY }
            return lhs.line.bbox.x < rhs.line.bbox.x
        }
        return pack(nodes, median: median)
    }
}

private func pack(_ nodes: [Node], median: Double) -> PageText {
    let built = buildPage(nodes, median: median)
    return PageText(
        lines: nodes.map(\.line),
        rows: built.rows,
        blocks: built.blocks,
        text: built.rows.map(\.text).joined(separator: "\n")
    )
}

private struct Strip {
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double
    /// Tiles stand side by side, so the shared region is a vertical band.
    var sideBySide: Bool
    var tileA: TileFrame
    var tileB: TileFrame
}

private struct Node {
    var line: OCRLine
    var key: String
    var tile: TileFrame?
    var centerY: Double
    var interior: Bool
    var stripID: Int?
}

private func dedupe(_ lines: [OCRLine], tiles: [TileFrame?], median: Double) -> [Node] {
    let strips = overlapStrips(tiles)
    var nodes: [Node] = []
    nodes.reserveCapacity(lines.count)
    for index in lines.indices {
        let line = lines[index]
        let key = LineMerge.matchKey(line.text)
        let tile = tiles[index]
        let stripID = localStrip(line.bbox, tile: tile, strips: strips)
        nodes.append(Node(
            line: line,
            key: key,
            tile: tile,
            centerY: line.bbox.y + line.bbox.height / 2,
            interior: isInterior(line.bbox, tile: tile, strips: strips, stripID: stripID),
            stripID: stripID
        ))
    }

    var alive = Array(repeating: true, count: nodes.count)
    let order = nodes.indices.sorted { nodes[$0].centerY < nodes[$1].centerY }
    let maxHeight = lines.map(\.bbox.height).max() ?? 0
    let yLimit = (median > 0 ? 0.5 * median : 0) + max(maxHeight, 1)

    for position in order.indices {
        let left = order[position]
        if !alive[left] { continue }
        let limit = nodes[left].centerY + yLimit
        var next = position + 1
        while next < order.count {
            let right = order[next]
            if nodes[right].centerY > limit { break }
            if alive[right], let winner = winnerOfDuplicate(nodes[left], nodes[right], strips: strips, median: median) {
                if winner == .right {
                    nodes[left] = nodes[right]
                }
                alive[right] = false
            }
            next += 1
        }
    }

    var kept: [Node] = []
    kept.reserveCapacity(nodes.count)
    for index in order where alive[index] {
        kept.append(nodes[index])
    }
    return kept.sorted { lhs, rhs in
        if lhs.centerY != rhs.centerY { return lhs.centerY < rhs.centerY }
        return lhs.line.bbox.x < rhs.line.bbox.x
    }
}

private enum Side {
    case left
    case right
}

/// Geometry first. String comparison runs only after a pair already coincides,
/// or both observations live in the same tile-overlap strip.
private func winnerOfDuplicate(_ lhs: Node, _ rhs: Node, strips: [Strip], median: Double) -> Side? {
    if lhs.key.isEmpty || rhs.key.isEmpty { return nil }
    let leftBox = lhs.line.bbox
    let rightBox = rhs.line.bbox

    if lhs.interior, rhs.interior {
        return nil
    }

    if let stripID = lhs.stripID, stripID == rhs.stripID {
        guard sameBand(leftBox, rightBox, median: median) else { return nil }
        let overlap = xOverlap(leftBox, rightBox)
        guard overlap > 0 else { return nil }
        let minWidth = min(leftBox.width, rightBox.width)
        let keysEqual = lhs.key == rhs.key
        let strong = coincides(leftBox, rightBox, median: median)
        let halfWidth = minWidth > 0 && overlap >= 0.5 * minWidth && keysEqual
        guard strong || halfWidth else { return nil }
        guard textsMatch(lhs.key, rhs.key) else { return nil }
        let strip = strips[stripID]
        let leftScore = seamDistance(leftBox, tile: lhs.tile, strip: strip)
        let rightScore = seamDistance(rightBox, tile: rhs.tile, strip: strip)
        if abs(leftScore - rightScore) > 0.5 {
            return rightScore > leftScore ? .right : .left
        }
        return preferRight(lhs, rhs) ? .right : .left
    }

    guard coincides(leftBox, rightBox, median: median), textsMatch(lhs.key, rhs.key) else { return nil }
    return preferRight(lhs, rhs) ? .right : .left
}

/// IoU ≥ 0.5, or the smaller box ≥ 80% covered, or same band and x-overlap
/// ≥ 80% of the narrower width. A 256px seam on an ~1800px fragment fails all three.
private func coincides(_ lhs: BBox, _ rhs: BBox, median: Double) -> Bool {
    if iou(lhs, rhs) >= 0.5 || boxContainment(lhs, rhs) >= 0.8 { return true }
    let minWidth = min(lhs.width, rhs.width)
    guard minWidth > 0, sameBand(lhs, rhs, median: median) else { return false }
    return xOverlap(lhs, rhs) >= 0.8 * minWidth
}

private func textsMatch(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    if lhs.isEmpty || rhs.isEmpty { return false }
    let shorter: String
    let longer: String
    if lhs.count <= rhs.count {
        shorter = lhs
        longer = rhs
    } else {
        shorter = rhs
        longer = lhs
    }
    if shorter.count >= 4, longer.contains(shorter) { return true }
    return similarity(lhs, rhs) >= 0.85
}

/// true when `rhs` should replace `lhs`. Containing text wins over confidence.
private func preferRight(_ lhs: Node, _ rhs: Node) -> Bool {
    if lhs.key != rhs.key {
        if lhs.key.count >= rhs.key.count, rhs.key.count >= 4, lhs.key.contains(rhs.key) { return false }
        if rhs.key.count > lhs.key.count, lhs.key.count >= 4, rhs.key.contains(lhs.key) { return true }
    }
    if lhs.line.confidence != rhs.line.confidence {
        return rhs.line.confidence > lhs.line.confidence
    }
    return rhs.key.count > lhs.key.count
}

private struct BuiltPage {
    var rows: [OCRRow]
    var blocks: [OCRBlock]
}

/// Recursive XY-cut. The widest full-width whitespace (at least one median
/// line height) splits the page top to bottom. Each band then splits on
/// vertical gutters, left to right, and the cut repeats inside a column.
/// A box that crosses a gutter is its own band and is not pushed into a column.
private func buildPage(_ lines: [Node], median: Double) -> BuiltPage {
    let basis = median > 0 ? median : 16
    var tables = Set<Int>()
    let groups = layoutLines(lines, indices: Array(lines.indices), basis: basis, tables: &tables)
    var rows: [OCRRow] = []
    var blocks: [OCRBlock] = []
    for group in groups where !group.isEmpty {
        let start = rows.count
        if let first = group.first, tables.contains(first) {
            rows.append(contentsOf: buildTableRows(lines, indices: group, basis: basis))
        } else {
            let gutters = localGutters(lines, indices: group, basis: basis)
            rows.append(contentsOf: buildRows(lines, indices: group, basis: basis, gutters: gutters))
        }
        if rows.count > start, let block = blockBox(lines, rows: rows, range: start..<rows.count) {
            blocks.append(block)
        }
    }
    return absorbContainedRows(lines, rows: rows, blocks: blocks, basis: basis)
}

/// A seam duplicate or a short scrap that still sits on its line becomes its
/// own row once a gutter puts it in another block. Fold it back. The host is
/// the larger box: either it already covers 80% of the scrap, or the scrap is
/// at most three characters (or narrower than two line heights) and 80% of
/// its width lies on the host. Side-by-side cells fail both tests.
private func absorbContainedRows(
    _ lines: [Node],
    rows: [OCRRow],
    blocks: [OCRBlock],
    basis: Double
) -> BuiltPage {
    var rows = rows
    var alive = Array(repeating: true, count: rows.count)
    let compactCount = rows.map { row in
        row.text.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
    }
    let maxHeight = rows.map(\.bbox.height).max() ?? basis
    let window = max(basis, maxHeight)
    for _ in 0..<3 {
        var moved = false
        let order = rows.indices.filter { alive[$0] }.sorted { rows[$0].bbox.y < rows[$1].bbox.y }
        var cursor = 0
        for position in order.indices {
            let fragment = order[position]
            if !alive[fragment] { continue }
            let fragmentBox = rows[fragment].bbox
            let fragmentCenter = fragmentBox.y + fragmentBox.height / 2
            while cursor < order.count,
                  rows[order[cursor]].bbox.y + rows[order[cursor]].bbox.height < fragmentCenter - window {
                cursor += 1
            }
            var host: Int?
            var hostArea = 0.0
            var scan = cursor
            while scan < order.count {
                let candidate = order[scan]
                scan += 1
                if candidate == fragment || !alive[candidate] { continue }
                let hostBox = rows[candidate].bbox
                if hostBox.y > fragmentCenter + window { break }
                let covered = containedInRow(hostBox, fragmentBox, basis: basis)
                let scrap = shortScrapOnRow(hostBox, fragmentBox, compactCount: compactCount[fragment], basis: basis)
                if !covered && !scrap { continue }
                let candidateArea = area(hostBox)
                if host == nil || candidateArea > hostArea {
                    host = candidate
                    hostArea = candidateArea
                }
            }
            guard let host, area(fragmentBox) <= hostArea else { continue }
            let combined = rows[host].lineIndices + rows[fragment].lineIndices
            guard let merged = makeRow(lines, combined) else { continue }
            rows[host] = merged
            alive[fragment] = false
            moved = true
        }
        if !moved { break }
    }
    var kept: [OCRRow] = []
    var remap = Array(repeating: -1, count: rows.count)
    for index in rows.indices where alive[index] {
        remap[index] = kept.count
        kept.append(rows[index])
    }
    var keptBlocks: [OCRBlock] = []
    for block in blocks {
        let indices = block.rowIndices.compactMap { index -> Int? in
            guard index >= 0, index < remap.count, remap[index] >= 0 else { return nil }
            return remap[index]
        }
        guard let first = indices.first else { continue }
        var box = kept[first].bbox
        for index in indices.dropFirst() {
            box = unionBox(box, kept[index].bbox)
        }
        keptBlocks.append(OCRBlock(bbox: box, rowIndices: indices))
    }
    return BuiltPage(rows: kept, blocks: keptBlocks)
}

private func containedInRow(_ host: BBox, _ fragment: BBox, basis: Double) -> Bool {
    let fragmentArea = area(fragment)
    let hostArea = area(host)
    guard fragmentArea > 0, hostArea >= fragmentArea else { return false }
    guard boxContainment(host, fragment) >= 0.8 else { return false }
    let center = fragment.x + fragment.width / 2
    guard center >= host.x, center <= host.x + host.width else { return false }
    // An oversized box can cover the next line. Seam copies share a center.
    let hostCenter = host.y + host.height / 2
    let fragmentCenter = fragment.y + fragment.height / 2
    return abs(hostCenter - fragmentCenter) <= basis
}

private func shortScrapOnRow(_ host: BBox, _ fragment: BBox, compactCount: Int, basis: Double) -> Bool {
    let short = compactCount <= 3 || fragment.width < 2 * basis
    guard short, sameBand(host, fragment, median: basis) else { return false }
    guard fragment.width > 0, fragment.width <= host.width else { return false }
    return xOverlap(host, fragment) >= 0.8 * fragment.width
}

/// `tables` collects the first index of every group that is a grid table.
private func layoutLines(_ lines: [Node], indices: [Int], basis: Double, tables: inout Set<Int>) -> [[Int]] {
    if indices.count <= 1 {
        return indices.isEmpty ? [] : [indices]
    }
    if isTable(lines, indices: indices, basis: basis) {
        let ordered = indices.sorted { lines[$0].centerY < lines[$1].centerY }
        if let first = ordered.first { tables.insert(first) }
        return [ordered]
    }
    let slices = horizontalSlices(lines, indices: indices, basis: basis)
    if slices.count >= 2 {
        return slices.flatMap { layoutLines(lines, indices: $0, basis: basis, tables: &tables) }
    }
    if let pieces = splitVotedColumns(lines, indices: indices, basis: basis) {
        return pieces.flatMap { layoutLines(lines, indices: $0, basis: basis, tables: &tables) }
    }
    let gutters = localGutters(lines, indices: indices, basis: basis)
    let spanning = indices.filter { crossesGutter(lines[$0].line.bbox, gutters) }
    if !spanning.isEmpty {
        let bands = bandsAroundSpanning(lines, indices: indices, spanning: spanning, basis: basis)
        if bands.count >= 2, bands.allSatisfy({ $0.count < indices.count }) {
            return bands.flatMap { layoutLines(lines, indices: $0, basis: basis, tables: &tables) }
        }
    }
    let columns = columnBlocks(lines, indices: indices, basis: basis)
    if columns.count >= 2, columns.allSatisfy({ $0.count < indices.count }) {
        return columns.flatMap { layoutLines(lines, indices: $0, basis: basis, tables: &tables) }
    }
    return [indices]
}

/// A full-width line ends the band above it. Lines on that line's row stay
/// with it; everything above and below is cut again.
private func bandsAroundSpanning(
    _ lines: [Node],
    indices: [Int],
    spanning: [Int],
    basis: Double
) -> [[Int]] {
    let spanningSet = Set(spanning)
    var clusters: [[Int]] = []
    let ordered = spanning.sorted { lines[$0].line.bbox.y < lines[$1].line.bbox.y }
    for index in ordered {
        let box = lines[index].line.bbox
        if let last = clusters.indices.last {
            let minY = clusters[last].map { lines[$0].line.bbox.y }.min() ?? box.y
            let maxY = clusters[last].map { lines[$0].line.bbox.y + lines[$0].line.bbox.height }.max() ?? box.y
            let overlaps = box.y < maxY + basis * 0.5 && box.y + box.height > minY - basis * 0.5
            if overlaps {
                clusters[last].append(index)
                continue
            }
        }
        clusters.append([index])
    }
    struct Separator {
        var indices: [Int]
        var minY: Double
        var maxY: Double
    }
    let separators: [Separator] = clusters.map { group in
        let minY = group.map { lines[$0].line.bbox.y }.min() ?? 0
        let maxY = group.map { lines[$0].line.bbox.y + lines[$0].line.bbox.height }.max() ?? 0
        return Separator(indices: group, minY: minY, maxY: maxY)
    }
    var regions = Array(repeating: [Int](), count: separators.count * 2 + 1)
    for separator in separators.enumerated() {
        regions[separator.offset * 2 + 1].append(contentsOf: separator.element.indices)
    }
    for index in indices where !spanningSet.contains(index) {
        let box = lines[index].line.bbox
        let center = lines[index].centerY
        var placed = false
        for (offset, separator) in separators.enumerated() {
            if box.y < separator.maxY && box.y + box.height > separator.minY {
                regions[offset * 2 + 1].append(index)
                placed = true
                break
            }
            if center < separator.minY {
                regions[offset * 2].append(index)
                placed = true
                break
            }
        }
        if !placed {
            regions[regions.count - 1].append(index)
        }
    }
    return regions.filter { !$0.isEmpty }
}

/// Exact y-coverage, not a 4px bin. A bin was eating the header gap on the photo.
private func horizontalSlices(_ lines: [Node], indices: [Int], basis: Double) -> [[Int]] {
    guard indices.count >= 2 else { return [indices] }
    let intervals = indices.map { index -> (Double, Double) in
        let box = lines[index].line.bbox
        return (box.y, box.y + box.height)
    }.sorted { $0.0 < $1.0 }
    var gaps: [(Double, Double)] = []
    var mergedEnd = intervals[0].1
    var started = false
    var previousEnd = intervals[0].1
    for interval in intervals {
        if !started {
            started = true
            previousEnd = interval.1
            mergedEnd = interval.1
            continue
        }
        if interval.0 <= mergedEnd {
            mergedEnd = max(mergedEnd, interval.1)
            previousEnd = mergedEnd
        } else {
            if interval.0 - previousEnd >= basis {
                gaps.append((previousEnd, interval.0))
            }
            mergedEnd = interval.1
            previousEnd = interval.1
        }
    }
    if gaps.isEmpty { return [indices] }
    var slices = Array(repeating: [Int](), count: gaps.count + 1)
    for index in indices {
        let center = lines[index].centerY
        var slice = 0
        for gap in gaps {
            if center < gap.0 { break }
            if center < gap.1 {
                if center - gap.0 >= gap.1 - center { slice += 1 }
                break
            }
            slice += 1
        }
        slices[slice].append(index)
    }
    let nonempty = slices.filter { !$0.isEmpty }
    return nonempty.count >= 2 ? nonempty : [indices]
}

private func buildRows(_ lines: [Node], indices: [Int], basis: Double, gutters: [(Double, Double)]) -> [OCRRow] {
    let ordered = indices.sorted { lhs, rhs in
        if lines[lhs].centerY != lines[rhs].centerY { return lines[lhs].centerY < lines[rhs].centerY }
        return lines[lhs].line.bbox.x < lines[rhs].line.bbox.x
    }
    let spreadLimit = basis * 1.25
    var bands: [[Int]] = []
    for index in ordered {
        if let last = bands.indices.last, joinsBand(lines[index], members: bands[last], lines: lines, basis: basis, spreadLimit: spreadLimit),
           !stackedConflict(lines[index], members: bands[last], lines: lines, basis: basis) {
            bands[last].append(index)
        } else {
            bands.append([index])
        }
    }
    var rows: [OCRRow] = []
    for band in bands {
        let byX = band.sorted { lines[$0].line.bbox.x < lines[$1].line.bbox.x }
        var group: [Int] = []
        func flush() {
            if let row = makeRow(lines, group) {
                rows.append(row)
            }
            group = []
        }
        for index in byX {
            if !group.isEmpty, splitsOnGap(previous: group, next: index, lines: lines, gutters: gutters, basis: basis) {
                flush()
            }
            group.append(index)
        }
        flush()
    }
    return rows
}

/// Positive gaps wider than 2× median height start a new row. Touching or
/// overlapping fragments stay together. A gap stays together only when the
/// fragments come from different tiles and one of them is actually cut off
/// by its own tile edge. A column gutter in that gap splits anyway.
private func splitsOnGap(
    previous: [Int],
    next: Int,
    lines: [Node],
    gutters: [(Double, Double)],
    basis: Double
) -> Bool {
    var runRight = -Double.greatestFiniteMagnitude
    var owner = previous[0]
    for index in previous {
        let edge = lines[index].line.bbox.x + lines[index].line.bbox.width
        if edge >= runRight {
            runRight = edge
            owner = index
        }
    }
    let nextX = lines[next].line.bbox.x
    let gap = nextX - runRight
    if gap <= 0 { return false }
    if gapOverlapsGutter(runRight, nextX, gutters) { return true }
    if seamTruncated(lines[owner], lines[next], basis: basis) { return false }
    return gap > 2 * basis
}

private func gapOverlapsGutter(_ left: Double, _ right: Double, _ gutters: [(Double, Double)]) -> Bool {
    for gutter in gutters where min(right, gutter.1) - max(left, gutter.0) > 0 {
        return true
    }
    return false
}

/// The fragment was cropped: its right edge sits on its tile's right edge,
/// or its left edge sits on its tile's left edge. A box that merely starts
/// inside the overlap strip is not cropped.
private func seamTruncated(_ left: Node, _ right: Node, basis: Double) -> Bool {
    guard let leftTile = left.tile, let rightTile = right.tile, !framesEqual(leftTile, rightTile) else {
        return false
    }
    let tolerance = max(8, min(24, basis * 0.5))
    let leftEdge = left.line.bbox.x + left.line.bbox.width
    let leftCut = leftEdge >= leftTile.maxX - tolerance && leftEdge <= leftTile.maxX + tolerance
    let rightEdge = right.line.bbox.x
    let rightCut = rightEdge >= rightTile.x - tolerance && rightEdge <= rightTile.x + tolerance
    return leftCut || rightCut
}

/// Per-row gaps, not one projection of the whole band. A skewed photo makes
/// the shared overlap of those gaps narrower than any single row. Three
/// consecutive rows must each open a gap of at least 1× median height, the
/// overlap must be at least 0.5× that height, and the median of the three
/// widths must still be at least 1.5×. The run then grows while the x-range
/// stays empty. A gap whose both edges are tile-crop edges is not a vote.
private func splitVotedColumns(_ lines: [Node], indices: [Int], basis: Double) -> [[Int]]? {
    let bands = textRows(lines, indices: indices, basis: basis)
    guard bands.count >= 3 else { return nil }
    let bandGaps = bands.map { gapsInRow(lines, band: $0, basis: basis) }
    struct Seed {
        var x0: Double
        var x1: Double
        var start: Int
        var end: Int
        var medianWidth: Double
    }
    var seeds: [Seed] = []
    let minOverlap = max(8, 0.5 * basis)
    for index in 0...(bands.count - 3) {
        let widths = overlapSeeds(bandGaps[index], bandGaps[index + 1], bandGaps[index + 2], minOverlap: minOverlap, minMedian: 1.5 * basis)
        for item in widths {
            seeds.append(Seed(x0: item.0, x1: item.1, start: index, end: index + 2, medianWidth: item.2))
        }
    }
    guard !seeds.isEmpty else { return nil }
    var best: Seed?
    var bestSpan = 0
    for seed in seeds {
        var start = seed.start
        var end = seed.end
        while start > 0, rowLeavesGutterOpen(lines, band: bands[start - 1], x0: seed.x0, x1: seed.x1) {
            start -= 1
        }
        while end + 1 < bands.count, rowLeavesGutterOpen(lines, band: bands[end + 1], x0: seed.x0, x1: seed.x1) {
            end += 1
        }
        let span = end - start
        if best == nil || span > bestSpan || (span == bestSpan && seed.medianWidth > (best?.medianWidth ?? 0)) {
            best = Seed(x0: seed.x0, x1: seed.x1, start: start, end: end, medianWidth: seed.medianWidth)
            bestSpan = span
        }
    }
    guard let chosen = best, chosen.end - chosen.start >= 2 else { return nil }
    var spanIDs = Set<Int>()
    for band in chosen.start...chosen.end {
        for index in bands[band] {
            spanIDs.insert(index)
        }
    }
    var crossers: [Int] = []
    for index in spanIDs where coversGutter(lines[index].line.bbox, x0: chosen.x0, x1: chosen.x1) {
        crossers.append(index)
    }
    if Double(crossers.count) > 0.15 * Double(spanIDs.count) {
        return nil
    }
    let crosserSet = Set(crossers)
    var above: [Int] = []
    var below: [Int] = []
    var left: [Int] = []
    var right: [Int] = []
    let anchor = bands[chosen.start].map { lines[$0].centerY }.min() ?? 0
    for index in indices {
        if !spanIDs.contains(index) {
            if lines[index].centerY < anchor {
                above.append(index)
            } else {
                below.append(index)
            }
            continue
        }
        let box = lines[index].line.bbox
        let center = box.x + box.width / 2
        let onRight: Bool
        if crosserSet.contains(index) {
            onRight = center >= (chosen.x0 + chosen.x1) / 2
        } else {
            onRight = center > chosen.x1 || (center >= chosen.x0 && center - chosen.x0 > chosen.x1 - center)
        }
        if onRight {
            right.append(index)
        } else {
            left.append(index)
        }
    }
    let parts = [above, left, right, below].filter { !$0.isEmpty }
    if parts.count < 2 || parts.contains(where: { $0.count == indices.count }) {
        return nil
    }
    if left.isEmpty || right.isEmpty {
        return nil
    }
    return parts
}

private func textRows(_ lines: [Node], indices: [Int], basis: Double) -> [[Int]] {
    let ordered = indices.sorted { lines[$0].centerY < lines[$1].centerY }
    var rows: [[Int]] = []
    for index in ordered {
        if let last = rows.indices.last, joinsVotedRow(lines[index], members: rows[last], lines: lines, basis: basis) {
            rows[last].append(index)
        } else {
            rows.append([index])
        }
    }
    return rows
}

private func joinsVotedRow(_ node: Node, members: [Int], lines: [Node], basis: Double) -> Bool {
    let centers = members.map { lines[$0].centerY }.sorted()
    let median = centers[centers.count / 2]
    var minY = Double.greatestFiniteMagnitude
    var maxY = -Double.greatestFiniteMagnitude
    for member in members {
        let box = lines[member].line.bbox
        minY = min(minY, box.y)
        maxY = max(maxY, box.y + box.height)
    }
    let box = node.line.bbox
    let overlap = max(0, min(maxY, box.y + box.height) - max(minY, box.y))
    let shorter = min(box.height, maxY - minY)
    let spread = max(node.centerY, centers[centers.count - 1]) - min(node.centerY, centers[0])
    guard spread <= basis * 1.25 else { return false }
    if abs(node.centerY - median) <= 0.55 * basis { return true }
    return shorter > 0 && overlap >= 0.5 * shorter && abs(node.centerY - lines[members[0]].centerY) <= basis
}

private func gapsInRow(_ lines: [Node], band: [Int], basis: Double) -> [(Double, Double, Double)] {
    let ordered = band.sorted { lines[$0].line.bbox.x < lines[$1].line.bbox.x }
    var merged: [(Double, Double, Int)] = []
    for index in ordered {
        let box = lines[index].line.bbox
        if let last = merged.last, box.x <= last.1 + 0.5 {
            if box.x + box.width > last.1 {
                merged[merged.count - 1].1 = box.x + box.width
                merged[merged.count - 1].2 = index
            }
        } else {
            merged.append((box.x, box.x + box.width, index))
        }
    }
    var gaps: [(Double, Double, Double)] = []
    for index in 1..<merged.count {
        let gapL = merged[index - 1].1
        let gapR = merged[index].0
        let width = gapR - gapL
        guard width >= basis else { continue }
        let leftIndex = merged[index - 1].2
        let rightIndex = merged[index].2
        if bothEdgesCropped(lines[leftIndex], lines[rightIndex], basis: basis) {
            continue
        }
        gaps.append((gapL, gapR, width))
    }
    return gaps
}

private func bothEdgesCropped(_ left: Node, _ right: Node, basis: Double) -> Bool {
    guard let leftTile = left.tile, let rightTile = right.tile, !framesEqual(leftTile, rightTile) else {
        return false
    }
    let tolerance = max(8, min(24, basis * 0.5))
    let leftEdge = left.line.bbox.x + left.line.bbox.width
    let rightEdge = right.line.bbox.x
    let leftCut = leftEdge >= leftTile.maxX - tolerance && leftEdge <= leftTile.maxX + tolerance
    let rightCut = rightEdge >= rightTile.x - tolerance && rightEdge <= rightTile.x + tolerance
    return leftCut && rightCut
}

/// Intersection of one gap from each row. `medianWidth` is the median of those three widths.
private func overlapSeeds(
    _ first: [(Double, Double, Double)],
    _ second: [(Double, Double, Double)],
    _ third: [(Double, Double, Double)],
    minOverlap: Double,
    minMedian: Double
) -> [(Double, Double, Double)] {
    var found: [(Double, Double, Double)] = []
    for a in first {
        for b in second {
            let ab0 = max(a.0, b.0)
            let ab1 = min(a.1, b.1)
            if ab1 - ab0 < minOverlap { continue }
            for c in third {
                let x0 = max(ab0, c.0)
                let x1 = min(ab1, c.1)
                if x1 - x0 < minOverlap { continue }
                let widths = [a.2, b.2, c.2].sorted()
                let median = widths[1]
                if median < minMedian { continue }
                found.append((x0, x1, median))
            }
        }
    }
    return found
}

private func rowLeavesGutterOpen(_ lines: [Node], band: [Int], x0: Double, x1: Double) -> Bool {
    for index in band where coversGutter(lines[index].line.bbox, x0: x0, x1: x1) {
        return false
    }
    return true
}

private func coversGutter(_ box: BBox, x0: Double, x1: Double) -> Bool {
    let overlap = min(box.x + box.width, x1) - max(box.x, x0)
    return overlap > max(2, 0.15 * (x1 - x0))
}

/// Gutters are x-ranges no line box covers, wider than 1.5× median height,
/// inside a window at least three lines tall. A box that crosses a gutter
/// does not glue the columns together.
private func columnBlocks(_ lines: [Node], indices: [Int], basis: Double) -> [[Int]] {
    guard indices.count >= 2 else { return [indices] }
    var parent = Array(lines.indices)
    func find(_ index: Int) -> Int {
        var cursor = index
        while parent[cursor] != cursor {
            parent[cursor] = parent[parent[cursor]]
            cursor = parent[cursor]
        }
        return cursor
    }
    func unite(_ lhs: Int, _ rhs: Int) {
        let left = find(lhs)
        let right = find(rhs)
        if left != right { parent[left] = right }
    }
    let gutterWidth = 1.5 * basis
    let span = 3 * basis
    let centers = indices.map { lines[$0].centerY }
    guard let y0 = centers.min(), let y1 = centers.max() else { return [indices] }
    var sawGutter = false
    var found: [(Double, Double)] = []
    var y = y0
    while y <= y1 {
        let members = indices.filter { lines[$0].centerY >= y && lines[$0].centerY <= y + span }
        if members.count >= 3 {
            let gutters = windowGutters(lines, members: members, minWidth: gutterWidth)
            // A window with no gutter must not glue every line into one component.
            // That was joining the photo's middle and right columns whenever one
            // long box narrowed the projection below the gutter threshold.
            if !gutters.isEmpty {
                sawGutter = true
                found.append(contentsOf: gutters)
                var groups: [Int: [Int]] = [:]
                for index in members {
                    if let segment = columnSegment(lines[index].line.bbox, gutters: gutters) {
                        groups[segment, default: []].append(index)
                    }
                }
                for group in groups.values where group.count >= 2 {
                    let root = group[0]
                    for index in group.dropFirst() {
                        unite(root, index)
                    }
                }
            }
        }
        y += basis
    }
    if !sawGutter { return [indices] }
    var components: [Int: [Int]] = [:]
    for index in indices {
        components[find(index), default: []].append(index)
    }
    return orderReading(Array(components.values), lines: lines, gutters: mergeGaps(found), basis: basis)
}

private func localGutters(_ lines: [Node], indices: [Int], basis: Double) -> [(Double, Double)] {
    guard indices.count >= 3 else { return [] }
    let gutterWidth = 1.5 * basis
    let span = 3 * basis
    let centers = indices.map { lines[$0].centerY }
    guard let y0 = centers.min(), let y1 = centers.max() else { return [] }
    var found: [(Double, Double)] = []
    var y = y0
    while y <= y1 {
        let members = indices.filter { lines[$0].centerY >= y && lines[$0].centerY <= y + span }
        if members.count >= 3 {
            found.append(contentsOf: windowGutters(lines, members: members, minWidth: gutterWidth))
        }
        y += basis
    }
    return mergeGaps(found)
}

private func windowGutters(_ lines: [Node], members: [Int], minWidth: Double) -> [(Double, Double)] {
    let minX = members.map { lines[$0].line.bbox.x }.min() ?? 0
    let maxX = members.map { lines[$0].line.bbox.x + lines[$0].line.bbox.width }.max() ?? 0
    let content = max(1, maxX - minX)
    let narrow = members.filter { lines[$0].line.bbox.width < 0.6 * content }
    let projected = narrow.count >= 3 ? narrow : members
    return xGutters(lines, indices: projected, minX: minX, maxX: maxX, minWidth: minWidth)
}

/// Full-width boxes (they cross a gutter) end a band: they stay on their own
/// strip, ordered by y, and the columns beside them do not absorb them.
private func orderReading(_ groups: [[Int]], lines: [Node], gutters: [(Double, Double)], basis: Double) -> [[Int]] {
    struct Item {
        var indices: [Int]
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
        var barrier: Bool
    }
    var items: [Item] = groups.map { group in
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for index in group {
            let box = lines[index].line.bbox
            minX = min(minX, box.x)
            minY = min(minY, box.y)
            maxX = max(maxX, box.x + box.width)
            maxY = max(maxY, box.y + box.height)
        }
        let box = BBox(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        return Item(
            indices: group,
            minX: minX,
            minY: minY,
            maxX: maxX,
            maxY: maxY,
            barrier: crossesGutter(box, gutters)
        )
    }
    items.sort { $0.minY < $1.minY }
    var strips: [[Item]] = []
    for item in items {
        if item.barrier {
            strips.append([item])
            continue
        }
        if let last = strips.indices.last {
            if strips[last].contains(where: \.barrier) {
                strips.append([item])
                continue
            }
            let stripTop = strips[last].map(\.minY).min() ?? item.minY
            let stripMax = strips[last].map(\.maxY).max() ?? item.maxY
            let overlap = min(stripMax, item.maxY) - max(stripTop, item.minY)
            // Side by side means they start on the same band. A card whose top
            // is far below does not join a column that began higher up.
            if item.minY <= stripTop + basis * 2, overlap > 0 {
                strips[last].append(item)
                continue
            }
        }
        strips.append([item])
    }
    var ordered: [[Int]] = []
    for strip in strips {
        for item in strip.sorted(by: { $0.minX < $1.minX }) {
            ordered.append(item.indices)
        }
    }
    return ordered
}

private func crossesGutter(_ box: BBox, _ gutters: [(Double, Double)]) -> Bool {
    for gutter in gutters where box.x < gutter.0 && box.x + box.width > gutter.1 {
        return true
    }
    return false
}

private func mergeGaps(_ gaps: [(Double, Double)]) -> [(Double, Double)] {
    let sorted = gaps.sorted { $0.0 < $1.0 }
    var merged: [(Double, Double)] = []
    for gap in sorted {
        if let last = merged.last, gap.0 <= last.1 {
            merged[merged.count - 1].1 = max(last.1, gap.1)
        } else {
            merged.append(gap)
        }
    }
    return merged
}

private func xGutters(_ lines: [Node], indices: [Int], minX: Double, maxX: Double, minWidth: Double) -> [(Double, Double)] {
    let intervals = indices.map { index -> (Double, Double) in
        let box = lines[index].line.bbox
        return (box.x, box.x + box.width)
    }.sorted { $0.0 < $1.0 }
    var merged: [(Double, Double)] = []
    for interval in intervals {
        if let last = merged.last, interval.0 <= last.1 {
            merged[merged.count - 1].1 = max(last.1, interval.1)
        } else {
            merged.append(interval)
        }
    }
    var gutters: [(Double, Double)] = []
    for index in 1..<merged.count {
        let gapL = merged[index - 1].1
        let gapR = merged[index].0
        if gapR - gapL >= minWidth, gapL > minX, gapR < maxX {
            gutters.append((gapL, gapR))
        }
    }
    return gutters
}

/// nil when the box crosses a gutter or its center sits inside one.
private func columnSegment(_ box: BBox, gutters: [(Double, Double)]) -> Int? {
    for gutter in gutters {
        if box.x < gutter.0 && box.x + box.width > gutter.1 {
            return nil
        }
    }
    let center = box.x + box.width / 2
    var segment = 0
    for gutter in gutters {
        if center > gutter.1 {
            segment += 1
        } else if center >= gutter.0 {
            return nil
        }
    }
    return segment
}

private func blockBox(_ lines: [Node], rows: [OCRRow], range: Range<Int>) -> OCRBlock? {
    guard let first = range.first else { return nil }
    var box = rows[first].bbox
    var rowIndices: [Int] = []
    for index in range {
        box = unionBox(box, rows[index].bbox)
        rowIndices.append(index)
    }
    _ = lines
    return OCRBlock(bbox: box, rowIndices: rowIndices)
}

/// Transitive within the current band only. A fragment joins when its center
/// is within 0.5× the median line height of the band (a 50% height overlap
/// alone is not enough) and the band's center spread stays ≤ 1.25× that median.
private func joinsBand(_ node: Node, members: [Int], lines: [Node], basis: Double, spreadLimit: Double) -> Bool {
    guard let first = members.first else { return false }
    var minY = lines[first].line.bbox.y
    var maxY = minY + lines[first].line.bbox.height
    var minCenter = lines[first].centerY
    var maxCenter = minCenter
    var centers: [Double] = []
    centers.reserveCapacity(members.count)
    for member in members {
        let box = lines[member].line.bbox
        minY = min(minY, box.y)
        maxY = max(maxY, box.y + box.height)
        let center = lines[member].centerY
        centers.append(center)
        minCenter = min(minCenter, center)
        maxCenter = max(maxCenter, center)
    }
    let sorted = centers.sorted()
    let bandCenter = sorted[sorted.count / 2]
    let anchor = centers[0]
    let box = node.line.bbox
    let center = node.centerY
    let overlap = max(0, min(maxY, box.y + box.height) - max(minY, box.y))
    let unionHeight = maxY - minY
    let minHeight = min(box.height, unionHeight)
    let overlapRatio = minHeight > 0 ? overlap / minHeight : 0
    let closeToCenter = abs(center - bandCenter) <= 0.5 * basis
    // Tall boxes on a paragraph page overlap the next line by half their height
    // while the centers are still a full line apart. That is a new row.
    let overlapsBand = overlapRatio >= 0.5 && abs(center - anchor) <= 0.5 * basis
    let spread = max(maxCenter, center) - min(minCenter, center)
    return (closeToCenter || overlapsBand) && spread <= spreadLimit
}

private func makeRow(_ lines: [Node], _ indices: [Int], separator: String? = nil) -> OCRRow? {
    guard !indices.isEmpty else { return nil }
    let order = indices.sorted { lhs, rhs in
        let leftX = lines[lhs].line.bbox.x
        let rightX = lines[rhs].line.bbox.x
        if leftX != rightX { return leftX < rightX }
        return lines[lhs].line.bbox.width > lines[rhs].line.bbox.width
    }
    var text = ""
    var textKey = ""
    var coverText = ""
    var emitted: [(Double, Double)] = []
    for index in order {
        let part = lines[index]
        let raw = part.line.text
        let box = part.line.bbox
        let chars = Array(raw)
        let count = chars.count
        if count == 0 { continue }
        let charWidth = box.width / Double(count)
        var cut = 0
        while cut < count {
            let center = box.x + (Double(cut) + 0.5) * charWidth
            if emitted.contains(where: { center >= $0.0 && center <= $0.1 }) {
                cut += 1
            } else {
                break
            }
        }
        let overlapped = emitted.contains { start, end in
            box.x < end && box.x + box.width > start
        }
        var piece = String(chars[cut...])
        if cut == count {
            let unique = hasUniqueMarker(raw, cover: coverText)
            if part.key.count > 2, !textKey.contains(part.key), unique {
                piece = raw
            } else {
                piece = ""
            }
        }
        piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        var aligned = false
        if overlapped, !text.isEmpty, cut > 0, cut < count,
           let seam = seamAlign(text: text, raw: raw, headLimit: cut + 8, cut: cut) {
            text = seam.text
            textKey = LineMerge.matchKey(text)
            piece = seam.piece.trimmingCharacters(in: .whitespacesAndNewlines)
            aligned = true
        }
        if !aligned, !piece.isEmpty, overlapped, !textKey.isEmpty, cut > 0, cut < count {
            let pieceKey = LineMerge.matchKey(piece)
            let shared = sharedAffixCount(textKey, pieceKey, minimum: 2, cap: 6)
            if shared >= 2 {
                piece = dropFoldedPrefix(piece, foldedCount: shared)
            }
        }
        if cut < count || !piece.isEmpty {
            emitted.append((box.x, box.x + box.width))
        }
        if !piece.isEmpty {
            if text.isEmpty {
                text = piece
            } else if let separator {
                text += separator + piece
            } else if let last = text.last, let first = piece.first, isCJK(last), isCJK(first) {
                text += piece
            } else {
                text += " " + piece
            }
            textKey = LineMerge.matchKey(text)
            coverText += piece
        }
    }
    if text.isEmpty { return nil }
    var box = lines[indices[0]].line.bbox
    var confidence = 0.0
    for index in indices {
        let part = lines[index].line
        box = unionBox(box, part.bbox)
        confidence += part.confidence
    }
    confidence /= Double(indices.count)
    let ordered = indices.sorted { lines[$0].line.bbox.x < lines[$1].line.bbox.x }
    return OCRRow(
        text: text,
        bbox: box,
        confidence: (confidence * 10000).rounded() / 10000,
        lineIndices: ordered
    )
}

/// `L`/`E` plus at least three digits. A fully covered fragment is kept only
/// when it carries one of these that the text already emitted does not.
private func markerIDs(_ text: String) -> Set<String> {
    var found: Set<String> = []
    let chars = Array(text)
    var index = 0
    while index < chars.count {
        let character = chars[index]
        if character == "L" || character == "E" {
            var end = index + 1
            while end < chars.count, isASCIIDigit(chars[end]) {
                end += 1
            }
            if end - index - 1 >= 3 {
                found.insert(String(chars[index..<end]))
            }
        }
        index += 1
    }
    return found
}

private func hasUniqueMarker(_ text: String, cover: String) -> Bool {
    let markers = markerIDs(text)
    if markers.isEmpty { return false }
    let coverMarkers = markerIDs(cover)
    for marker in markers where !coverMarkers.contains(marker) {
        return true
    }
    return false
}

private func isASCIIDigit(_ character: Character) -> Bool {
    guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value else {
        return false
    }
    return (48...57).contains(value)
}

private func isCJK(_ character: Character) -> Bool {
    for scalar in character.unicodeScalars {
        let value = scalar.value
        if (0x3400...0x9FFF).contains(value) || (0xF900...0xFAFF).contains(value) { return true }
        if (0x3040...0x30FF).contains(value) || (0xAC00...0xD7AF).contains(value) { return true }
    }
    return false
}

private struct FoldPiece {
    var folded: String
    var end: String.Index
}

private func foldPieces(_ text: String) -> [FoldPiece] {
    var pieces: [FoldPiece] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(after: index)
        let character = text[index]
        index = next
        if character.isWhitespace || character.isNewline { continue }
        let folded = String(character).precomposedStringWithCompatibilityMapping.lowercased()
        if folded.isEmpty || folded.allSatisfy({ $0.isWhitespace }) { continue }
        pieces.append(FoldPiece(folded: folded, end: next))
    }
    return pieces
}

/// `foldedCount` is a length in the normalized key. The cut lands on the
/// original character that consumed that prefix, so spaces stay put.
private func dropFoldedPrefix(_ text: String, foldedCount: Int) -> String {
    guard foldedCount > 0 else {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var remaining = foldedCount
    var cut = text.startIndex
    for piece in foldPieces(text) {
        if remaining <= 0 { break }
        cut = piece.end
        remaining -= piece.folded.count
    }
    return String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Longest suffix/prefix match in `minimum...cap`. The cap stops a repeated
/// filler phrase on the far side of a seam from being eaten after the geometric cut.
private func sharedAffixCount(_ left: String, _ right: String, minimum: Int, cap: Int) -> Int {
    let lhs = Array(left)
    let rhs = Array(right)
    let maxCount = min(lhs.count, rhs.count, cap)
    guard maxCount >= minimum else { return 0 }
    var count = maxCount
    while count >= minimum {
        var matches = true
        for index in 0..<count {
            if lhs[lhs.count - count + index] != rhs[index] {
                matches = false
                break
            }
        }
        if matches { return count }
        count -= 1
    }
    return 0
}

private func similarity(_ lhs: String, _ rhs: String) -> Double {
    if lhs == rhs { return 1 }
    let denom = max(lhs.count, rhs.count, 1)
    if denom > 800 { return 0 }
    return 1 - Double(levenshtein(lhs, rhs)) / Double(denom)
}

private func levenshtein(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs)
    let b = Array(rhs)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

private func medianHeight(_ lines: [OCRLine]) -> Double {
    let heights = lines.map(\.bbox.height).filter { $0 > 0 }.sorted()
    guard !heights.isEmpty else { return 16 }
    return heights[heights.count / 2]
}

private func sameBand(_ lhs: BBox, _ rhs: BBox, median: Double) -> Bool {
    let overlap = verticalOverlap(lhs, rhs)
    let minHeight = min(lhs.height, rhs.height)
    if minHeight > 0, overlap / minHeight >= 0.5 { return true }
    let leftCenter = lhs.y + lhs.height / 2
    let rightCenter = rhs.y + rhs.height / 2
    let basis = median > 0 ? median : max(lhs.height, rhs.height, 1)
    return abs(leftCenter - rightCenter) <= 0.5 * basis
}

private func area(_ box: BBox) -> Double {
    max(0, box.width) * max(0, box.height)
}

private func intersection(_ lhs: BBox, _ rhs: BBox) -> Double {
    let x1 = max(lhs.x, rhs.x)
    let y1 = max(lhs.y, rhs.y)
    let x2 = min(lhs.x + lhs.width, rhs.x + rhs.width)
    let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
    return max(0, x2 - x1) * max(0, y2 - y1)
}

private func verticalOverlap(_ lhs: BBox, _ rhs: BBox) -> Double {
    let y1 = max(lhs.y, rhs.y)
    let y2 = min(lhs.y + lhs.height, rhs.y + rhs.height)
    return max(0, y2 - y1)
}

private func iou(_ lhs: BBox, _ rhs: BBox) -> Double {
    let inter = intersection(lhs, rhs)
    let union = area(lhs) + area(rhs) - inter
    return union > 0 ? inter / union : 0
}

private func boxContainment(_ lhs: BBox, _ rhs: BBox) -> Double {
    let inter = intersection(lhs, rhs)
    let smaller = min(area(lhs), area(rhs))
    return smaller > 0 ? inter / smaller : 0
}

private func xOverlap(_ lhs: BBox, _ rhs: BBox) -> Double {
    min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x)
}

private func unionBox(_ lhs: BBox, _ rhs: BBox) -> BBox {
    let x1 = min(lhs.x, rhs.x)
    let y1 = min(lhs.y, rhs.y)
    let x2 = max(lhs.x + lhs.width, rhs.x + rhs.width)
    let y2 = max(lhs.y + lhs.height, rhs.y + rhs.height)
    return BBox(
        x: rounded2(x1),
        y: rounded2(y1),
        width: rounded2(x2 - x1),
        height: rounded2(y2 - y1)
    )
}

private func rounded2(_ value: Double) -> Double {
    (value * 100).rounded() / 100
}

private func framesEqual(_ lhs: TileFrame, _ rhs: TileFrame) -> Bool {
    abs(lhs.x - rhs.x) < 0.5 && abs(lhs.y - rhs.y) < 0.5
        && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
}

private func overlapStrips(_ tiles: [TileFrame?]) -> [Strip] {
    var unique: [TileFrame] = []
    for tile in tiles {
        guard let tile else { continue }
        if !unique.contains(where: { framesEqual($0, tile) }) {
            unique.append(tile)
        }
    }
    guard unique.count >= 2 else { return [] }
    var strips: [Strip] = []
    for i in unique.indices {
        for j in (i + 1)..<unique.count {
            let a = unique[i]
            let b = unique[j]
            let xo = min(a.maxX, b.maxX) - max(a.x, b.x)
            let yo = min(a.maxY, b.maxY) - max(a.y, b.y)
            guard xo > 1, yo > 1 else { continue }
            let sideBySide = yo >= 0.5 * min(a.height, b.height) && xo <= 0.8 * min(a.width, b.width)
            let stacked = xo >= 0.5 * min(a.width, b.width) && yo <= 0.8 * min(a.height, b.height)
            if sideBySide || stacked {
                strips.append(Strip(
                    x0: max(a.x, b.x),
                    y0: max(a.y, b.y),
                    x1: min(a.maxX, b.maxX),
                    y1: min(a.maxY, b.maxY),
                    sideBySide: sideBySide,
                    tileA: a,
                    tileB: b
                ))
            }
        }
    }
    return strips
}

private func coverage(_ box: BBox, _ strip: Strip) -> Double {
    let xo = min(box.x + box.width, strip.x1) - max(box.x, strip.x0)
    let yo = min(box.y + box.height, strip.y1) - max(box.y, strip.y0)
    guard xo > 0, yo > 0 else { return 0 }
    if strip.sideBySide {
        return box.width > 0 ? xo / box.width : 0
    }
    return box.height > 0 ? yo / box.height : 0
}

private func tileMatches(_ tile: TileFrame?, _ frame: TileFrame) -> Bool {
    guard let tile else { return false }
    return framesEqual(tile, frame)
}

/// At least 80% of the line lies in one overlap strip of its own tile.
private func localStrip(_ box: BBox, tile: TileFrame?, strips: [Strip]) -> Int? {
    guard let tile else { return nil }
    var best: (Int, Double)?
    for index in strips.indices {
        let strip = strips[index]
        guard tileMatches(tile, strip.tileA) || tileMatches(tile, strip.tileB) else { continue }
        let fraction = coverage(box, strip)
        if fraction >= 0.8, best == nil || fraction > best!.1 {
            best = (index, fraction)
        }
    }
    return best?.0
}

/// Fully inside one tile and not in an overlap strip. Untagged lines and a
/// single-tile page are not interior, so same-position duplicates still collapse.
private func isInterior(_ box: BBox, tile: TileFrame?, strips: [Strip], stripID: Int?) -> Bool {
    guard let tile, strips.count >= 1, stripID == nil else { return false }
    let centerX = box.x + box.width / 2
    let centerY = box.y + box.height / 2
    guard centerX >= tile.x - 1, centerX <= tile.maxX + 1, centerY >= tile.y - 1, centerY <= tile.maxY + 1 else {
        return false
    }
    for strip in strips where coverage(box, strip) >= 0.2 {
        return false
    }
    return true
}

/// Distance of the box center from this tile's seam edge. Larger means the
/// observation sits farther inside the tile and is the copy to keep.
private func seamDistance(_ box: BBox, tile: TileFrame?, strip: Strip) -> Double {
    guard let tile else { return 0 }
    if strip.sideBySide {
        let leftTile = strip.tileA.x <= strip.tileB.x ? strip.tileA : strip.tileB
        let center = box.x + box.width / 2
        if framesEqual(tile, leftTile) {
            return (tile.x + tile.width) - center
        }
        return center - tile.x
    }
    let topTile = strip.tileA.y <= strip.tileB.y ? strip.tileA : strip.tileB
    let center = box.y + box.height / 2
    if framesEqual(tile, topTile) {
        return (tile.y + tile.height) - center
    }
    return center - tile.y
}


// MARK: - Grid tables

/// A grid table: at least three text rows whose cells fall into at least three
/// shared columns, one cell per column, with short cells. Three columns of
/// running prose also line up row by row, so long cells (median above
/// `tableMaxCellChars`) never count as a table.
let tableMaxCellChars = 16

private func isTable(_ lines: [Node], indices: [Int], basis: Double) -> Bool {
    guard indices.count >= 9 else { return false }
    let bands = textRows(lines, indices: indices, basis: basis)
    let multi = bands.filter { $0.count >= 3 }
    guard multi.count >= 3 else { return false }
    let columns = tableColumns(lines, rows: multi)
    guard columns.count >= 3 else { return false }
    var alignedRows = 0
    var alignedLines = 0
    var cellChars: [Int] = []
    for row in multi {
        var used = Set<Int>()
        var ok = true
        for index in row {
            guard let column = tableColumn(lines[index].line.bbox, columns) , !used.contains(column) else {
                ok = false
                break
            }
            used.insert(column)
        }
        if ok && used.count >= 3 {
            alignedRows += 1
            alignedLines += row.count
            for index in row {
                cellChars.append(lines[index].key.count)
            }
        }
    }
    guard alignedRows >= 3, Double(alignedRows) >= 0.7 * Double(multi.count) else { return false }
    guard Double(alignedLines) >= 0.6 * Double(indices.count) else { return false }
    let sortedChars = cellChars.sorted()
    let medianChars = sortedChars.isEmpty ? 0 : sortedChars[sortedChars.count / 2]
    return medianChars <= tableMaxCellChars
}

/// Column x-ranges: the union of cell extents over the multi-cell rows.
private func tableColumns(_ lines: [Node], rows: [[Int]]) -> [(Double, Double)] {
    var spans: [(Double, Double)] = []
    for row in rows {
        for index in row {
            let box = lines[index].line.bbox
            spans.append((box.x, box.x + box.width))
        }
    }
    spans.sort { $0.0 < $1.0 }
    var merged: [(Double, Double)] = []
    for span in spans {
        if let last = merged.last, span.0 <= last.1 {
            merged[merged.count - 1].1 = max(last.1, span.1)
        } else {
            merged.append(span)
        }
    }
    return merged
}

private func tableColumn(_ box: BBox, _ columns: [(Double, Double)]) -> Int? {
    let center = box.x + box.width / 2
    for (offset, column) in columns.enumerated() where center >= column.0 && center <= column.1 {
        return offset
    }
    return nil
}

/// Rows across the whole table, cells left to right joined by a tab. No gap
/// or gutter splits a table row.
private func buildTableRows(_ lines: [Node], indices: [Int], basis: Double) -> [OCRRow] {
    let ordered = indices.sorted { lhs, rhs in
        if lines[lhs].centerY != lines[rhs].centerY { return lines[lhs].centerY < lines[rhs].centerY }
        return lines[lhs].line.bbox.x < lines[rhs].line.bbox.x
    }
    let spreadLimit = basis * 1.25
    var bands: [[Int]] = []
    for index in ordered {
        if let last = bands.indices.last, joinsBand(lines[index], members: bands[last], lines: lines, basis: basis, spreadLimit: spreadLimit),
           !stackedConflict(lines[index], members: bands[last], lines: lines, basis: basis) {
            bands[last].append(index)
        } else {
            bands.append([index])
        }
    }
    return bands.compactMap { makeRow(lines, $0, separator: "\t") }
}


// MARK: - Seam reconciliation

/// Two observations of one text line that overlap in x (tile seam, slanted
/// photo) are stitched on their longest shared run of at least three
/// non-space characters, searched in the last 24 characters already emitted
/// and the first `headLimit` characters of the new piece. The per-character
/// geometric cut misplaces the join on a slanted line ("和四种： 和四种转换").
/// At most three characters may follow the match in the emitted text; they
/// are dropped only when all are punctuation or symbols. The run must occur
/// exactly once on each side, and the stitched join may move at most four
/// characters from the geometric cut (repeating text aligns a period away).
private func seamAlign(text: String, raw: String, headLimit: Int, cut: Int) -> (text: String, piece: String)? {
    let t = Array(text)
    let r = Array(raw)
    let tTail = Array(t.indices.filter { !t[$0].isWhitespace }.suffix(24))
    let rHead = Array(r.indices.filter { !r[$0].isWhitespace }.prefix(max(0, headLimit)))
    guard tTail.count >= 3, rHead.count >= 3 else { return nil }
    func norm(_ c: Character) -> String { String(c).precomposedStringWithCompatibilityMapping.lowercased() }
    let a = tTail.map { norm(t[$0]) }
    let b = rHead.map { norm(r[$0]) }
    var best = 0
    var endA = 0
    var endB = 0
    var prev = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        var cur = Array(repeating: 0, count: b.count + 1)
        for j in 1...b.count where a[i - 1] == b[j - 1] {
            cur[j] = prev[j - 1] + 1
            if cur[j] >= best {
                best = cur[j]
                endA = i
                endB = j
            }
        }
        prev = cur
    }
    guard best >= 3, a.count - endA <= 3 else { return nil }
    // Repeating text ("金额 100 元 金额 100 元") matches at several offsets;
    // an ambiguous run would drop real text, so keep the geometric cut then.
    let run = Array(a[(endA - best)..<endA])
    func occurrences(_ hay: [String]) -> Int {
        guard hay.count >= run.count else { return 0 }
        return (0...(hay.count - run.count)).filter { Array(hay[$0..<($0 + run.count)]) == run }.count
    }
    guard occurrences(b) == 1, occurrences(a) == 1 else { return nil }
    // Trailing punctuation after the match is seam junk ("和四种：") and goes.
    // Letters, digits or CJK after it are real text that the new piece only
    // partly repeats; they stay.
    let trailing = t[(tTail[endA - 1] + 1)...].filter { !$0.isWhitespace }
    let junk = trailing.allSatisfy { $0.isPunctuation || $0.isSymbol }
    let keep = junk ? tTail[endA - 1] + 1 : t.count
    // Kept trailing text may stand for as many characters of the new piece
    // ("先週后" + "先调后买": the match is "先", "週后" covers "调后") or be a
    // misread extra ("互联发1" + "互联发货组"). Take whichever join lands
    // nearer the geometric cut; on a tie keep the piece whole.
    var start = rHead[endB - 1] + 1
    if !junk {
        var skipped = start
        var skip = trailing.count
        while skip > 0, skipped < r.count {
            if !r[skipped].isWhitespace { skip -= 1 }
            skipped += 1
        }
        if abs(skipped - cut) < abs(start - cut) { start = skipped }
    }
    guard abs(start - cut) <= 4 else { return nil }
    return (String(t[..<keep]), start < r.count ? String(r[start...]) : "")
}

/// A full-height fragment does not join a row band when it sits under a
/// different full-height line of that band: at least half of the narrower
/// width shared in x, centers at least a quarter line apart, texts unequal,
/// and both from one Vision pass or one tile column (side-by-side tiles only
/// when the overlap is wider than their seam strip plus a line).
/// On a slanted photo the right-tile copy of a line otherwise joins the line
/// above and its text is trimmed away as covered.
private func stackedConflict(_ node: Node, members: [Int], lines: [Node], basis: Double) -> Bool {
    let box = node.line.bbox
    guard box.height >= 0.6 * basis else { return false }
    for member in members {
        let other = lines[member]
        let otherBox = other.line.bbox
        guard otherBox.height >= 0.6 * basis else { continue }
        let minWidth = min(box.width, otherBox.width)
        let overlap = xOverlap(box, otherBox)
        guard minWidth > 0, overlap >= 0.5 * minWidth else { continue }
        guard abs(node.centerY - other.centerY) >= 0.25 * basis else { continue }
        if textsMatch(node.key, other.key) { continue }
        // Halves of one line cut by side-by-side tiles overlap only inside
        // the shared seam strip. Tiles stacked in one column each see the
        // whole line, so stacked boxes there are two different lines.
        if let tileA = node.tile, let tileB = other.tile, abs(tileA.x - tileB.x) > 0.5 {
            let strip = max(0, min(tileA.maxX, tileB.maxX) - max(tileA.x, tileB.x))
            if overlap <= strip + basis { continue }
        }
        return true
    }
    return false
}
