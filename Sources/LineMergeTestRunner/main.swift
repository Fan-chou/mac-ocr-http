#if canImport(LineMergeCore)
import LineMergeCore
#endif
import Foundation

private func line(
    _ text: String,
    _ x: Double,
    _ y: Double,
    _ w: Double,
    _ h: Double,
    _ confidence: Double
) -> OCRLine {
    OCRLine(
        text: text,
        confidence: confidence,
        bbox: BBox(x: x, y: y, width: w, height: h),
        quad: Quad(
            topLeft: Point(x: x, y: y),
            topRight: Point(x: x + w, y: y),
            bottomRight: Point(x: x + w, y: y + h),
            bottomLeft: Point(x: x, y: y + h)
        )
    )
}

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}

@main
enum LineMergeTestMain {
    static func main() {
        run()
        fputs("line-merge tests ok\n", stdout)
    }
}

private func run() {
    let yuan = LineMerge.matchKey("100 元")
    check(yuan == LineMerge.matchKey("100元"), "spaces \(yuan)")
    check(yuan == LineMerge.matchKey("１００元"), "fullwidth \(LineMerge.matchKey("１００元"))")
    check(yuan == LineMerge.matchKey("100\n元"), "newline")
    check(LineMerge.matchKey("Invoice") == LineMerge.matchKey("invoice"), "case")

    let spaced = LineMerge.assemble([
        line("100 元", 0, 0, 80, 16, 0.95),
        line("100元", 0, 0, 80, 16, 0.40),
    ])
    check(spaced.lines.count == 1, "whitespace dup lines \(spaced.lines.count)")
    check(spaced.lines[0].text == "100 元", "kept higher confidence spelling \(spaced.lines[0].text)")
    check(spaced.rows.count == 1 && spaced.text == "100 元", "whitespace dup row \(spaced.text)")

    let phrase = "发票金额 Invoice 100 元 END"
    let repeated = LineMerge.assemble([
        line(phrase, 0, 0, 800, 18, 0.9),
        line(phrase, 0, 40, 800, 18, 0.9),
    ])
    check(repeated.lines.count == 2 && repeated.rows.count == 2, "different rows \(repeated.lines.count) \(repeated.rows.count)")
    check(repeated.text == "\(phrase)\n\(phrase)", "repeated text \(repeated.text)")

    let columns = LineMerge.assemble([
        line("Right", 200, 0, 40, 16, 0.9),
        line("Left", 0, 0, 40, 16, 0.9),
    ])
    check(columns.rows.count == 2 && columns.text == "Left\nRight", "columns \(columns.text)")

    check(shinjitaiToSimplified("発気満対実") == "发气满对实", "shinjitai \(shinjitaiToSimplified("発気満対実"))")
    check(shinjitaiToSimplified("あア発") == "あア发", "kana left alone \(shinjitaiToSimplified("あア発"))")
    check(shinjitaiToSimplified("浄済") == "净济", "浄済 \(shinjitaiToSimplified("浄済"))")

    seamStitch()
    stripDuplicate()
    touchingFragments()
    coveredSeamScrap()
    seamGapStays()
    gutterBeatsSeam()
    timing()
    fixturePages()
    columnReadingOrder()
    stackedParagraphCenter()
    tilePolicy()
    openAICompatTests()
    debugCaptureTests()
}

/// Two ~2000px fragments of one repetitive row, sharing only the 256px tile overlap.
/// The normalized texts are similar enough that a loose x-overlap rule would drop one.
private func seamStitch() {
    let piece = "发票金额 Invoice 100 元 "
    let leftText = "L001 " + String(repeating: piece, count: 6)
    let rightText = String(repeating: piece, count: 6) + "E001"
    let leftTile = TileFrame(x: 0, y: 0, width: 2048, height: 2048)
    let rightTile = TileFrame(x: 1792, y: 0, width: 2048, height: 2048)
    let page = LineMerge.assemble(
        [
            line(leftText, 40, 40, 2000, 16, 0.5),
            line(rightText, 1800, 40, 2000, 16, 0.5),
        ],
        tiles: [leftTile, rightTile]
    )
    check(page.lines.count == 2, "seam kept both fragments \(page.lines.count)")
    check(page.rows.count == 1, "seam one row \(page.rows.count) \(page.text)")
    let row = page.rows[0].text
    check(row.contains("L001"), "seam missing L001 \(row)")
    check(row.contains("E001"), "seam missing E001 \(row)")
    check(row.components(separatedBy: "L001").count == 2, "L001 once \(row)")
    check(row.components(separatedBy: "E001").count == 2, "E001 once \(row)")
    let token = LineMerge.matchKey(piece)
    let key = LineMerge.matchKey(row)
    var count = 0
    var search = key.startIndex
    while let range = key.range(of: token, range: search..<key.endIndex) {
        count += 1
        search = range.upperBound
    }
    // Geometry keeps the part of the right box past the 240px overlap.
    // The synthetic text repeats the phrase across that uncovered span, so the
    // count is 11 rather than 6. E001 is still on the row, and the overlap
    // itself is not a second full copy (12).
    check(count == 11, "overlap phrase count \(count) in \(row)")
    check(count < 12, "overlap was not trimmed \(count)")
}

/// Same whitespace-only text inside the overlap strip. Keep the copy farther from its tile edge.
private func stripDuplicate() {
    let leftTile = TileFrame(x: 0, y: 0, width: 2048, height: 2048)
    let rightTile = TileFrame(x: 1792, y: 0, width: 2048, height: 2048)
    let page = LineMerge.assemble(
        [
            line("100元", 1820, 10, 80, 16, 0.99),
            line("100 元", 1800, 10, 80, 16, 0.5),
        ],
        tiles: [rightTile, leftTile]
    )
    check(page.lines.count == 1, "strip dup lines \(page.lines.count) \(page.text)")
    check(page.lines[0].text == "100 元", "kept the copy farther from the seam \(page.lines[0].text)")
}

/// A short fragment nested inside a longer one must not open a column gap.
/// The next fragment touches the long box, so the running right edge is what counts.
private func touchingFragments() {
    let page = LineMerge.group([
        line("RIGHT", 500, 0, 200, 20, 0.9),
        line("岁", 400, 0, 20, 20, 0.9),
        line("LEFT", 0, 0, 500, 20, 0.9),
    ])
    check(page.rows.count == 1, "touching fragments one row \(page.rows.count) \(page.text)")
    check(page.text.contains("LEFT") && page.text.contains("RIGHT"), "kept both ends \(page.text)")
    check(!page.text.contains("岁"), "covered scrap dropped \(page.text)")

    let columns = LineMerge.group([
        line("LEFT", 0, 40, 40, 20, 0.9),
        line("RIGHT", 200, 40, 40, 20, 0.9),
    ])
    check(columns.rows.count == 2 && columns.text == "LEFT\nRIGHT", "real column gap \(columns.text)")
}

/// A whitespace gap inside the overlap strip splits when neither box was cropped.
/// A box that ends on its tile edge stays with the fragment from the next tile.
private func seamGapStays() {
    let leftTile = TileFrame(x: 0, y: 0, width: 2048, height: 2048)
    let rightTile = TileFrame(x: 1792, y: 0, width: 2048, height: 2048)
    let open = LineMerge.assemble(
        [
            line("LEFT", 1600, 0, 200, 16, 0.9),
            line("RIGHT", 1860, 0, 200, 16, 0.9),
        ],
        tiles: [leftTile, rightTile]
    )
    check(open.rows.count == 2, "unclipped overlap gap stayed joined \(open.rows.count) \(open.text)")

    let clipped = LineMerge.assemble(
        [
            line("LEFT", 1848, 0, 200, 16, 0.9),
            line("RIGHT", 2110, 0, 200, 16, 0.9),
        ],
        tiles: [leftTile, rightTile]
    )
    check(clipped.rows.count == 1, "clipped seam split \(clipped.rows.count) \(clipped.text)")
    check(clipped.text.contains("LEFT") && clipped.text.contains("RIGHT"), "clipped seam text \(clipped.text)")
}

/// A real column gutter splits even when the right fragment starts on its tile edge.
private func gutterBeatsSeam() {
    let leftTile = TileFrame(x: 0, y: 0, width: 2048, height: 400)
    let rightTile = TileFrame(x: 1792, y: 0, width: 2048, height: 400)
    var lines: [OCRLine] = []
    var tiles: [TileFrame?] = []
    for row in 0..<3 {
        let y = Double(row) * 30
        lines.append(line("L\(row)", 400, y, 300, 20, 0.9))
        tiles.append(leftTile)
        lines.append(line("R\(row)", 1792, y, 300, 20, 0.9))
        tiles.append(rightTile)
    }
    let page = LineMerge.assemble(lines, tiles: tiles)
    check(page.rows.count >= 3, "gutter rows \(page.rows.count) \(page.text)")
    for row in page.rows {
        let hasL = row.text.contains("L")
        let hasR = row.text.contains("R")
        check(!(hasL && hasR), "gutter lost to seam \(row.text)")
    }
}

/// "ce 100元" sits in the overlap; "TAIL" is past the left box and must survive.
private func coveredSeamScrap() {
    let page = LineMerge.group([
        line("发票金额 Invoice 100 元 END", 0, 0, 300, 20, 0.9),
        line("ce 100元 TAIL", 200, 0, 180, 20, 0.9),
    ])
    check(page.rows.count == 1, "seam scrap one row \(page.rows.count)")
    check(page.text.contains("TAIL"), "uncovered tail kept \(page.text)")
    check(!page.text.contains("ce 100元"), "seam prefix dropped \(page.text)")
    check(page.text.contains("END"), "left text kept \(page.text)")
}

private struct FixtureLine: Decodable {
    var text: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

private func fixturePages() {
    let pages: [(String, Int, Double, Double)] = [
        ("page-7000.json", 223, 7000, 5000),
        ("page-8400.json", 269, 8400, 6000),
    ]
    for (name, gt, width, height) in pages {
        let url = fixtureURL(name)
        check(url != nil, "missing fixture \(name)")
        let data = try! Data(contentsOf: url!)
        let decoded = try! JSONDecoder().decode([FixtureLine].self, from: data)
        let lines = decoded.map { item in
            line(item.text, item.x, item.y, item.w, item.h, 0.5)
        }
        let page = LineMerge.group(lines, tiles: assignTiles(lines, width: width, height: height))
        let ratio = Double(page.rows.count) / Double(gt)
        fputs("fixture \(name) rows \(page.rows.count) gt \(gt) ratio \(String(format: "%.4f", ratio))\n", stdout)
        check(ratio >= 0.98 && ratio <= 1.03, "\(name) rows \(page.rows.count) vs gt \(gt)")
        check(page.text == page.rows.map(\.text).joined(separator: "\n"), "\(name) text matches rows")
        for marker in ["L159", "L160", "L134", "L150", "L164"] {
            let hits = page.rows.filter { $0.text.contains(marker) }
            check(hits.count == 1, "\(name) \(marker) rows \(hits.count)")
            let end = marker.replacingOccurrences(of: "L", with: "E")
            check(hits[0].text.contains(end), "\(name) \(marker) split from \(end) \(hits[0].text.prefix(40))")
        }
        let blob = page.text
        check(!blob.contains(". ce"), "\(name) seam '. ce'")
        check(!blob.contains("： e"), "\(name) seam '： e'")
        check(!blob.contains("元 . ce"), "\(name) seam '元 . ce'")
        check(!blob.contains("元. ce"), "\(name) seam '元. ce'")
        let dups = duplicateMarkerCount(blob)
        fputs("fixture \(name) duplicate markers \(dups)\n", stdout)
        check(dups <= 1, "\(name) duplicate markers \(dups)")
        fputs("fixture \(name) blocks \(page.blocks.count)\n", stdout)
        check(page.blocks.count == 1, "\(name) blocks \(page.blocks.count)")
        let heights = lines.map(\.bbox.height).sorted()
        let columnBasis = heights.isEmpty ? 16.0 : heights[heights.count / 2]
        for leftIndex in page.blocks.indices {
            for rightIndex in (leftIndex + 1)..<page.blocks.count {
                let leftBox = page.blocks[leftIndex].bbox
                let rightBox = page.blocks[rightIndex].bbox
                let overlap = min(leftBox.y + leftBox.height, rightBox.y + rightBox.height) - max(leftBox.y, rightBox.y)
                let xGap = max(leftBox.x, rightBox.x) - min(leftBox.x + leftBox.width, rightBox.x + rightBox.width)
                check(!(overlap > columnBasis * 3 && xGap > 0), "\(name) split into columns")
            }
        }
        if let dir = ProcessInfo.processInfo.environment["LINE_MERGE_DUMP"] {
            let out = URL(fileURLWithPath: dir).appendingPathComponent(name.replacingOccurrences(of: ".json", with: "-rows.json"))
            let payload = try! JSONSerialization.data(withJSONObject: page.rows.map(\.text))
            try! payload.write(to: out)
        }
    }
}

/// Three synthetic columns, two bands. An oversized title covers the subtitle's
/// box, but the centers are more than a line apart, so the subtitle stays.
/// A contained copy and a two-character scrap fold back into their host rows.
private func columnReadingOrder() {
    var lines: [OCRLine] = []
    lines.append(line("Quarterly progress on the sample inventory report", 60, 20, 2000, 220, 0.9))
    lines.append(line("Notes on the current quarter and the open items", 200, 180, 800, 36, 0.9))
    let columns = [
        ("Left", 80.0),
        ("Middle", 900.0),
        ("Right", 2100.0),
    ]
    for band in [480.0, 980.0] {
        for row in 0..<4 {
            let y = band + Double(row) * 48
            for column in columns {
                let text = "\(column.0) row \(row) stays in its own column"
                lines.append(line(text, column.1, y, 420, 36, 0.9))
            }
        }
    }
    lines.append(line("Restock the north aisle before the noon delivery", 200, 1500, 900, 40, 0.9))
    lines.append(line("north aisle before the noon", 250, 1502, 520, 36, 0.5))
    lines.append(line("Deliver the spare parts to the service counter today", 200, 1620, 900, 40, 0.9))
    lines.append(line("zz", 500, 1624, 24, 28, 0.4))

    let page = LineMerge.group(lines, tiles: assignTiles(lines, width: 3000, height: 1800))
    check(page.text == page.rows.map(\.text).joined(separator: "\n"), "column text matches rows")
    let first = page.rows.first?.text ?? ""
    check(first.contains("Quarterly progress"), "title is not first \(first)")
    let notes = page.rows.filter { $0.text.contains("Notes on the current quarter") }
    check(notes.count == 1, "subtitle rows \(notes.count)")
    check(!first.contains("Notes on the current quarter"), "title absorbed the subtitle \(first)")

    let heights = page.lines.map(\.bbox.height).sorted()
    let basis = heights.isEmpty ? 16.0 : heights[heights.count / 2]
    for block in page.blocks {
        var previous = -Double.greatestFiniteMagnitude
        for index in block.rowIndices {
            let box = page.rows[index].bbox
            let center = box.y + box.height / 2
            check(center + basis >= previous, "block y went backwards \(center) after \(previous)")
            previous = center
        }
    }
    for row in page.rows {
        let hasMiddle = row.text.contains("Middle")
        let hasRight = row.text.contains("Right")
        let hasLeft = row.text.contains("Left")
        check(!(hasMiddle && hasRight), "middle and right share a row \(row.text)")
        check(!(hasLeft && hasMiddle), "left bled into the middle \(row.text)")
    }
    func bandIndices(_ name: String, y0: Double, y1: Double) -> [Int] {
        page.rows.indices.filter { index in
            let row = page.rows[index]
            let box = row.bbox
            let centerY = box.y + box.height / 2
            return row.text.contains(name) && centerY >= y0 && centerY <= y1
        }
    }
    for band in [(480.0, 720.0, "upper"), (980.0, 1220.0, "lower")] {
        let middle = bandIndices("Middle", y0: band.0, y1: band.1)
        let right = bandIndices("Right", y0: band.0, y1: band.1)
        check(!middle.isEmpty && !right.isEmpty, "column band empty \(band.2)")
        if let lastMiddle = middle.max(), let firstRight = right.min() {
            check(lastMiddle < firstRight, "middle column is not finished before the right column \(band.2) \(lastMiddle) \(firstRight)")
        }
        for block in page.blocks {
            let hasMiddle = block.rowIndices.contains { middle.contains($0) }
            let hasRight = block.rowIndices.contains { right.contains($0) }
            check(!(hasMiddle && hasRight), "middle and right share block \(band.2)")
        }
    }
    let restock = page.rows.filter { $0.text.contains("Restock the north aisle") }
    check(restock.count == 1, "contained copy stayed a second row \(restock.map(\.text))")
    let orphan = page.rows.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == "zz" }
    check(orphan.isEmpty, "short scrap stayed a row \(orphan.map(\.text))")
}

/// Tall boxes overlap by about half a line while their centers are still
/// farther than 0.5× the median height. They stay two rows, so the lower
/// line keeps its left half.
private func stackedParagraphCenter() {
    var lines: [OCRLine] = []
    for index in 0..<12 {
        lines.append(line(
            "Filler sentence \(index) sets the median line height",
            200,
            100 + Double(index) * 200,
            900,
            138,
            0.9
        ))
    }
    let body = "FLOOR stays on this line. " + String(repeating: "The sample paragraph continues across the measure. ", count: 6) + "PERIOD ends the review."
    lines.append(line("ALPHA plan covers the sample tier only", 242.75, 3097.45, 1630.92, 182.42, 0.9))
    lines.append(line(body, 247.65, 3177.74, 2723.22, 272.17, 0.9))
    let whole = LineMerge.group(lines)
    let floor = whole.rows.filter { $0.text.contains("FLOOR") }
    check(floor.count == 1, "whole floor rows \(floor.count) \(floor.map(\.text))")
    if let row = floor.first {
        check(row.text.contains("PERIOD"), "whole line lost its right half \(row.text)")
        check(!row.text.contains("ALPHA"), "heading swallowed the paragraph \(row.text)")
    }
    let heading = whole.rows.filter { $0.text.contains("ALPHA") }
    check(heading.count == 1, "heading rows \(heading.count)")
    check(heading.first?.text.contains("PERIOD") == false, "heading took the paragraph \(heading.first?.text ?? "")")

    var tiled = lines
    tiled.removeLast()
    let right = String(repeating: "word ", count: 20) + "MARKRIGHT through the review period ends here"
    tiled.append(line("MARKLEFT begins the sample paragraph and reaches the seam", 248.8, 3243.0, 1800.1, 187.9, 0.9))
    tiled.append(line(right, 972.0, 3182.4, 1990.6, 214.5, 0.9))
    let tiledPage = LineMerge.group(tiled, tiles: assignTiles(tiled, width: 3024, height: 4032))
    let marked = tiledPage.rows.filter { $0.text.contains("MARKLEFT") }
    check(marked.count == 1, "tiled paragraph rows \(marked.count) \(marked.map(\.text))")
    if let row = marked.first {
        check(row.text.contains("MARKRIGHT"), "tiled paragraph lost its right half \(row.text)")
        check(!row.text.contains("ALPHA"), "tiled heading joined the paragraph \(row.text)")
    }
    let scheme = tiledPage.rows.filter { $0.text.contains("ALPHA") }
    check(scheme.count == 1, "tiled heading rows \(scheme.count)")
    check(scheme.first?.text.contains("MARKRIGHT") == false, "tiled heading took the next line \(scheme.first?.text ?? "")")
}

private func duplicateMarkerCount(_ text: String) -> Int {
    var counts: [String: Int] = [:]
    let chars = Array(text)
    var index = 0
    while index < chars.count {
        let character = chars[index]
        if character == "L" || character == "E" {
            var end = index + 1
            while end < chars.count, let value = chars[end].asciiValue, (48...57).contains(value) {
                end += 1
            }
            if end - index - 1 >= 3 {
                let marker = String(chars[index..<end])
                counts[marker, default: 0] += 1
            }
        }
        index += 1
    }
    return counts.values.filter { $0 >= 2 }.count
}

private func tilePolicy() {
    check(TilePolicy.defaultMinGlyphFrac == 0.012, "default T \(TilePolicy.defaultMinGlyphFrac)")
    check(TilePolicy.probeMaxSide == 4096, "probe side \(TilePolicy.probeMaxSide)")
    check(TilePolicy.singlePassSide == 2048, "single pass \(TilePolicy.singlePassSide)")
    check(abs(TilePolicy.widthUnits("，") - 1) < 0.001, "fullwidth comma")
    check(abs(TilePolicy.widthUnits("A") - 0.55) < 0.001, "latin unit")
    check(abs(TilePolicy.widthUnits("中A") - 1.55) < 0.001, "mixed units")

    let wide = glyphRun(count: 16, chars: 10, px: 56)
    let page = TilePolicy.decide(width: 3024, height: 4032, lines: wide)
    fputs("wide decision \(page.mode) \(page.glyphPx) \(page.glyphFrac) \(page.tileDecision)\n", stdout)
    check(page.mode == "whole", "56px glyphs on a 4032 page should be whole \(page.tileDecision)")
    check(!page.tileDecision.contains("4096"), "4032 must not skip on long side \(page.tileDecision)")
    check(abs(page.glyphPx - 56) < 0.05, "wide glyphPx \(page.glyphPx)")
    check(page.glyphFrac >= 0.012, "wide glyphFrac \(page.glyphFrac)")
    check(page.countedLines >= 8, "wide counted \(page.countedLines)")

    let phone = TilePolicy.decide(width: 3024, height: 4032, lines: glyphRun(count: 10, chars: 10, px: 40))
    check(phone.mode == "tiled", "small glyphs on a 4032 page still tile \(phone.tileDecision)")
    check(!phone.tileDecision.contains("4096"), "no 4096 shortcut \(phone.tileDecision)")

    let dense = TilePolicy.decide(width: 4284, height: 5712, lines: glyphRun(count: 12, chars: 10, px: 42))
    fputs("dense decision \(dense.mode) \(dense.glyphPx) \(dense.glyphFrac) \(dense.tileDecision)\n", stdout)
    check(dense.mode == "tiled", "42px glyphs on a 5712 page \(dense.tileDecision)")
    check(abs(dense.glyphPx - 42) < 0.05, "dense glyphPx \(dense.glyphPx)")
    check(dense.glyphFrac < 0.012, "dense frac \(dense.glyphFrac)")

    let emptyWide = TilePolicy.decide(width: 7000, height: 5000, lines: [])
    check(emptyWide.mode == "tiled" && emptyWide.tileDecision.contains("qualifying"), emptyWide.tileDecision)
    let emptyTaller = TilePolicy.decide(width: 8400, height: 6000, lines: [])
    check(emptyTaller.mode == "tiled", "8400 fixture \(emptyTaller.tileDecision)")

    let junk = TilePolicy.decide(width: 6064, height: 8294, lines: glyphRun(count: 4, chars: 8, px: 400))
    check(junk.mode == "tiled" && junk.countedLines == 4, "halftone \(junk.tileDecision)")
    check(junk.glyphFrac > 0.012, "halftone fraction would have looked large \(junk.glyphFrac)")

    let oneTile = TilePolicy.decide(width: 1500, height: 2048, lines: glyphRun(count: 10, chars: 8, px: 10))
    check(oneTile.mode == "whole" && oneTile.tileDecision.contains("2048"), oneTile.tileDecision)
    let justOver = TilePolicy.decide(width: 1500, height: 2049, lines: glyphRun(count: 10, chars: 8, px: 10))
    check(justOver.mode == "tiled", "2049 still measured \(justOver.tileDecision)")

    let forcedTile = TilePolicy.decide(width: 3024, height: 4032, lines: wide, force: "tile")
    check(forcedTile.mode == "tiled" && forcedTile.tileDecision == "tiled: force=tile", forcedTile.tileDecision)
    check(abs(forcedTile.glyphPx - 56) < 0.05, "force still reports glyph \(forcedTile.glyphPx)")
    let forcedWhole = TilePolicy.decide(width: 7000, height: 5000, lines: [], force: "whole")
    check(forcedWhole.mode == "whole" && forcedWhole.tileDecision == "whole: force=whole", forcedWhole.tileDecision)
}

private func glyphRun(count: Int, chars: Int, px: Double) -> [GlyphBox] {
    let text = String(repeating: "中", count: chars)
    return (0..<count).map { _ in GlyphBox(text: text, width: px * Double(chars)) }
}

private func tileRects(width: Double, height: Double) -> [TileFrame] {
    let tile = 2048.0
    let overlap = 256.0
    func spans(_ length: Double) -> [(Double, Double)] {
        if length <= tile { return [(0, max(length, 0))] }
        let step = tile - overlap
        var offsets = [0.0]
        var cursor = 0.0
        while cursor + tile < length - 0.5 {
            let next = cursor + step
            let last = length - tile
            if next >= last - 0.5 {
                if last > offsets[offsets.count - 1] + 0.5 {
                    offsets.append(last)
                }
                break
            }
            offsets.append(next)
            cursor = next
        }
        return offsets.map { ($0, tile) }
    }
    var result: [TileFrame] = []
    for y in spans(height) {
        for x in spans(width) {
            result.append(TileFrame(x: x.0, y: y.0, width: x.1, height: y.1))
        }
    }
    return result
}

/// The tile that contains most of the box. Lines already deduped have no
/// source index; the crop that still holds the box is the one Vision saw.
private func assignTiles(_ lines: [OCRLine], width: Double, height: Double) -> [TileFrame?] {
    let rects = tileRects(width: width, height: height)
    return lines.map { line in
        let box = line.bbox
        let boxArea = max(box.width, 0) * max(box.height, 0)
        guard boxArea > 0 else { return nil }
        var best: (TileFrame, Double)?
        for rect in rects {
            let x0 = max(box.x, rect.x)
            let y0 = max(box.y, rect.y)
            let x1 = min(box.x + box.width, rect.x + rect.width)
            let y1 = min(box.y + box.height, rect.y + rect.height)
            let area = max(0, x1 - x0) * max(0, y1 - y0)
            if area / boxArea >= 0.8, best == nil || area > best!.1 {
                best = (rect, area)
            }
        }
        return best?.0
    }
}

private func fixtureURL(_ name: String) -> URL? {
    var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        let candidate = url.appendingPathComponent("Sources/LineMergeTestRunner/Fixtures").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        url.deleteLastPathComponent()
    }
    return nil
}

private func timing() {
    let piece = String(repeating: "发票金额 Invoice 100 元 ", count: 4)
    let tileW = 2048.0
    let tileH = 2048.0
    let step = 1792.0
    let pageW = 6700.0
    let pageH = 7300.0
    var frames: [TileFrame] = []
    var y = 0.0
    while y < pageH {
        var x = 0.0
        let height = min(tileH, pageH - y)
        while x < pageW {
            let width = min(tileW, pageW - x)
            frames.append(TileFrame(x: x, y: y, width: width, height: height))
            if x + tileW >= pageW { break }
            let next = x + step
            let last = pageW - tileW
            x = next >= last ? last : next
        }
        if y + tileH >= pageH { break }
        let next = y + step
        let last = pageH - tileH
        y = next >= last ? last : next
    }

    func tileContaining(_ x: Double, _ y: Double) -> TileFrame? {
        frames.first { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }
    }

    var lines: [OCRLine] = []
    var tiles: [TileFrame?] = []
    lines.reserveCapacity(1200)
    for row in 0..<240 {
        let y = Double(row) * 30 + 40
        for column in 0..<5 {
            let x = Double(column) * 1300
            lines.append(line("\(piece) R\(row)C\(column)", x, y, 1500, 16, 0.5))
            let centerX = x + 750
            let centerY = y + 8
            tiles.append(tileContaining(centerX, centerY))
        }
    }
    check(lines.count == 1200, "fixture size \(lines.count)")
    let start = Date()
    let page = LineMerge.assemble(lines, tiles: tiles)
    let elapsed = Date().timeIntervalSince(start)
    fputs(String(format: "merge %.1f ms\n", elapsed * 1000), stdout)
    check(elapsed < 1, "1200 lines took \(elapsed)s")
    check(page.lines.count == 1200, "timing dropped lines \(page.lines.count)")
    check(page.rows.count == 240, "timing rows \(page.rows.count)")
}

private func openAICompatTests() {
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
    let webp = Data("RIFF".utf8) + Data([4, 0, 0, 0]) + Data("WEBP".utf8)
    let heic = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 0, count: 8)
    func b64(_ data: Data) -> String { data.base64EncodedString() }
    func dataURL(_ mime: String, _ data: Data) -> String { "data:\(mime);base64,\(b64(data))" }

    let system = "You are an OCR engine. Return the text only."
    let body: [String: Any] = [
        "model": "gpt-4o-mini",
        "temperature": 0.7,
        "top_p": 1,
        "n": 3,
        "max_tokens": 4096,
        "max_completion_tokens": 100,
        "stop": ["\n"],
        "presence_penalty": 0,
        "frequency_penalty": 0,
        "user": "bob",
        "response_format": ["type": "json_object"],
        "seed": 1,
        "logprobs": false,
        "tools": [Any](),
        "thinking": ["type": "disabled"],
        "reasoning_effort": "low",
        "unknown_field": ["kept": true],
        "stream": false,
        "messages": [
            ["role": "system", "content": system],
            ["role": "developer", "content": "ocr-language: ja-JP\nKeep the layout."],
            [
                "role": "user",
                "content": [
                    ["type": "text", "text": "Read this."],
                    ["type": "image_url", "image_url": ["url": dataURL("image/png", png), "detail": "high"]],
                ],
            ],
            ["role": "assistant", "content": "previous"],
            [
                "role": "user",
                "content": [
                    ["type": "text", "text": "second page"],
                    ["type": "image_url", "image_url": dataURL("image/jpeg", jpeg)],
                    ["type": "input_image", "image_url": ["url": dataURL("image/webp", webp)]],
                ],
            ],
        ],
    ]
    let parsed = tryParse(body)
    check(parsed.images.count == 2, "last user images \(parsed.images.count)")
    check(parsed.images[0].data == jpeg && parsed.images[0].mediaType == "image/jpeg", "jpeg part")
    check(parsed.images[1].data == webp && parsed.images[1].mediaType == "image/webp", "webp part")
    check(parsed.model == "gpt-4o-mini", "model \(parsed.model ?? "")")
    check(parsed.stream == false, "stream false")
    check(parsed.languages == ["ja-JP"], "language hint \(parsed.languages ?? [])")
    check(parsed.promptScalars == system.unicodeScalars.count + "ocr-language: ja-JP\nKeep the layout.".unicodeScalars.count + "Read this.".unicodeScalars.count + "previous".unicodeScalars.count + "second page".unicodeScalars.count, "prompt scalars \(parsed.promptScalars)")

    let ignored = tryParse([
        "model": 12,
        "stream": 1,
        "stream_options": ["include_usage": true, "include_obfuscation": false],
        "messages": [[
            "role": "user",
            "content": [["type": "image_url", "image_url": ["url": "data:image/heic;base64," + wrapped(b64(heic))]]],
        ]],
    ])
    check(ignored.stream == false, "numeric stream is not streaming")
    check(ignored.includeUsage, "include_usage")
    check(ignored.model == "12", "numeric model")
    check(ignored.images[0].data == heic && ignored.images[0].mediaType == "image/heic", "heic")

    let fallback = tryParse([
        "messages": [
            ["role": "user", "content": [["type": "image_url", "image_url": dataURL("image/png", png)]]],
            ["role": "assistant", "content": [["type": "image_url", "image_url": ["url": dataURL("image/jpeg", jpeg)]]]],
            ["role": "user", "content": "no picture here\nocr-language: en"],
        ],
    ])
    check(fallback.images.count == 2, "fallback images \(fallback.images.count)")
    check(fallback.images[0].data == png && fallback.images[1].data == jpeg, "fallback order")
    check(fallback.languages == ["en-US"], "en hint")

    let noUser = tryParse([
        "messages": [
            ["role": "system", "content": [["type": "image_url", "image_url": dataURL("image/png", png)]]],
        ],
    ])
    check(noUser.images.count == 1 && noUser.images[0].data == png, "system fallback")

    let scanner = "Act like a text scanner. Extract text as it is without analyzing it."
    let validate = tryParse([
        "model": "mac-ocr",
        "temperature": 0.7,
        "stream": true,
        "messages": [["role": "user", "content": scanner]],
    ])
    check(validate.images.isEmpty, "validate has no image")
    check(validate.stream, "validate streams")
    check(validate.model == "mac-ocr", "validate model")
    check(validate.promptScalars == scanner.unicodeScalars.count, "validate scalars")

    let emptyMessages = tryParse(["model": "mac-ocr", "messages": [Any](), "stream": false])
    check(emptyMessages.images.isEmpty && emptyMessages.stream == false, "empty messages")
    let missingMessages = tryParse(["model": "mac-ocr"])
    check(missingMessages.images.isEmpty, "missing messages")

    let stranslate = tryParse([
        "model": "mac-ocr",
        "temperature": 0.7,
        "messages": [
            ["role": "system", "content": "markdown rules"],
            ["role": "user", "content": [
                ["type": "text", "text": "please read"],
                ["type": "image_url", "image_url": ["url": dataURL("image/jpeg", jpeg)]],
            ]],
        ],
    ])
    check(stranslate.images.count == 1 && stranslate.images[0].data == jpeg, "stranslate jpeg")
    check(stranslate.images[0].mediaType == "image/jpeg", "stranslate jpeg type")
    check(stranslate.stream == false, "stranslate ocr is not a stream")
    let stranslatePNG = tryParse([
        "model": "gpt-4o",
        "messages": [[
            "role": "user",
            "content": [
                ["type": "text", "text": "please read"],
                ["type": "image_url", "image_url": ["url": dataURL("image/png", png)]],
            ],
        ]],
    ])
    check(stranslatePNG.images.count == 1 && stranslatePNG.images[0].mediaType == "image/png", "stranslate png")

    expectError(["messages": "nope"], code: nil)
    expectError([
        "messages": [[
            "role": "user",
            "content": [["type": "image_url", "image_url": ["url": "https://example.com/a.png", "detail": "auto"]]],
        ]],
    ], code: "invalid_image_url")
    expectError([
        "messages": [[
            "role": "user",
            "content": [["type": "image_url", "image_url": "file:///tmp/page.png"]],
        ]],
    ], code: "invalid_image_url")
    expectError([
        "messages": [[
            "role": "user",
            "content": [["type": "image_url", "image_url": ["url": "http://127.0.0.1/a.jpg"]]],
        ]],
    ], code: "invalid_image_url")
    expectError([
        "messages": [[
            "role": "user",
            "content": [["type": "image_url", "image_url": "data:image/png;base64,****"]],
        ]],
    ], code: "invalid_base64")
    expectError([
        "messages": [[
            "role": "user",
            "content": [["type": "image_url", "image_url": "data:text/html;base64,\(b64(Data("hi".utf8)))"]],
        ]],
    ], code: "invalid_image_url")

    let unknownHint = tryParse([
        "messages": [[
            "role": "user",
            "content": [
                ["type": "text", "text": "ocr-language: fr-FR"],
                ["type": "image_url", "image_url": dataURL("image/png", png)],
            ],
        ]],
    ])
    check(unknownHint.languages == nil, "unknown hint ignored")

    let responses = tryResponses([
        "model": "custom-model",
        "instructions": "You are an OCR engine.",
        "temperature": 0,
        "input": [
            ["type": "input_text", "text": "ocr-language: zh-Hant"],
            ["type": "input_image", "image_url": dataURL("image/png", png)],
            ["type": "input_image", "image_url": ["url": dataURL("image/jpeg", jpeg), "detail": "low"]],
        ],
    ])
    check(responses.images.count == 2, "responses images")
    check(responses.images[0].data == png && responses.images[1].data == jpeg, "responses order")
    check(responses.languages == ["zh-Hant"], "responses hint")
    check(responses.model == "custom-model", "responses model")
    let textProbe = tryResponses([
        "model": "mac-ocr",
        "instructions": "system",
        "input": "Reply with OK.",
        "stream": true,
        "temperature": 0.7,
    ])
    check(textProbe.images.isEmpty && textProbe.stream, "responses text probe")
    let noInput = tryResponses(["model": "mac-ocr"])
    check(noInput.images.isEmpty && noInput.stream == false, "responses without input")

    let usage = OpenAICompat.Usage(promptScalars: 4, completion: "ab\n\ncd")
    check(usage.completionTokens == 6 && usage.totalTokens == 10, "usage \(usage)")
    let completion = jsonObject(OpenAICompat.chatCompletionJSON(
        id: "chatcmpl-test",
        created: 1711929600,
        model: "gpt-4o-mini",
        content: "ab\n\ncd",
        usage: usage
    ))
    check(completion["object"] as? String == "chat.completion", "completion object")
    check(completion["model"] as? String == "gpt-4o-mini", "echo model")
    let choices = completion["choices"] as? [[String: Any]] ?? []
    check(choices.count == 1, "n is ignored, one choice")
    let message = choices.first?["message"] as? [String: Any]
    check(message?["role"] as? String == "assistant", "assistant role")
    check(message?["content"] as? String == "ab\n\ncd", "plain text despite json_object")
    let emptyCompletion = jsonObject(OpenAICompat.chatCompletionJSON(
        id: "chatcmpl-empty",
        created: 1,
        model: "mac-ocr",
        content: "",
        usage: OpenAICompat.Usage(promptScalars: scanner.unicodeScalars.count, completion: "")
    ))
    let emptyChoices = emptyCompletion["choices"] as? [[String: Any]] ?? []
    let emptyMessage = emptyChoices.first?["message"] as? [String: Any]
    check(emptyMessage?["content"] as? String == "", "empty validate content")
    check(emptyChoices.first?["finish_reason"] as? String == "stop", "empty finish")
    check(choices.first?["finish_reason"] as? String == "stop", "finish stop")
    check(completion["system_fingerprint"] as? String == "fp_macocr", "fingerprint")

    let events = OpenAICompat.sseEvents(
        wire: .chat,
        id: "chatcmpl-test",
        created: 1711929600,
        model: "mac-ocr",
        content: "ab\n\ncd",
        usage: usage,
        includeUsage: true
    )
    check(String(data: events.last ?? Data(), encoding: .utf8) == "data: [DONE]\n\n", "done sentinel")
    var pieces = ""
    var sawRole = false
    var sawStop = false
    var sawUsage = false
    for event in events.dropLast() {
        let text = String(data: event, encoding: .utf8) ?? ""
        check(text.hasPrefix("data: "), "chat event prefix \(text)")
        let payload = jsonObject(Data(text.dropFirst(6).dropLast(2).utf8))
        check(payload["object"] as? String == "chat.completion.chunk", "chunk object")
        let chunkChoices = payload["choices"] as? [Any] ?? [""]
        if chunkChoices.isEmpty {
            sawUsage = payload["usage"] != nil
            continue
        }
        let choice = (chunkChoices.first as? [String: Any]) ?? [:]
        let delta = choice["delta"] as? [String: Any] ?? [:]
        if delta["role"] as? String == "assistant" { sawRole = true }
        if let content = delta["content"] as? String { pieces += content }
        if choice["finish_reason"] as? String == "stop" { sawStop = true }
    }
    check(sawRole && sawStop && sawUsage, "sse markers role=\(sawRole) stop=\(sawStop) usage=\(sawUsage)")
    check(pieces == "ab\n\ncd", "sse concat \(pieces)")

    let emptyEvents = OpenAICompat.sseEvents(
        wire: .chat,
        id: "chatcmpl-empty",
        created: 1,
        model: "mac-ocr",
        content: "",
        usage: OpenAICompat.Usage(promptScalars: 0, completion: ""),
        includeUsage: false
    )
    check(String(data: emptyEvents.last ?? Data(), encoding: .utf8) == "data: [DONE]\n\n", "empty stream done")
    var emptyPieces = ""
    var emptyRole = false
    var emptyStop = false
    for event in emptyEvents.dropLast() {
        let text = String(data: event, encoding: .utf8) ?? ""
        let payload = jsonObject(Data(text.dropFirst(6).dropLast(2).utf8))
        let choice = ((payload["choices"] as? [Any])?.first as? [String: Any]) ?? [:]
        let delta = choice["delta"] as? [String: Any] ?? [:]
        if delta["role"] as? String == "assistant" { emptyRole = true }
        if let content = delta["content"] as? String { emptyPieces += content }
        if choice["finish_reason"] as? String == "stop" { emptyStop = true }
    }
    check(emptyRole && emptyStop && emptyPieces.isEmpty, "empty stream markers")

    let denied = OpenAICompat.accessLog(method: "POST", path: "/v1/chat/completions", status: 400, code: "invalid_image_url")
    check(denied == "POST /v1/chat/completions 400 invalid_image_url", "error log \(denied)")
    check(!denied.contains("Bearer") && !denied.contains("http"), "log has no secret or url")
    let okLine = OpenAICompat.accessLog(method: "POST", path: "/v1/chat/completions", status: 200, code: nil)
    check(okLine == "POST /v1/chat/completions 200", "ok log \(okLine)")
    let queued = OpenAICompat.accessLog(method: "POST", path: "/v1/responses", status: 503, code: "queue_full")
    check(queued == "POST /v1/responses 503 queue_full", "queue log \(queued)")

    let framed = OpenAICompat.chunkFrame(Data("data: hi\n\n".utf8))
    check(framed == Data("a\r\ndata: hi\n\n\r\n".utf8), "chunk frame \(framed as NSData)")
    check(OpenAICompat.chunkTerminator() == Data("0\r\n\r\n".utf8), "chunk end")

    let responseEvents = OpenAICompat.sseEvents(
        wire: .responses,
        id: "resp_test",
        created: 10,
        model: "mac-ocr",
        content: "row",
        usage: usage,
        includeUsage: false
    )
    let deltaText = String(data: responseEvents[0], encoding: .utf8) ?? ""
    check(deltaText.contains("event: response.output_text.delta"), "responses delta event")
    check(deltaText.contains("\"delta\":\"row\""), "responses delta \(deltaText)")
    let doneText = String(data: responseEvents[1], encoding: .utf8) ?? ""
    check(doneText.contains("response.completed"), "responses completed")
    check(doneText.contains("\"status\":\"completed\""), "responses status")
    check(doneText.contains("\"output_text\":\"row\""), "responses output_text")

    let listed = jsonObject(OpenAICompat.modelsList(id: "mac-ocr", created: 1711929600))
    check(listed["object"] as? String == "list", "models list")
    let data = listed["data"] as? [[String: Any]] ?? []
    check(data.count == 1, "one model")
    check(data.first?["id"] as? String == "mac-ocr", "model id")
    check(data.first?["object"] as? String == "model", "model object")
    check(data.first?["owned_by"] as? String == "mac-ocr-http", "owner")

    let error = jsonObject(OpenAICompat.errorJSON(.invalid("http(s) and file URLs are not accepted", param: "image_url", code: "invalid_image_url")))
    let err = error["error"] as? [String: Any] ?? [:]
    check(err["message"] as? String == "http(s) and file URLs are not accepted", "error message")
    check(err["type"] as? String == "invalid_request_error", "error type")
    check(err["param"] as? String == "image_url", "error param")
    check(err["code"] as? String == "invalid_image_url", "error code")
}

private func debugCaptureTests() {
    let token = "SUPERSECRETTOKENVALUE"
    let queryValue = "QUERYVALUE9f3a"
    let imagePayload = "QUJDREVGR0hJSktMTQBASE64PAYLOAD"
    let textPayload = "SHOULDNOTAPPEAR"
    let prompt = "please read the sign"
    let body: [String: Any] = [
        "authorization": "Bearer \(token)",
        "api_key": token,
        "query": queryValue,
        "temperature": 0.7,
        "model": "mac-ocr",
        "messages": [
            ["role": "system", "content": "markdown rules"],
            ["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "text", "text": "data:image/png;base64,\(textPayload)"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(imagePayload)", "detail": "low"]],
            ]],
        ],
    ]
    let summaries = DebugCapture.messageSummaries(json: jsonData(body))
    check(summaries.count == 2, "summary count \(summaries.count)")
    check(summaries[0].role == "system" && summaries[0].texts == ["markdown rules"] && summaries[0].imageCount == 0, "system summary")
    check(summaries[1].role == "user", "user role")
    check(summaries[1].texts.count == 2, "two text parts")
    check(summaries[1].texts[0] == prompt, "prompt kept")
    check(summaries[1].texts[1] == "data:image/png;base64,[redacted]", "text data url redacted")
    check(summaries[1].imageCount == 1, "image counted without its url")

    let meta = DebugCapture.makeMeta(
        timestamp: "2026-10-12T00:00:01Z",
        endpoint: "/v1/chat/completions",
        clientIP: "127.0.0.1",
        status: 200,
        errorCode: nil,
        passes: [DebugPassSummary(elapsedMs: 12, mode: "whole", tiles: 1, glyphFrac: 0.02, text: "line", rows: ["line"])],
        messages: summaries
    )
    let encoded = try! DebugCapture.metaJSON(meta)
    assertRedacted(encoded, "meta")
    let object = jsonObject(encoded)
    check(object["mode"] as? String == "whole", "one pass mode")
    check(object["tiles"] as? Int == 1, "one pass tiles")
    check(object["text"] as? String == "line", "returned text")
    check((object["rows"] as? [String]) == ["line"], "returned rows")
    check(object["errorCode"] == nil, "success has no error code")

    let empty = DebugCapture.makeMeta(
        timestamp: "2026-10-12T00:00:02Z",
        endpoint: "/v1/chat/completions",
        clientIP: "127.0.0.1",
        status: 200,
        errorCode: nil,
        passes: [],
        messages: summaries
    )
    let emptyObject = jsonObject(try! DebugCapture.metaJSON(empty))
    check(emptyObject["text"] as? String == "", "text-only probe stores empty text")
    check(emptyObject["mode"] == nil, "text-only probe has no mode")

    let failed = DebugCapture.makeMeta(
        timestamp: "2026-10-12T00:00:03Z",
        endpoint: "/v1/chat/completions",
        clientIP: "127.0.0.1",
        status: 400,
        errorCode: "invalid_image_url",
        passes: [],
        messages: []
    )
    let failedObject = jsonObject(try! DebugCapture.metaJSON(failed))
    check(failedObject["errorCode"] as? String == "invalid_image_url", "error code kept")
    check(failedObject["text"] == nil, "failed capture has no text")
    check(Set(failedObject.keys).isSubset(of: DebugCapture.metaKeys), "failed keys")

    check(DebugCapture.records(status: 200), "authenticated success is captured")
    check(DebugCapture.records(status: 400), "authenticated 400 is captured")
    check(DebugCapture.records(status: 413), "authenticated 413 is captured")
    check(DebugCapture.records(status: 500), "authenticated 500 is captured")
    check(!DebugCapture.records(status: 401), "401 is not captured")
    let admitted = [401, 401, 200, 400].filter(DebugCapture.records)
    check(admitted == [200, 400], "401s do not take ring slots \(admitted)")

    check(DebugCapture.evictionIDs(existingOldestFirst: ["000001", "000002", "000003"], maxCount: 2) == ["000001"], "evict oldest")
    check(DebugCapture.evictionIDs(existingOldestFirst: ["000001", "000002"], maxCount: 2).isEmpty, "at the cap")
    check(DebugCapture.evictionIDs(existingOldestFirst: ["000001"], maxCount: 0) == ["000001"], "max zero drops all")

    let responsesBody: [String: Any] = [
        "token": token,
        "instructions": "You are an OCR engine.",
        "input": [[
            "role": "user",
            "content": [
                ["type": "input_text", "text": prompt],
                ["type": "input_image", "image_url": "data:image/jpeg;base64,\(imagePayload)"],
            ],
        ]],
    ]
    let responses = DebugCapture.messageSummaries(json: jsonData(responsesBody))
    check(responses.count == 2, "responses summary count")
    check(responses[0].role == "instructions" && responses[0].texts == ["You are an OCR engine."], "instructions")
    check(responses[1].imageCount == 1 && responses[1].texts == [prompt], "responses image count")
    let responsesJSON = try! DebugCapture.metaJSON(DebugCapture.makeMeta(
        timestamp: "2026-10-12T00:00:04Z",
        endpoint: "/v1/responses",
        clientIP: "192.168.1.50",
        status: 200,
        errorCode: nil,
        passes: [],
        messages: responses
    ))
    assertRedacted(responsesJSON, "responses meta")

    let root = "/tmp/macocr-capture-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let store = DebugCaptureStore(directory: root, maxCount: 2)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x11, 0x22])
    for index in 1...3 {
        let record = DebugCapture.makeMeta(
            timestamp: "2026-10-12T00:00:0\(index)Z",
            endpoint: "/ocr",
            clientIP: "127.0.0.1",
            status: 200,
            errorCode: nil,
            passes: [DebugPassSummary(elapsedMs: index, mode: "whole", tiles: 1, glyphFrac: 0.02, text: "row \(index)", rows: ["row \(index)"])],
            messages: summaries
        )
        try! store.save(meta: record, images: [png])
    }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { Int($0) != nil }.sorted()
    check(names == ["000002", "000003"], "ring kept \(names)")
    check(!FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("000001")), "oldest removed")
    check(posixMode(root) == 0o700, "capture dir mode \(posixMode(root))")
    let kept = (root as NSString).appendingPathComponent("000003")
    check(posixMode(kept) == 0o700, "entry dir mode \(posixMode(kept))")
    let metaPath = (kept as NSString).appendingPathComponent("meta.json")
    let imagePath = (kept as NSString).appendingPathComponent("image-0.png")
    check(posixMode(metaPath) == 0o600, "meta mode \(posixMode(metaPath))")
    check(posixMode(imagePath) == 0o600, "image mode \(posixMode(imagePath))")
    let saved = try! Data(contentsOf: URL(fileURLWithPath: imagePath))
    check(saved == png, "original image bytes")
    assertRedacted(try! Data(contentsOf: URL(fileURLWithPath: metaPath)), "stored meta")
    let stored = jsonObject(try! Data(contentsOf: URL(fileURLWithPath: metaPath)))
    check(stored["endpoint"] as? String == "/ocr", "stored endpoint")
    check(stored["text"] as? String == "row 3", "newest text kept")
}

private func assertRedacted(_ data: Data, _ label: String) {
    let text = String(data: data, encoding: .utf8) ?? ""
    check(!text.contains("SUPERSECRETTOKENVALUE"), "\(label) dropped the token")
    check(!text.contains("QUERYVALUE9f3a"), "\(label) dropped the query value")
    check(!text.contains("QUJDREVGR0hJSktMTQBASE64PAYLOAD"), "\(label) dropped image base64")
    check(!text.contains("SHOULDNOTAPPEAR"), "\(label) dropped a data URL in text")
    check(!text.contains("authorization"), "\(label) dropped the authorization field")
    check(!text.contains("Bearer"), "\(label) dropped the bearer scheme")
    check(text.contains("please read the sign"), "\(label) kept the prompt")
    let object = jsonObject(data)
    check(Set(object.keys).isSubset(of: DebugCapture.metaKeys), "\(label) keys \(Set(object.keys))")
    if let messages = object["messages"] as? [[String: Any]] {
        for message in messages {
            check(Set(message.keys).isSubset(of: DebugCapture.messageKeys), "\(label) message keys")
        }
    }
}

private func posixMode(_ path: String) -> Int {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let number = attrs[.posixPermissions] as? NSNumber else {
        return -1
    }
    return Int(number.uint16Value) & 0o777
}

private func wrapped(_ url: String) -> String {
    var lines: [String] = []
    var rest = url[...]
    while !rest.isEmpty {
        let end = rest.index(rest.startIndex, offsetBy: min(16, rest.count), limitedBy: rest.endIndex) ?? rest.endIndex
        lines.append(String(rest[..<end]))
        rest = rest[end...]
    }
    return lines.joined(separator: "\n")
}

private func tryParse(_ object: [String: Any]) -> OpenAICompat.Parsed {
    do {
        return try OpenAICompat.parseChat(jsonData(object))
    } catch {
        fputs("FAIL parse chat \(error)\n", stderr)
        exit(1)
    }
}

private func tryResponses(_ object: [String: Any]) -> OpenAICompat.Parsed {
    do {
        return try OpenAICompat.parseResponses(jsonData(object))
    } catch {
        fputs("FAIL parse responses \(error)\n", stderr)
        exit(1)
    }
}

private func expectError(_ object: [String: Any], code: String?) {
    do {
        _ = try OpenAICompat.parseChat(jsonData(object))
        fputs("FAIL expected chat error \(code ?? "any")\n", stderr)
        exit(1)
    } catch let error as OpenAICompat.APIError {
        check(error.status == 400 && error.type == "invalid_request_error", "error status \(error.status) \(error.type)")
        if let code {
            check(error.code == code, "error code \(error.code ?? "nil") wanted \(code)")
        }
    } catch {
        fputs("FAIL unexpected \(error)\n", stderr)
        exit(1)
    }
}

private func expectResponsesError(_ object: [String: Any], code: String) {
    do {
        _ = try OpenAICompat.parseResponses(jsonData(object))
        fputs("FAIL expected responses error\n", stderr)
        exit(1)
    } catch let error as OpenAICompat.APIError {
        check(error.code == code, "responses code \(error.code ?? "nil")")
    } catch {
        fputs("FAIL unexpected \(error)\n", stderr)
        exit(1)
    }
}

private func jsonData(_ object: Any) -> Data {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
        fputs("FAIL encode\n", stderr)
        exit(1)
    }
    return data
}

private func jsonObject(_ data: Data) -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("FAIL decode \(String(data: data, encoding: .utf8) ?? "")\n", stderr)
        exit(1)
    }
    return object
}
