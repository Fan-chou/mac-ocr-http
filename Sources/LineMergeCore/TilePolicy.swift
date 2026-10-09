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
