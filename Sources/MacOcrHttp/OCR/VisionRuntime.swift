import Foundation
import Vision

/// One serial queue per worker. `recognize` does not `await` and does not hop
/// through an actor: the body runs synchronously on that queue, so worker N
/// cannot start a second `VNImageRequestHandler.perform`.
final class VisionPool: @unchecked Sendable {
    private let queues: [DispatchQueue]
    private let languages = LanguageCache()

    init(workers: Int) {
        let count = max(1, workers)
        queues = (0..<count).map { index in
            DispatchQueue(label: "macocr.vision.\(index)")
        }
    }

    func recognize(
        on index: Int,
        holder: DataHolder,
        job: OCRJob,
        maxPixels: Int,
        maxPixel: Int,
        minGlyphFrac: Double
    ) throws -> OCRPayload {
        let queue = queues[index]
        var result: Result<OCRPayload, Error>?
        let longEdge: Int? = job.scale == .downscale ? (job.maxPixel ?? maxPixel) : nil
        queue.sync {
            result = autoreleasepool { () -> Result<OCRPayload, Error> in
                let started = Date()
                let decoded: DecodedImage
                do {
                    decoded = try autoreleasepool {
                        let bytes = holder.data
                        holder.data = Data()
                        return try decodeImage(bytes, maxPixels: maxPixels, longEdge: longEdge)
                    }
                } catch {
                    return .failure(error)
                }
                do {
                    let payload = try autoreleasepool {
                        try self.recognize(decoded: decoded, job: job, started: started, minGlyphFrac: minGlyphFrac)
                    }
                    return .success(payload)
                } catch {
                    return .failure(error)
                }
            }
        }
        switch result {
        case .success(let payload):
            return payload
        case .failure(let error):
            throw error
        case .none:
            throw OCREngineError.vision("missing OCR result")
        }
    }

    func languageCatalog() throws -> LanguageCatalog {
        autoreleasepool {
            let accurate = languages.languages(fast: false)
            let fast = languages.languages(fast: true)
            return LanguageCatalog(
                ok: true,
                defaults: defaultRecognitionLanguages,
                accurate: orderedSupported(accurate),
                fast: orderedSupported(fast)
            )
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
            force: job.force
        )
    }
}

/// Holds image bytes so the HTTP body can be released, and these bytes can be
/// dropped after decode, before `perform`.
final class DataHolder: @unchecked Sendable {
    var data: Data
    init(_ data: Data) { self.data = data }
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
