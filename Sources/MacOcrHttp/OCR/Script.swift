import CoreFoundation
import Foundation
import LineMergeCore

func traditionalToSimplified(_ text: String) -> String {
    let mutable = NSMutableString(string: text)
    let transformed: String
    if CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false) {
        transformed = mutable as String
    } else {
        transformed = text
    }
    return shinjitaiToSimplified(transformed)
}

func applyScript(_ page: PageText, _ script: ScriptMode) -> PageText {
    guard script == .hans else { return page }
    let lines = page.lines.map { line in
        OCRLine(
            text: traditionalToSimplified(line.text),
            confidence: line.confidence,
            bbox: line.bbox,
            quad: line.quad
        )
    }
    let rows = page.rows.map { row in
        OCRRow(
            text: traditionalToSimplified(row.text),
            bbox: row.bbox,
            confidence: row.confidence,
            lineIndices: row.lineIndices
        )
    }
    return PageText(
        lines: lines,
        rows: rows,
        blocks: page.blocks,
        text: rows.map(\.text).joined(separator: "\n")
    )
}

/// Folds full-width punctuation on code-like lines (no CJK) to ASCII.
func applyCodePunct(_ page: PageText) -> PageText {
    let lines = page.lines.map { line in
        OCRLine(text: CodePunct.fold(line.text), confidence: line.confidence, bbox: line.bbox, quad: line.quad)
    }
    let rows = page.rows.map { row in
        OCRRow(text: CodePunct.fold(row.text), bbox: row.bbox, confidence: row.confidence, lineIndices: row.lineIndices)
    }
    return PageText(lines: lines, rows: rows, blocks: page.blocks, text: CodePunct.foldText(page.text))
}
