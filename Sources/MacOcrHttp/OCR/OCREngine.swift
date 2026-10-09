import CoreGraphics
import Foundation
import LineMergeCore
import Vision

func prefersLanguageCorrection(_ languages: [String]) -> Bool {
    for language in languages {
        let lower = language.lowercased()
        if lower.hasPrefix("zh") || lower.hasPrefix("ja") {
            return false
        }
    }
    return true
}

func orderedSupported(_ supported: [String]) -> [String] {
    var result: [String] = []
    let known = Set(supported)
    for language in defaultRecognitionLanguages where known.contains(language) {
        result.append(language)
    }
    for language in supported where !result.contains(language) {
        result.append(language)
    }
    return result
}

enum OCREngine {
    static func resolveLanguages(requested: [String]?, supported: [String]) throws -> [String] {
        let supportedSet = Set(supported)
        guard let requested else {
            return defaultRecognitionLanguages.filter { supportedSet.contains($0) }
        }
        let cleaned = requested
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if cleaned.isEmpty {
            return defaultRecognitionLanguages.filter { supportedSet.contains($0) }
        }
        if cleaned.count > 8 {
            throw OCREngineError.badRequest("at most 8 recognition languages")
        }
        let missing = cleaned.filter { !supportedSet.contains($0) }
        if !missing.isEmpty {
            let list = orderedSupported(supported).joined(separator: ", ")
            throw OCREngineError.badRequest(
                "unsupported languages: \(missing.joined(separator: ", ")); supported: \(list)"
            )
        }
        return cleaned
    }

    /// `hans` converts traditional to simplified unless the caller asked for `zh-Hant`.
    static func effectiveScript(requested: ScriptMode?, languages: [String]) -> ScriptMode {
        let asksHant = languages.contains { $0.lowercased().hasPrefix("zh-hant") }
        if asksHant { return .auto }
        if let requested { return requested }
        if languages.first?.lowercased().hasPrefix("zh-hans") == true { return .hans }
        return .auto
    }

    /// One Vision pass. Boxes are top-left pixels of this image, not yet placed on the page.
    /// `echo` is what the request reports after assignment, not the caller's list.
    static func lines(
        image: CGImage,
        languages: [String],
        level: RecognitionLevel
    ) throws -> (lines: [OCRLine], echo: RecognitionEcho) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw OCREngineError.vision("empty image")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level == .fast ? .fast : .accurate
        // Detection has to be off before languages are assigned. Leaving the
        // default `true` makes Vision ignore `recognitionLanguages`.
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages
            request.usesLanguageCorrection = prefersLanguageCorrection(languages)
        }
        let echo = RecognitionEcho(languages: request.recognitionLanguages, revision: request.revision)

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCREngineError.vision(error.localizedDescription)
        }

        let observations = request.results ?? []
        var lines: [OCRLine] = []
        lines.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let quad = Quad(
                topLeft: Geometry.pixelPoint(
                    normalizedBottomLeft: observation.topLeft,
                    width: width,
                    height: height
                ),
                topRight: Geometry.pixelPoint(
                    normalizedBottomLeft: observation.topRight,
                    width: width,
                    height: height
                ),
                bottomRight: Geometry.pixelPoint(
                    normalizedBottomLeft: observation.bottomRight,
                    width: width,
                    height: height
                ),
                bottomLeft: Geometry.pixelPoint(
                    normalizedBottomLeft: observation.bottomLeft,
                    width: width,
                    height: height
                )
            )
            lines.append(OCRLine(
                text: text,
                confidence: (Double(candidate.confidence) * 10000).rounded() / 10000,
                bbox: Geometry.pixelBBox(
                    normalizedBottomLeft: observation.boundingBox,
                    width: width,
                    height: height
                ),
                quad: quad
            ))
        }
        return (lines, echo)
    }
}
