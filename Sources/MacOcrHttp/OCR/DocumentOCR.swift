import CoreGraphics
import Foundation
import LineMergeCore
import Vision

/// `layout=document` runs one `RecognizeDocumentsRequest` on the full bitmap.
/// It does not tile: paragraph geometry would not survive a crop grid.
///
/// The request is in the macOS 26 Vision SDK. `OCR_HTTP_HAS_DOCUMENT_LAYOUT`
/// is set for that SDK. Without the flag, or on an older OS, the call returns
/// 400 instead of referencing a missing symbol.
enum DocumentOCR {
    /// Longest side, in pixels, sent to `RecognizeDocumentsRequest`.
    static let maxLongEdge = 8192
    /// Pixel count sent to `RecognizeDocumentsRequest`. 4284×5712 fits; a 7000×5000 page does too.
    static let maxPixels = 40_000_000

    static func recognize(
        decoded: DecodedImage,
        languages: [String],
        level: RecognitionLevel,
        scale: ScaleMode,
        script: ScriptMode,
        started: Date
    ) throws -> OCRPayload {
        let width = decoded.image.width
        let height = decoded.image.height
        if width > maxLongEdge || height > maxLongEdge || width * height > maxPixels {
            throw OCREngineError.badRequest(
                "document layout supports up to \(maxLongEdge)px on a side and \(maxPixels) pixels; this bitmap is \(width)x\(height). It is not tiled or shrunk."
            )
        }
        #if OCR_HTTP_HAS_DOCUMENT_LAYOUT
        if #available(macOS 26, *) {
            return try recognizeDocument(
                decoded: decoded,
                languages: languages,
                level: level,
                scale: scale,
                script: script,
                started: started
            )
        }
        #endif
        throw OCREngineError.badRequest("layout=document requires macOS 26 and a Vision SDK that includes RecognizeDocumentsRequest")
    }
}

#if OCR_HTTP_HAS_DOCUMENT_LAYOUT
@available(macOS 26, *)
private func recognizeDocument(
    decoded: DecodedImage,
    languages: [String],
    level: RecognitionLevel,
    scale: ScaleMode,
    script: ScriptMode,
    started: Date
) throws -> OCRPayload {
    _ = level
    var request = RecognizeDocumentsRequest()
    var options = request.textRecognitionOptions
    if languages.isEmpty {
        options.automaticallyDetectLanguage = true
        options.useLanguageCorrection = true
    } else {
        options.automaticallyDetectLanguage = false
        options.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        options.useLanguageCorrection = prefersLanguageCorrection(languages)
    }
    request.textRecognitionOptions = options
    let applied = request.textRecognitionOptions.recognitionLanguages.map { language in
        [language.languageCode?.identifier, language.script?.identifier, language.region?.identifier]
            .compactMap { $0 }
            .joined(separator: "-")
    }
    let revision = (RecognizeDocumentsRequest.supportedRevisions.firstIndex(of: request.revision) ?? -1) + 1

    let observations = try autoreleasepool {
        try performDocuments(request, on: decoded.image)
    }
    let scaleX = Double(decoded.originalWidth) / Double(max(decoded.image.width, 1))
    let scaleY = Double(decoded.originalHeight) / Double(max(decoded.image.height, 1))
    let mapped = mapDocument(
        observations,
        width: decoded.image.width,
        height: decoded.image.height,
        scaleX: scaleX,
        scaleY: scaleY
    )
    let page = PageText(lines: mapped.lines, rows: mapped.rows, blocks: mapped.blocks, text: mapped.text)
    let scripted = applyScript(page, script)
    let measured = TilePolicy.measure(
        width: decoded.originalWidth,
        height: decoded.originalHeight,
        lines: scripted.lines.map { GlyphBox(text: $0.text, width: $0.bbox.width) }
    )
    let elapsed = max(0, Int(Date().timeIntervalSince(started) * 1000))
    return OCRPayload(
        text: scripted.text,
        width: decoded.originalWidth,
        height: decoded.originalHeight,
        scale: scale.rawValue,
        tiles: 1,
        mode: "whole",
        glyphPx: measured.glyphPx,
        glyphFrac: measured.glyphFrac,
        tileDecision: "whole: layout=document is not tiled",
        elapsedMs: elapsed,
        languages: applied,
        revision: revision,
        script: script.rawValue,
        layout: LayoutMode.document.rawValue,
        lines: scripted.lines,
        rows: scripted.rows,
        blocks: scripted.blocks
    )
}

/// `perform` is async. The worker queue stays synchronous: this waits on a
/// semaphore, and the task is detached so it does not need the blocked queue.
@available(macOS 26, *)
private func performDocuments(
    _ request: RecognizeDocumentsRequest,
    on image: CGImage
) throws -> [DocumentObservation] {
    let box = DocumentBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached(priority: .userInitiated) {
        do {
            box.result = .success(try await request.perform(on: image))
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    switch box.result {
    case .success(let observations):
        return observations
    case .failure(let error):
        throw OCREngineError.vision(error.localizedDescription)
    case .none:
        throw OCREngineError.vision("document recognition returned no result")
    }
}

@available(macOS 26, *)
private final class DocumentBox: @unchecked Sendable {
    var result: Result<[DocumentObservation], Error>?
}

@available(macOS 26, *)
private func mapDocument(
    _ observations: [DocumentObservation],
    width: Int,
    height: Int,
    scaleX: Double,
    scaleY: Double
) -> (lines: [OCRLine], rows: [OCRRow], blocks: [OCRBlock], text: String) {
    guard let document = observations.first?.document else {
        return ([], [], [], "")
    }
    var lines: [OCRLine] = []
    var rows: [OCRRow] = []
    var blocks: [OCRBlock] = []
    for paragraph in document.paragraphs {
        let start = rows.count
        if paragraph.lines.isEmpty {
            appendDocumentLine(
                text: paragraph.transcript,
                confidence: 0,
                rect: paragraph.boundingRegion.boundingBox.cgRect,
                width: width,
                height: height,
                scaleX: scaleX,
                scaleY: scaleY,
                lines: &lines,
                rows: &rows
            )
        } else {
            for piece in paragraph.lines {
                let candidate = piece.topCandidates(1).first
                appendDocumentLine(
                    text: candidate?.string ?? piece.transcript,
                    confidence: Double(candidate?.confidence ?? 0),
                    rect: piece.boundingRegion.boundingBox.cgRect,
                    width: width,
                    height: height,
                    scaleX: scaleX,
                    scaleY: scaleY,
                    lines: &lines,
                    rows: &rows
                )
            }
        }
        if rows.count > start {
            let bbox = scaledBox(
                Geometry.pixelBBox(
                    normalizedBottomLeft: paragraph.boundingRegion.boundingBox.cgRect,
                    width: width,
                    height: height
                ),
                scaleX: scaleX,
                scaleY: scaleY
            )
            blocks.append(OCRBlock(bbox: bbox, rowIndices: Array(start..<rows.count)))
        }
    }
    let text = rows.map(\.text).joined(separator: "\n")
    return (lines, rows, blocks, text)
}

@available(macOS 26, *)
private func appendDocumentLine(
    text: String,
    confidence: Double,
    rect: CGRect,
    width: Int,
    height: Int,
    scaleX: Double,
    scaleY: Double,
    lines: inout [OCRLine],
    rows: inout [OCRRow]
) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    let bbox = scaledBox(
        Geometry.pixelBBox(normalizedBottomLeft: rect, width: width, height: height),
        scaleX: scaleX,
        scaleY: scaleY
    )
    let rounded = (confidence * 10000).rounded() / 10000
    let lineIndex = lines.count
    lines.append(OCRLine(text: trimmed, confidence: rounded, bbox: bbox, quad: axisQuad(bbox)))
    rows.append(OCRRow(text: trimmed, bbox: bbox, confidence: rounded, lineIndices: [lineIndex]))
}
#endif

private func scaledBox(_ box: BBox, scaleX: Double, scaleY: Double) -> BBox {
    BBox(
        x: round2(box.x * scaleX),
        y: round2(box.y * scaleY),
        width: round2(box.width * scaleX),
        height: round2(box.height * scaleY)
    )
}

private func axisQuad(_ box: BBox) -> Quad {
    Quad(
        topLeft: Point(x: box.x, y: box.y),
        topRight: Point(x: box.x + box.width, y: box.y),
        bottomRight: Point(x: box.x + box.width, y: box.y + box.height),
        bottomLeft: Point(x: box.x, y: box.y + box.height)
    )
}
