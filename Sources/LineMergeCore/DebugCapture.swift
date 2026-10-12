import Foundation

/// One chat or Responses message, with image payloads removed.
public struct DebugMessageSummary: Equatable, Sendable {
    public var role: String
    public var texts: [String]
    public var imageCount: Int

    public init(role: String, texts: [String], imageCount: Int) {
        self.role = role
        self.texts = texts
        self.imageCount = imageCount
    }
}

/// One Vision pass. Several images on one `/v1` request produce several passes.
public struct DebugPassSummary: Equatable, Sendable {
    public var elapsedMs: Int
    public var mode: String
    public var tiles: Int
    public var glyphFrac: Double
    public var text: String
    public var rows: [String]

    public init(elapsedMs: Int, mode: String, tiles: Int, glyphFrac: Double, text: String, rows: [String]) {
        self.elapsedMs = elapsedMs
        self.mode = mode
        self.tiles = tiles
        self.glyphFrac = glyphFrac
        self.text = text
        self.rows = rows
    }
}

/// Sidecar written next to the image files. The property list is the whole schema.
public struct DebugCaptureMeta: Equatable, Sendable {
    public var timestamp: String
    public var endpoint: String
    public var clientIP: String
    public var status: Int
    public var errorCode: String?
    public var elapsedMs: Int?
    public var mode: String?
    public var tiles: Int?
    public var glyphFrac: Double?
    public var text: String?
    public var rows: [String]?
    public var passes: [DebugPassSummary]?
    public var messages: [DebugMessageSummary]?

    public init(
        timestamp: String,
        endpoint: String,
        clientIP: String,
        status: Int,
        errorCode: String?,
        elapsedMs: Int?,
        mode: String?,
        tiles: Int?,
        glyphFrac: Double?,
        text: String?,
        rows: [String]?,
        passes: [DebugPassSummary]?,
        messages: [DebugMessageSummary]?
    ) {
        self.timestamp = timestamp
        self.endpoint = endpoint
        self.clientIP = clientIP
        self.status = status
        self.errorCode = errorCode
        self.elapsedMs = elapsedMs
        self.mode = mode
        self.tiles = tiles
        self.glyphFrac = glyphFrac
        self.text = text
        self.rows = rows
        self.passes = passes
        self.messages = messages
    }
}

public enum DebugCapture {
    /// Keys `metaJSON` is allowed to emit. Anything else is a leak.
    public static let metaKeys: Set<String> = [
        "timestamp", "endpoint", "clientIP", "status", "errorCode",
        "elapsedMs", "mode", "tiles", "glyphFrac", "text", "rows",
        "passes", "messages",
    ]
    public static let messageKeys: Set<String> = ["role", "texts", "imageCount"]
    public static let passKeys: Set<String> = ["elapsedMs", "mode", "tiles", "glyphFrac", "text", "rows"]

    /// `passes` fills the top-level Vision fields when there is exactly one.
    /// A 2xx with no passes (a text-only probe) records `text` as `""`.
    public static func makeMeta(
        timestamp: String,
        endpoint: String,
        clientIP: String,
        status: Int,
        errorCode: String?,
        passes: [DebugPassSummary],
        messages: [DebugMessageSummary]?
    ) -> DebugCaptureMeta {
        let elapsed = passes.isEmpty ? nil : passes.reduce(0) { $0 + $1.elapsedMs }
        let text: String?
        let rows: [String]?
        if passes.isEmpty {
            text = status < 400 ? "" : nil
            rows = nil
        } else {
            text = passes.map(\.text).joined(separator: "\n\n")
            rows = passes.flatMap(\.rows)
        }
        let only = passes.count == 1 ? passes[0] : nil
        return DebugCaptureMeta(
            timestamp: timestamp,
            endpoint: endpoint,
            clientIP: clientIP,
            status: status,
            errorCode: errorCode,
            elapsedMs: elapsed,
            mode: only?.mode,
            tiles: only?.tiles,
            glyphFrac: only?.glyphFrac,
            text: text,
            rows: rows,
            passes: passes.isEmpty ? nil : passes,
            messages: messages
        )
    }

    /// Roles, text parts, and image counts from a chat or Responses body.
    /// Image URLs, data URLs, and any field that is not a role or text part are dropped.
    public static func messageSummaries(json: Data) -> [DebugMessageSummary] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            return []
        }
        var result: [DebugMessageSummary] = []
        if let instructions = object["instructions"] as? String {
            result.append(DebugMessageSummary(role: "instructions", texts: [redactText(instructions)], imageCount: 0))
        }
        if let messages = object["messages"] as? [Any] {
            result.append(contentsOf: summaries(from: messages))
        } else if let input = object["input"] as? String {
            result.append(DebugMessageSummary(role: "user", texts: [redactText(input)], imageCount: 0))
        } else if let input = object["input"] as? [Any] {
            result.append(contentsOf: summaries(from: input))
        }
        return result
    }

    /// Drops a `;base64,` payload. Ordinary prompt text is unchanged.
    public static func redactText(_ text: String) -> String {
        guard let range = text.range(of: ";base64,", options: .caseInsensitive) else {
            return text
        }
        return String(text[..<range.lowerBound]) + ";base64,[redacted]"
    }

    public static func metaJSON(_ meta: DebugCaptureMeta) throws -> Data {
        let object = jsonObject(meta)
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// Unauthenticated requests are not OCR jobs. Recording a 401 would let
    /// LAN traffic that fails the bearer check evict real captures.
    public static func records(status: Int) -> Bool {
        status != 401
    }

    /// `existingOldestFirst` is already oldest-first. Returns the prefix that
    /// must be deleted so the remaining count is `maxCount`.
    public static func evictionIDs(existingOldestFirst: [String], maxCount: Int) -> [String] {
        let limit = max(0, maxCount)
        let overflow = existingOldestFirst.count - limit
        if overflow <= 0 { return [] }
        return Array(existingOldestFirst.prefix(overflow))
    }

    /// Extension for the saved file. The bytes themselves are not rewritten.
    public static func fileExtension(for image: Data) -> String {
        let bytes = [UInt8](image.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "webp"
        }
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            return "heic"
        }
        return "bin"
    }

    private static func summaries(from items: [Any]) -> [DebugMessageSummary] {
        var result: [DebugMessageSummary] = []
        for item in items {
            guard let message = item as? [String: Any] else { continue }
            let role = sanitizeRole(message["role"] as? String)
            var texts: [String] = []
            var imageCount = 0
            collect(message["content"], texts: &texts, imageCount: &imageCount)
            result.append(DebugMessageSummary(role: role, texts: texts, imageCount: imageCount))
        }
        return result
    }

    private static func collect(_ content: Any?, texts: inout [String], imageCount: inout Int) {
        if let text = content as? String {
            texts.append(redactText(text))
            return
        }
        guard let parts = content as? [Any] else { return }
        for part in parts {
            if let text = part as? String {
                texts.append(redactText(text))
                continue
            }
            guard let part = part as? [String: Any] else { continue }
            let type = (part["type"] as? String)?.lowercased() ?? ""
            if type == "image_url" || type == "input_image" || type == "image" || part["image_url"] != nil {
                imageCount += 1
                continue
            }
            if let text = part["text"] as? String {
                texts.append(redactText(text))
            }
        }
    }

    private static func sanitizeRole(_ role: String?) -> String {
        let trimmed = role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.count > 32 { return "unknown" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "unknown"
        }
        return trimmed
    }

    private static func jsonObject(_ meta: DebugCaptureMeta) -> [String: Any] {
        var object: [String: Any] = [
            "timestamp": meta.timestamp,
            "endpoint": meta.endpoint,
            "clientIP": meta.clientIP,
            "status": meta.status,
        ]
        if let errorCode = meta.errorCode { object["errorCode"] = errorCode }
        if let elapsedMs = meta.elapsedMs { object["elapsedMs"] = elapsedMs }
        if let mode = meta.mode { object["mode"] = mode }
        if let tiles = meta.tiles { object["tiles"] = tiles }
        if let glyphFrac = meta.glyphFrac { object["glyphFrac"] = glyphFrac }
        if let text = meta.text { object["text"] = text }
        if let rows = meta.rows { object["rows"] = rows }
        if let passes = meta.passes {
            object["passes"] = passes.map { pass -> [String: Any] in
                [
                    "elapsedMs": pass.elapsedMs,
                    "mode": pass.mode,
                    "tiles": pass.tiles,
                    "glyphFrac": pass.glyphFrac,
                    "text": pass.text,
                    "rows": pass.rows,
                ]
            }
        }
        if let messages = meta.messages {
            object["messages"] = messages.map { message -> [String: Any] in
                [
                    "role": message.role,
                    "texts": message.texts,
                    "imageCount": message.imageCount,
                ]
            }
        }
        return object
    }
}

/// Writes one directory per OCR request and deletes the oldest past `maxCount`.
/// Callers that must not block do the `save` on their own queue.
public final class DebugCaptureStore: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: String
    private let maxCount: Int

    public init(directory: String, maxCount: Int) {
        self.directory = directory
        self.maxCount = max(0, maxCount)
    }

    public func save(meta: DebugCaptureMeta, images: [Data]) throws {
        lock.lock()
        defer { lock.unlock() }
        let files = FileManager.default
        try files.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
        let id = nextID()
        let entry = (directory as NSString).appendingPathComponent(id)
        try files.createDirectory(atPath: entry, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry)
        do {
            let metaPath = (entry as NSString).appendingPathComponent("meta.json")
            try DebugCapture.metaJSON(meta).write(to: URL(fileURLWithPath: metaPath), options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaPath)
            for (index, image) in images.enumerated() {
                let name = "image-\(index).\(DebugCapture.fileExtension(for: image))"
                let path = (entry as NSString).appendingPathComponent(name)
                try image.write(to: URL(fileURLWithPath: path), options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        } catch {
            try? files.removeItem(atPath: entry)
            throw error
        }
        for old in DebugCapture.evictionIDs(existingOldestFirst: entryIDs(), maxCount: maxCount) {
            try files.removeItem(atPath: (directory as NSString).appendingPathComponent(old))
        }
    }

    private func nextID() -> String {
        let next = (entryIDs().compactMap(Int.init).max() ?? 0) + 1
        if next < 1_000_000 {
            return String(format: "%06d", next)
        }
        return String(next)
    }

    private func entryIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { Int($0) != nil }.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }
}
