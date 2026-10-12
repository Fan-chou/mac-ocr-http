import Foundation

/// OpenAI-compatible request parsing and response bytes for `/v1/*`.
///
/// Image rule: OCR every image in the last message whose role is `user`.
/// When that message has none, or there is no user message, OCR every image
/// in the conversation, in order. Several images are the caller's to join;
/// this type only returns them in that order. Text prompts are not
/// instructions. A line `ocr-language: <tag>` (or `recognition-language`)
/// is the only hint that is read, and only for a short allowlist.
public enum OpenAICompat {
    public static let fingerprint = "fp_macocr"
    public static let owner = "mac-ocr-http"

    public struct Image: Equatable {
        public var data: Data
        public var mediaType: String

        public init(data: Data, mediaType: String) {
            self.data = data
            self.mediaType = mediaType
        }
    }

    public enum Wire: String {
        case chat
        case responses
    }

    public struct Parsed: Equatable {
        public var images: [Image]
        public var stream: Bool
        public var includeUsage: Bool
        public var model: String?
        public var languages: [String]?
        public var promptScalars: Int
        public var wire: Wire

        public init(
            images: [Image],
            stream: Bool,
            includeUsage: Bool,
            model: String?,
            languages: [String]?,
            promptScalars: Int,
            wire: Wire
        ) {
            self.images = images
            self.stream = stream
            self.includeUsage = includeUsage
            self.model = model
            self.languages = languages
            self.promptScalars = promptScalars
            self.wire = wire
        }
    }

    public struct APIError: Error, Equatable {
        public var status: Int
        public var message: String
        public var type: String
        public var param: String?
        public var code: String?

        public init(status: Int, message: String, type: String, param: String?, code: String?) {
            self.status = status
            self.message = message
            self.type = type
            self.param = param
            self.code = code
        }

        public static func invalid(
            _ message: String,
            param: String? = nil,
            code: String? = nil,
            status: Int = 400
        ) -> APIError {
            APIError(status: status, message: message, type: "invalid_request_error", param: param, code: code)
        }
    }

    public struct Usage: Equatable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int

        public init(promptScalars: Int, completion: String) {
            promptTokens = promptScalars
            completionTokens = completion.unicodeScalars.count
            totalTokens = promptTokens + completionTokens
        }
    }

    public static func parseChat(_ data: Data) throws -> Parsed {
        let object = try jsonObject(data)
        return try parseMessages(object, wire: .chat, messagesKey: "messages")
    }

    public static func parseResponses(_ data: Data) throws -> Parsed {
        let object = try jsonObject(data)
        var texts: [String] = []
        if let instructions = object["instructions"] as? String {
            texts.append(instructions)
        }
        let input = object["input"]
        let messages: [Any]
        if input == nil, let fallback = object["messages"] {
            messages = try messageList(fallback, param: "messages")
        } else if let text = input as? String {
            messages = [["role": "user", "content": text]]
        } else if let one = input as? [String: Any] {
            messages = [one]
        } else if let list = input as? [Any] {
            messages = try responsesInput(list)
        } else if input == nil {
            throw APIError.invalid(
                "no image in the request",
                param: "input",
                code: "missing_image"
            )
        } else {
            throw APIError.invalid("input must be a string, a message, or an array", param: "input")
        }
        return try finish(object, messages: messages, extraText: texts, wire: .responses)
    }

    public static func errorJSON(_ error: APIError) -> Data {
        jsonData([
            "error": [
                "message": error.message,
                "type": error.type,
                "param": error.param.map { $0 as Any } ?? NSNull(),
                "code": error.code.map { $0 as Any } ?? NSNull(),
            ],
        ])
    }

    public static func modelsList(id: String, created: Int) -> Data {
        jsonData([
            "object": "list",
            "data": [modelObject(id: id, created: created)],
        ])
    }

    public static func modelJSON(id: String, created: Int) -> Data {
        jsonData(modelObject(id: id, created: created))
    }

    public static func chatCompletionJSON(
        id: String,
        created: Int,
        model: String,
        content: String,
        usage: Usage
    ) -> Data {
        jsonData(chatCompletionObject(id: id, created: created, model: model, content: content, usage: usage))
    }

    public static func responsesJSON(
        id: String,
        created: Int,
        model: String,
        content: String,
        usage: Usage
    ) -> Data {
        jsonData(responsesObject(id: id, created: created, model: model, content: content, usage: usage))
    }

    /// SSE events, each already framed as `data: …\n\n` (and `event:` for Responses).
    /// The caller writes them with chunked encoding on HTTP/1.1, or raw on HTTP/1.0.
    public static func sseEvents(
        wire: Wire,
        id: String,
        created: Int,
        model: String,
        content: String,
        usage: Usage,
        includeUsage: Bool
    ) -> [Data] {
        switch wire {
        case .chat:
            return chatSSE(id: id, created: created, model: model, content: content, usage: usage, includeUsage: includeUsage)
        case .responses:
            return responsesSSE(id: id, created: created, model: model, content: content, usage: usage)
        }
    }

    public static func contentPieces(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        let lines = text.components(separatedBy: "\n")
        var pieces: [String] = []
        for index in lines.indices {
            if index < lines.count - 1 {
                pieces.append(lines[index] + "\n")
            } else if !lines[index].isEmpty {
                pieces.append(lines[index])
            }
        }
        return pieces
    }

    /// One HTTP/1.1 chunk, including the trailing CRLF. Size is lowercase hex.
    public static func chunkFrame(_ payload: Data) -> Data {
        var out = Data(String(payload.count, radix: 16).utf8)
        out.append(contentsOf: [13, 10])
        out.append(payload)
        out.append(contentsOf: [13, 10])
        return out
    }

    public static func chunkTerminator() -> Data {
        Data("0\r\n\r\n".utf8)
    }

    public static func completionID(prefix: String) -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if prefix.hasSuffix("-") || prefix.hasSuffix("_") {
            return prefix + raw
        }
        return prefix + "-" + raw
    }
}

private extension OpenAICompat {
    static func modelObject(id: String, created: Int) -> [String: Any] {
        [
            "id": id,
            "object": "model",
            "created": created,
            "owned_by": owner,
        ]
    }

    static func chatCompletionObject(
        id: String,
        created: Int,
        model: String,
        content: String,
        usage: Usage
    ) -> [String: Any] {
        [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": model,
            "system_fingerprint": fingerprint,
            "choices": [[
                "index": 0,
                "message": [
                    "role": "assistant",
                    "content": content,
                ],
                "finish_reason": "stop",
            ]],
            "usage": chatUsage(usage),
        ]
    }

    static func responsesObject(
        id: String,
        created: Int,
        model: String,
        content: String,
        usage: Usage
    ) -> [String: Any] {
        let messageID = completionID(prefix: "msg_")
        return [
            "id": id,
            "object": "response",
            "created_at": created,
            "status": "completed",
            "model": model,
            "output_text": content,
            "output": [[
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [[
                    "type": "output_text",
                    "text": content,
                ]],
            ]],
            "usage": [
                "input_tokens": usage.promptTokens,
                "output_tokens": usage.completionTokens,
                "total_tokens": usage.totalTokens,
            ],
        ]
    }

    static func chatUsage(_ usage: Usage) -> [String: Int] {
        [
            "prompt_tokens": usage.promptTokens,
            "completion_tokens": usage.completionTokens,
            "total_tokens": usage.totalTokens,
        ]
    }

    static func chatSSE(
        id: String,
        created: Int,
        model: String,
        content: String,
        usage: Usage,
        includeUsage: Bool
    ) -> [Data] {
        var events: [Data] = []
        events.append(sseData(chunk(
            id: id,
            created: created,
            model: model,
            choices: [[
                "index": 0,
                "delta": ["role": "assistant"],
                "finish_reason": NSNull(),
            ]],
            usage: nil
        )))
        for piece in contentPieces(content) {
            events.append(sseData(chunk(
                id: id,
                created: created,
                model: model,
                choices: [[
                    "index": 0,
                    "delta": ["content": piece],
                    "finish_reason": NSNull(),
                ]],
                usage: nil
            )))
        }
        events.append(sseData(chunk(
            id: id,
            created: created,
            model: model,
            choices: [[
                "index": 0,
                "delta": [String: String](),
                "finish_reason": "stop",
            ]],
            usage: nil
        )))
        if includeUsage {
            events.append(sseData(chunk(
                id: id,
                created: created,
                model: model,
                choices: [Any](),
                usage: chatUsage(usage)
            )))
        }
        events.append(Data("data: [DONE]\n\n".utf8))
        return events
    }

    static func responsesSSE(
        id: String,
        created: Int,
        model: String,
        content: String,
        usage: Usage
    ) -> [Data] {
        var events: [Data] = []
        for piece in contentPieces(content) {
            events.append(sseEvent(
                name: "response.output_text.delta",
                object: [
                    "type": "response.output_text.delta",
                    "delta": piece,
                ]
            ))
        }
        events.append(sseEvent(
            name: "response.completed",
            object: [
                "type": "response.completed",
                "response": responsesObject(id: id, created: created, model: model, content: content, usage: usage),
            ]
        ))
        events.append(Data("data: [DONE]\n\n".utf8))
        return events
    }

    static func chunk(
        id: String,
        created: Int,
        model: String,
        choices: [Any],
        usage: [String: Int]?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "system_fingerprint": fingerprint,
            "choices": choices,
        ]
        if let usage {
            object["usage"] = usage
        }
        return object
    }

    static func sseData(_ object: [String: Any]) -> Data {
        var out = Data("data: ".utf8)
        out.append(jsonData(object))
        out.append(Data("\n\n".utf8))
        return out
    }

    static func sseEvent(name: String, object: [String: Any]) -> Data {
        var out = Data("event: \(name)\ndata: ".utf8)
        out.append(jsonData(object))
        out.append(Data("\n\n".utf8))
        return out
    }

    static func jsonData(_ object: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return Data(#"{"error":{"message":"internal error","type":"server_error","param":null,"code":"internal_error"}}"#.utf8)
        }
        return data
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw APIError.invalid("invalid JSON", param: nil, code: "invalid_json")
        }
        guard let dict = object as? [String: Any] else {
            throw APIError.invalid("JSON object required", code: "invalid_json")
        }
        return dict
    }

    static func parseMessages(_ object: [String: Any], wire: Wire, messagesKey: String) throws -> Parsed {
        guard let raw = object[messagesKey] else {
            throw APIError.invalid("no image in the request", param: messagesKey, code: "missing_image")
        }
        let messages = try messageList(raw, param: messagesKey)
        return try finish(object, messages: messages, extraText: [], wire: wire)
    }

    static func messageList(_ raw: Any, param: String) throws -> [Any] {
        if let list = raw as? [Any] {
            return list
        }
        throw APIError.invalid("\(param) must be an array", param: param)
    }

    static func responsesInput(_ list: [Any]) throws -> [Any] {
        if list.isEmpty { return [] }
        let parts = list.allSatisfy { item in
            guard let dict = item as? [String: Any] else { return false }
            return dict["type"] != nil && dict["role"] == nil && dict["content"] == nil
        }
        if parts {
            return [["role": "user", "content": list]]
        }
        return list
    }

    static func finish(
        _ object: [String: Any],
        messages: [Any],
        extraText: [String],
        wire: Wire
    ) throws -> Parsed {
        var collected: [Collected] = []
        for (index, item) in messages.enumerated() {
            guard let message = item as? [String: Any] else {
                throw APIError.invalid("message \(index) must be an object", param: "messages")
            }
            collected.append(try collect(message))
        }
        let images = selectImages(collected)
        if images.isEmpty {
            throw APIError.invalid(
                "no image in the request",
                param: wire == .chat ? "messages" : "input",
                code: "missing_image"
            )
        }
        var texts = extraText
        var scalars = extraText.reduce(0) { $0 + $1.unicodeScalars.count }
        for message in collected {
            scalars += message.scalars
            texts.append(contentsOf: message.texts)
        }
        return Parsed(
            images: images,
            stream: jsonBool(object["stream"]) == true,
            includeUsage: includeUsage(object["stream_options"]),
            model: modelString(object["model"]),
            languages: languageHint(from: texts),
            promptScalars: scalars,
            wire: wire
        )
    }

    struct Collected {
        var role: String
        var images: [Image]
        var texts: [String]
        var scalars: Int
    }

    static func selectImages(_ messages: [Collected]) -> [Image] {
        if let lastUser = messages.last(where: { $0.role == "user" }), !lastUser.images.isEmpty {
            return lastUser.images
        }
        return messages.flatMap(\.images)
    }

    static func collect(_ message: [String: Any]) throws -> Collected {
        let role = (message["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var images: [Image] = []
        var texts: [String] = []
        var scalars = 0
        if let content = message["content"] {
            if content is NSNull {
                // no content
            } else if let text = content as? String {
                texts.append(text)
                scalars += text.unicodeScalars.count
            } else if let parts = content as? [Any] {
                for part in parts {
                    let read = try readPart(part)
                    images.append(contentsOf: read.images)
                    texts.append(contentsOf: read.texts)
                    scalars += read.scalars
                }
            } else if let one = content as? [String: Any] {
                let read = try readPart(one)
                images.append(contentsOf: read.images)
                texts.append(contentsOf: read.texts)
                scalars += read.scalars
            }
        }
        return Collected(role: role, images: images, texts: texts, scalars: scalars)
    }

    struct PartRead {
        var images: [Image] = []
        var texts: [String] = []
        var scalars: Int = 0
    }

    static func readPart(_ part: Any) throws -> PartRead {
        if part is NSNull { return PartRead() }
        if let text = part as? String {
            return PartRead(images: [], texts: [text], scalars: text.unicodeScalars.count)
        }
        guard let object = part as? [String: Any] else {
            throw APIError.invalid("content parts must be objects or strings", param: "messages")
        }
        let type = (object["type"] as? String)?.lowercased() ?? ""
        var read = PartRead()
        if type == "text" || type == "input_text" || (type.isEmpty && object["text"] is String && object["image_url"] == nil) {
            if let text = object["text"] as? String {
                read.texts.append(text)
                read.scalars += text.unicodeScalars.count
            }
        }
        let isImage = type == "image_url" || type == "input_image" || object["image_url"] != nil
        if isImage {
            let image = try image(from: object)
            read.images.append(image)
        } else if type == "file" || type == "input_file" {
            throw APIError.invalid(
                "file ids and non-image files are not accepted",
                param: "image_url",
                code: "invalid_image_url"
            )
        }
        return read
    }

    static func image(from object: [String: Any]) throws -> Image {
        if let raw = object["image_url"] {
            return try image(fromURLField: raw)
        }
        if let raw = object["url"] {
            return try image(fromURLField: raw)
        }
        throw APIError.invalid(
            "image_url is required",
            param: "image_url",
            code: "invalid_image_url"
        )
    }

    static func image(fromURLField raw: Any) throws -> Image {
        if let text = raw as? String {
            return try decodeDataURL(text)
        }
        if let object = raw as? [String: Any] {
            guard let text = object["url"] as? String else {
                throw APIError.invalid(
                    "image_url.url must be a base64 data URL",
                    param: "image_url",
                    code: "invalid_image_url"
                )
            }
            return try decodeDataURL(text)
        }
        throw APIError.invalid(
            "image_url must be a data URL string or an object with url",
            param: "image_url",
            code: "invalid_image_url"
        )
    }

    static func decodeDataURL(_ raw: String) throws -> Image {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file:") {
            throw APIError.invalid(
                "http(s) and file URLs are not accepted",
                param: "image_url",
                code: "invalid_image_url"
            )
        }
        guard lower.hasPrefix("data:") else {
            throw APIError.invalid(
                "only base64 data URLs are accepted",
                param: "image_url",
                code: "invalid_image_url"
            )
        }
        guard let comma = text.firstIndex(of: ",") else {
            throw APIError.invalid("invalid data URL", param: "image_url", code: "invalid_image_url")
        }
        let meta = text[..<comma].lowercased()
        guard meta.contains(";base64") else {
            throw APIError.invalid(
                "data URL must be base64",
                param: "image_url",
                code: "invalid_image_url"
            )
        }
        let mime = mediaType(meta)
        if !mime.isEmpty && mime != "application/octet-stream" && !mime.hasPrefix("image/") {
            throw APIError.invalid(
                "data URL media type must be an image",
                param: "image_url",
                code: "invalid_image_url"
            )
        }
        let payload = String(text[text.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw APIError.invalid("invalid base64 image", param: "image_url", code: "invalid_base64")
        }
        return Image(data: data, mediaType: mime.isEmpty ? "application/octet-stream" : mime)
    }

    static func mediaType(_ meta: String) -> String {
        var type = meta
        if type.hasPrefix("data:") {
            type = String(type.dropFirst(5))
        }
        let mime = type.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return mime
    }

    static func jsonBool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        // JSON integers are NSNumbers too. Only boolean objC types count,
        // so `stream: 1` does not turn streaming on.
        if let number = value as? NSNumber {
            let kind = String(cString: number.objCType)
            if kind == "c" || kind == "B" {
                return number.boolValue
            }
            return nil
        }
        if let flag = value as? Bool {
            return flag
        }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        return nil
    }

    static func includeUsage(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else { return false }
        return jsonBool(object["include_usage"]) == true
    }

    static func modelString(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber, !(value is Bool) {
            return number.stringValue
        }
        return nil
    }

    static func languageHint(from texts: [String]) -> [String]? {
        let keys = ["ocr-language", "ocr_language", "recognition-language", "recognition_language"]
        var found: String?
        for text in texts {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let lower = line.lowercased()
                for key in keys where lower.hasPrefix(key) {
                    var rest = line.dropFirst(key.count).drop { $0 == " " || $0 == "\t" }
                    guard let separator = rest.first, separator == ":" || separator == "=" else { continue }
                    rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
                    let token = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
                    if let mapped = mapLanguage(String(token)) {
                        found = mapped
                    }
                }
            }
        }
        return found.map { [$0] }
    }

    static func mapLanguage(_ token: String) -> String? {
        switch token.lowercased() {
        case "zh", "zh-hans":
            return "zh-Hans"
        case "zh-hant":
            return "zh-Hant"
        case "en", "en-us":
            return "en-US"
        case "ja", "ja-jp":
            return "ja-JP"
        case "ko", "ko-kr":
            return "ko-KR"
        default:
            return nil
        }
    }
}
