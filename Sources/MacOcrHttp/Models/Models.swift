import Foundation
import LineMergeCore

enum RecognitionLevel: String, Codable, Sendable {
    case accurate
    case fast
}

enum ScaleMode: String, Codable, Sendable {
    /// One whole-image pass, then tile only when the page is large and the text is small.
    case auto
    /// Full resolution. Tile when either side is longer than 2048. No probe pass.
    case none
    case tile
    case downscale
}

enum TileForce: String, Codable, Sendable {
    case whole
    case tile
}

enum ScriptMode: String, Codable, Sendable {
    case hans
    case auto
}

enum LayoutMode: String, Codable, Sendable {
    case rows
    case document
}

struct OCRJob: Codable, Sendable {
    var level: RecognitionLevel
    /// nil means the server default (`zh-Hans`, `en-US`, filtered to what Vision supports).
    var languages: [String]?
    var scale: ScaleMode
    /// Overrides `OCR_HTTP_MAX_PIXEL` for this request when `scale` is `downscale`.
    var maxPixel: Int?
    /// `scale=auto` only. `whole` keeps the probe; `tile` skips it and uses the grid.
    var force: TileForce?
    /// Overrides `OCR_HTTP_TILE_MIN_GLYPH_FRAC` for this request.
    var tileMinGlyphFrac: Double?
    /// nil means: `hans` when `zh-Hans` is first and `zh-Hant` was not requested, otherwise `auto`.
    var script: ScriptMode?
    var layout: LayoutMode
    /// Drop low-confidence icon, edge-cut and corner fragments (`fragments=drop`, the default).
    var fragments: Bool = true
}

let defaultRecognitionLanguages = ["zh-Hans", "en-US"]

struct RecognitionEcho: Codable, Sendable {
    var languages: [String]
    var revision: Int
}

/// Crosses the worker pipe as JSON; every field round-trips exactly.
struct OCRPayload: Codable, Sendable {
    var text: String
    var width: Int
    var height: Int
    var scale: String
    var tiles: Int
    /// `whole` or `tiled`: the path that produced `lines`.
    var mode: String
    /// Median glyph size in original pixels: box width / width units.
    var glyphPx: Double
    /// `glyphPx` divided by the long side of the original image.
    var glyphFrac: Double
    /// Why `mode` was chosen.
    var tileDecision: String
    var elapsedMs: Int
    var languages: [String]
    var revision: Int
    var script: String
    var layout: String
    var lines: [OCRLine]
    var rows: [OCRRow]
    var blocks: [OCRBlock]
}

struct ErrorBody: Encodable {
    var ok: Bool
    var error: String
}

struct HealthBody: Encodable {
    var ok: Bool
}

struct OCRSuccessBody: Encodable {
    var ok: Bool
    var text: String
    var width: Int
    var height: Int
    var scale: String
    var tiles: Int
    var mode: String
    var glyphPx: Double
    var glyphFrac: Double
    var tileDecision: String
    var elapsedMs: Int
    /// Languages read back from the Vision request after they were assigned.
    var languages: [String]
    /// `VNRecognizeTextRequest.revision`, or the document request's revision raw value.
    var revision: Int
    /// `hans` when traditional glyphs were converted, otherwise `auto`.
    var script: String
    var layout: String
    var lines: [OCRLine]
    var rows: [OCRRow]
    var blocks: [OCRBlock]
}

struct TooLargeBody: Encodable {
    var ok: Bool
    var error: String
    var maxPixels: Int
    var width: Int
    var height: Int
}

struct StatsBody: Encodable {
    var ok: Bool
    var inFlight: Int
    var queued: Int
    var rejected: Int
    var workers: Int
    /// `task_info` `phys_footprint`, in bytes.
    var rssBytes: UInt64
}

struct LanguageCatalog: Encodable, Sendable {
    var ok: Bool
    var defaults: [String]
    var accurate: [String]
    var fast: [String]
}

struct BadRequest: Error {
    var message: String
}

enum OCREngineError: Error, CustomStringConvertible, Sendable {
    case badRequest(String)
    case vision(String)

    var description: String {
        switch self {
        case .badRequest(let message), .vision(let message):
            return message
        }
    }
}

enum ImageDecodeError: Error, CustomStringConvertible, Sendable {
    case unrecognized
    case tooLarge(width: Int, height: Int, maxPixels: Int)

    var description: String {
        switch self {
        case .unrecognized:
            return "unrecognized image data"
        case .tooLarge:
            return "image too large"
        }
    }
}
