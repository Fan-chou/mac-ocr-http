import Foundation

/// Whether a page should be recognized as one image or as tiles.
/// `glyphPx` is the median, over qualifying lines, of box width divided by
/// width units. A CJK or full-width character is 1; any other character is
/// 0.55. A line qualifies when it has at least 3 width units.
public struct TileChoice: Sendable, Equatable {
    public var mode: String
    public var glyphPx: Double
    public var glyphFrac: Double
    public var countedLines: Int
    public var tileDecision: String

    public init(mode: String, glyphPx: Double, glyphFrac: Double, countedLines: Int, tileDecision: String) {
        self.mode = mode
        self.glyphPx = glyphPx
        self.glyphFrac = glyphFrac
        self.countedLines = countedLines
        self.tileDecision = tileDecision
    }
}

public struct GlyphBox: Sendable, Equatable {
    public var text: String
    public var width: Double

    public init(text: String, width: Double) {
        self.text = text
        self.width = width
    }
}

public enum TilePolicy {
    /// Tile when glyph size / long side is below this.
    /// Chosen on a 57-item Mac set (2026-10-09): severity-weighted excess
    /// error is 0.312 at 0.012, against 0.405 at 0.011, 0.335 at 0.0125 and
    /// 0.438 at 0.014. Below 0.009 a whole pass failed 18/20 pages; at or
    /// above 0.012 it failed 0/21. Going whole by mistake costs 0.2–0.8 CER;
    /// tiling by mistake costs about 0.01–0.06.
    public static let defaultMinGlyphFrac = 0.012
    /// Probe pass long side. Vision's whole-image pass already downsamples
    /// by the long side, so a probe above this matches a native pass.
    public static let probeMaxSide = 4096
    /// One tile anyway. Stay a single pass and do not apply the fraction.
    public static let singlePassSide = 2048
    public static let minUnits = 3.0
    public static let minCountedLines = 8

    public static func widthUnits(_ text: String) -> Double {
        var units = 0.0
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { continue }
            units += wideScalar(scalar.value) ? 1 : 0.55
        }
        return units
    }

    public static func measure(width: Int, height: Int, lines: [GlyphBox]) -> (glyphPx: Double, glyphFrac: Double, countedLines: Int) {
        var sizes: [Double] = []
        sizes.reserveCapacity(lines.count)
        for line in lines {
            let units = widthUnits(line.text)
            guard units >= minUnits, line.width > 0 else { continue }
            sizes.append(line.width / units)
        }
        sizes.sort()
        let counted = sizes.count
        let rawPx = counted == 0 ? 0 : sizes[counted / 2]
        let longSide = max(width, height)
        let rawFrac = longSide > 0 ? rawPx / Double(longSide) : 0
        return (round2(rawPx), round6(rawFrac), counted)
    }

    public static func decide(
        width: Int,
        height: Int,
        lines: [GlyphBox],
        minGlyphFrac: Double = defaultMinGlyphFrac,
        force: String? = nil
    ) -> TileChoice {
        let measured = measure(width: width, height: height, lines: lines)
        let shown = String(format: "%.6f", measured.glyphFrac)
        let threshold = String(format: "%.6f", minGlyphFrac)
        let px = String(format: "%.2f", measured.glyphPx)
        let longSide = max(width, height)
        func choice(_ mode: String, _ decision: String) -> TileChoice {
            TileChoice(
                mode: mode,
                glyphPx: measured.glyphPx,
                glyphFrac: measured.glyphFrac,
                countedLines: measured.countedLines,
                tileDecision: decision
            )
        }
        if force == "tile" {
            return choice("tiled", "tiled: force=tile")
        }
        if force == "whole" {
            return choice("whole", "whole: force=whole")
        }
        if longSide <= singlePassSide {
            return choice("whole", "whole: long side \(longSide) <= \(singlePassSide)")
        }
        if measured.countedLines < minCountedLines {
            return choice(
                "tiled",
                "tiled: \(measured.countedLines) qualifying lines < \(minCountedLines)"
            )
        }
        if measured.glyphFrac < minGlyphFrac {
            return choice("tiled", "tiled: glyphFrac \(shown) < \(threshold) (glyphPx \(px))")
        }
        return choice("whole", "whole: glyphFrac \(shown) >= \(threshold) (glyphPx \(px))")
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func round6(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    /// East-Asian wide or full-width. Matches the Mac glyph fit: CJK,
    /// kana, Hangul, ideographic punctuation, and full-width forms are 1.
    private static func wideScalar(_ value: UInt32) -> Bool {
        if (0x1100...0x115F).contains(value) { return true }
        if (0x2329...0x232A).contains(value) { return true }
        if (0x2E80...0x303E).contains(value) { return true }
        if (0x3040...0xA4CF).contains(value) { return true }
        if (0xAC00...0xD7A3).contains(value) { return true }
        if (0xF900...0xFAFF).contains(value) { return true }
        if (0xFE10...0xFE19).contains(value) { return true }
        if (0xFE30...0xFE6F).contains(value) { return true }
        if (0xFF01...0xFF60).contains(value) { return true }
        if (0xFFE0...0xFFE6).contains(value) { return true }
        if (0x20000...0x2FFFD).contains(value) { return true }
        if (0x30000...0x3FFFD).contains(value) { return true }
        return false
    }
}

/// Tile geometry for the second pass. Vision's accurate recognizer drops whole
/// runs of lines once glyphs are under about 1% of the tile side, so a page of
/// small glyphs gets smaller tiles. Large glyphs keep the classic 2048 grid.
public enum AdaptiveTile {
    public static let maxLength = 2048
    public static let minLength = 1024
    public static let baseOverlap = 256
    /// Glyph height as a fraction of the tile side that Vision still reads.
    public static let targetGlyphFrac = 0.011
    /// A text line box is about 1.5 glyph heights tall. A shrunken tile
    /// overlaps by three of them, never less than the classic 256.
    public static let lineHeightPerGlyph = 1.5

    /// `glyphPx` is the median glyph height in the bitmap that will be tiled.
    public static func plan(glyphPx: Double) -> (length: Int, overlap: Int) {
        guard glyphPx.isFinite, glyphPx > 0 else { return (maxLength, baseOverlap) }
        let ideal = Int((glyphPx / targetGlyphFrac).rounded())
        let length = min(max(ideal, minLength), maxLength)
        // Three line heights, never below the classic 256. Full-size tiles keep
        // exactly 256: a page that is tiled despite huge glyphs (a poster or a
        // newspaper scan) would otherwise double its tile count for nothing,
        // and seam stitching already handles lines cut at a 2048 seam.
        let threeLines = Int((3 * lineHeightPerGlyph * glyphPx).rounded(.up))
        let overlap = length >= maxLength ? baseOverlap : min(length / 2, max(baseOverlap, threeLines))
        return (length, overlap)
    }

    /// Offsets along one axis. An axis no longer than `keepWholeUpTo` stays a
    /// single span so short lines are not cut by a needless seam.
    public static func spans(length: Int, tile: Int, overlap: Int, keepWholeUpTo: Int) -> [(offset: Int, length: Int)] {
        if length <= max(tile, keepWholeUpTo) {
            return [(0, max(length, 0))]
        }
        let step = max(1, tile - overlap)
        var offsets = [0]
        var cursor = 0
        while cursor + tile < length {
            let next = cursor + step
            let last = length - tile
            if next >= last {
                if last > offsets[offsets.count - 1] {
                    offsets.append(last)
                }
                break
            }
            offsets.append(next)
            cursor = next
        }
        return offsets.map { ($0, tile) }
    }

    /// The cross axis may stay whole up to 1.3× the tile side (and never past
    /// the 2048 cap): a 1700px-wide page with 15px glyphs still reads in full
    /// width once its height is cut to about 1360.
    public static func wholeAxisLimit(tile: Int) -> Int {
        tile >= maxLength ? maxLength : min(maxLength, Int(Double(tile) * 1.3))
    }
}
