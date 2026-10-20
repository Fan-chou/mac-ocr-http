import CoreGraphics
import CoreText
import Foundation
import Vision

/// Runs inside an `--ocr-worker` child process (see `Worker/`). The worker
/// calls `recognize` from its one serial queue, so a child never has two
/// `VNImageRequestHandler.perform` calls in flight. The body is synchronous:
/// no `await`, no actor hop.
final class VisionRecognizer: @unchecked Sendable {
    private let languages = LanguageCache()

    func recognize(
        holder: DataHolder,
        job: OCRJob,
        maxPixels: Int,
        maxPixel: Int,
        minGlyphFrac: Double
    ) throws -> OCRPayload {
        let longEdge: Int? = job.scale == .downscale ? (job.maxPixel ?? maxPixel) : nil
        return try autoreleasepool { () throws -> OCRPayload in
            let started = Date()
            let decoded = try autoreleasepool { () throws -> DecodedImage in
                let local = holder.data
                holder.data = Data()
                return try decodeImage(local, maxPixels: maxPixels, longEdge: longEdge)
            }
            return try autoreleasepool {
                try self.recognize(decoded: decoded, job: job, started: started, minGlyphFrac: minGlyphFrac)
            }
        }
    }

    /// Loads the default-language model once so the first real request in a
    /// fresh worker is not slower than in a warm one. Errors are ignored: a
    /// real request on a broken worker fails and is retried on a new one.
    func warmUp() {
        autoreleasepool {
            _ = languages.languages(fast: false)
            guard let image = warmUpImage() else { return }
            let selected = defaultRecognitionLanguages.filter { languages.languages(fast: false).contains($0) }
            _ = try? OCREngine.lines(image: image, languages: selected, level: .accurate)
        }
    }

    private func recognize(decoded: DecodedImage, job: OCRJob, started: Date, minGlyphFrac: Double) throws -> OCRPayload {
        let supported = languages.languages(fast: job.level == .fast)
        let selected = try OCREngine.resolveLanguages(requested: job.languages, supported: supported)
        let script = OCREngine.effectiveScript(requested: job.script, languages: selected)
        if job.layout == .document {
            return try DocumentOCR.recognize(
                decoded: decoded,
                languages: selected,
                level: job.level,
                scale: job.scale,
                script: script,
                started: started
            )
        }
        return try ImageOCR.recognize(
            decoded: decoded,
            languages: selected,
            level: job.level,
            scale: job.scale,
            script: script,
            started: started,
            minGlyphFrac: job.tileMinGlyphFrac ?? minGlyphFrac,
            force: job.force,
            fragments: job.fragments
        )
    }
}

/// A small black-on-white bitmap with a few CJK and Latin glyphs, drawn with
/// CoreText, so warm-up loads the recognizer and not only the detector.
private func warmUpImage() -> CGImage? {
    let width = 480, height = 96
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("PingFang SC" as CFString, 40, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "文字识别 OCR 2048", attributes: attributes))
    context.textPosition = CGPoint(x: 16, y: 30)
    CTLineDraw(line, context)
    return context.makeImage()
}

/// Holds image bytes so the HTTP body can be released, and these bytes can be
/// dropped after decode, before `perform`.
final class DataHolder: @unchecked Sendable {
    var data: Data
    init(_ data: Data) { self.data = data }
}

extension LanguageCache {
    /// `GET /languages`. Listing languages does not run recognition, so the
    /// HTTP process answers it without a worker round trip.
    func catalog() -> LanguageCatalog {
        autoreleasepool {
            LanguageCatalog(
                ok: true,
                defaults: defaultRecognitionLanguages,
                accurate: orderedSupported(languages(fast: false)),
                fast: orderedSupported(languages(fast: true))
            )
        }
    }
}

/// Supported-language lists are the only cross-request cache.
final class LanguageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var accurate: [String]?
    private var fast: [String]?

    func languages(fast wantFast: Bool) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if wantFast, let fast { return fast }
        if !wantFast, let accurate { return accurate }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = wantFast ? .fast : .accurate
        let list = (try? request.supportedRecognitionLanguages()) ?? []
        if wantFast {
            fast = list
        } else {
            accurate = list
        }
        return list
    }
}
