import Foundation

/// One recognized character with its Vision box (top-left pixels of the pass image).
/// `box` is nil for characters Vision gives no box for, such as spaces.
public struct FragmentGlyph: Sendable {
    public var text: String
    public var box: BBox?

    public init(text: String, box: BBox?) {
        self.text = text
        self.box = box
    }
}

/// One Vision observation as the filter sees it. `glyphs` may be empty when the
/// line is confident enough that per-character boxes were not requested.
public struct FragmentLine: Sendable {
    public var text: String
    public var confidence: Double
    public var bbox: BBox
    public var glyphs: [FragmentGlyph]

    public init(text: String, confidence: Double, bbox: BBox, glyphs: [FragmentGlyph]) {
        self.text = text
        self.confidence = confidence
        self.bbox = bbox
        self.glyphs = glyphs
    }
}

public enum FragmentAction: Equatable, Sendable {
    case keep
    case drop(reason: String)
    /// Drop the first `count` characters of the observation. `newLeft` is the
    /// left edge of the first kept character.
    case trimLeading(count: Int, newLeft: Double, reason: String)
}

/// Removes UI noise that Vision reads as text in small screenshots: an icon in
/// front of a label, a glyph cut in half by the crop edge, or a tiny watermark
/// in a corner. Every rule needs Vision's lowest confidence bucket, so a
/// confident observation is never changed. Run it only on a pass that covers
/// the whole image; a tile edge is not an image edge.
public enum FragmentFilter {
    /// Vision reports 0.3, 0.5 or 1.0 for CJK text; only 0.3 counts as low.
    public static let lowConfidence = 0.4

    public static func decide(lines: [FragmentLine], imageWidth: Double, imageHeight: Double) -> [FragmentAction] {
        let dominant = lines
            .filter { $0.confidence >= lowConfidence && visibleCount($0.text) >= 2 }
            .map { $0.bbox.height }
            .max() ?? 0
        return lines.indices.map { index in
            let line = lines[index]
            guard line.confidence < lowConfidence else { return .keep }
            if let reason = edgeSpeck(line, dominant: dominant, width: imageWidth, height: imageHeight) {
                return .drop(reason: reason)
            }
            if isolatedIcon(index, lines) {
                return .drop(reason: "isolated low-confidence glyph before text")
            }
            if let trim = leadingIcon(line) { return trim }
            if let trim = leadingCut(line) { return trim }
            return .keep
        }
    }

    /// A short low-confidence observation far smaller than the main text that
    /// touches an image edge, such as a corner watermark.
    static func edgeSpeck(_ line: FragmentLine, dominant: Double, width: Double, height: Double) -> String? {
        let count = visibleCount(line.text)
        guard count >= 1, count <= 3, dominant > 0 else { return nil }
        let ratio = line.bbox.height / dominant
        let margin = max(3, line.bbox.height * 0.25)
        let b = line.bbox
        let touches = b.x <= margin || b.y <= margin || width - (b.x + b.width) <= margin || height - (b.y + b.height) <= margin
        if ratio <= 0.35, touches { return "tiny low-confidence fragment at image edge" }
        if count <= 2, ratio <= 0.25 { return "tiny low-confidence fragment" }
        return nil
    }

    /// A one-character observation on the same row just left of a longer one,
    /// separated by a gap: usually an icon.
    static func isolatedIcon(_ index: Int, _ lines: [FragmentLine]) -> Bool {
        let line = lines[index]
        guard visibleCount(line.text) == 1 else { return false }
        let b = line.bbox
        for (other, candidate) in lines.enumerated() where other != index {
            let o = candidate.bbox
            guard visibleCount(candidate.text) >= 2 else { continue }
            let overlap = min(b.y + b.height, o.y + o.height) - max(b.y, o.y)
            guard overlap >= 0.5 * min(b.height, o.height) else { continue }
            let gap = o.x - (b.x + b.width)
            if gap >= 0.3 * o.height, gap <= 3 * o.height { return true }
        }
        return false
    }

    /// The first glyph is wider than the text after it and either is CJK or is
    /// followed by a space: an icon Vision read as a character.
    static func leadingIcon(_ line: FragmentLine) -> FragmentAction? {
        guard let split = firstAndRest(line) else { return nil }
        let (first, firstBox, restStart) = split
        let rest = Array(line.glyphs[restStart...])
        let cjkWidths = rest.filter { isCJK($0.text) }.compactMap { $0.box?.width }
        guard cjkWidths.count >= 2, cjkWidths.count * 2 >= rest.filter({ $0.box != nil }).count else { return nil }
        let spaced = restStart > 1
        guard isCJK(first) || spaced else { return nil }
        let med = median(cjkWidths)
        guard med > 0, firstBox.width >= 1.3 * med, firstBox.width >= 1.2 * line.bbox.height else { return nil }
        guard let newLeft = rest.first(where: { $0.box != nil })?.box?.x else { return nil }
        return .trimLeading(count: restStart, newLeft: newLeft, reason: "wide low-confidence leading glyph (icon)")
    }

    /// The first glyph sits on the left image edge and is narrower than the
    /// CJK text after it: a character cut in half by the crop.
    static func leadingCut(_ line: FragmentLine) -> FragmentAction? {
        guard let split = firstAndRest(line) else { return nil }
        let (first, firstBox, restStart) = split
        guard isCJK(first) else { return nil }
        let rest = Array(line.glyphs[restStart...])
        let cjkWidths = rest.filter { isCJK($0.text) }.compactMap { $0.box?.width }
        guard cjkWidths.count >= 3 else { return nil }
        let margin = max(2, 0.3 * line.bbox.height)
        guard firstBox.x <= margin else { return nil }
        let med = median(cjkWidths)
        guard med > 0, firstBox.width <= 0.8 * med else { return nil }
        guard let newLeft = rest.first(where: { $0.box != nil })?.box?.x else { return nil }
        return .trimLeading(count: restStart, newLeft: newLeft, reason: "low-confidence glyph cut by the left edge")
    }

    /// First visible glyph, its box, and the index where the rest begins (after any spaces).
    private static func firstAndRest(_ line: FragmentLine) -> (String, BBox, Int)? {
        let glyphs = line.glyphs
        guard glyphs.count >= 3, let firstBox = glyphs[0].box, !isSpace(glyphs[0].text) else { return nil }
        var restStart = 1
        while restStart < glyphs.count, isSpace(glyphs[restStart].text) { restStart += 1 }
        guard glyphs.count - restStart >= 2 else { return nil }
        return (glyphs[0].text, firstBox, restStart)
    }

    /// Applies `trimLeading` to a string: drops `count` characters.
    public static func trimmed(_ text: String, count: Int) -> String {
        String(text.dropFirst(count)).trimmingCharacters(in: .whitespaces)
    }

    static func visibleCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    static func isSpace(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace }
    }

    static func isCJK(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
