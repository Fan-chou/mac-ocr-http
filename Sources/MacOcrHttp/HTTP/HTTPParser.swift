import Darwin
import Foundation
import LineMergeCore

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
    var version: String
}

struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    static func json<T: Encodable>(
        _ status: Int,
        _ payload: T,
        headers: [String: String] = [:]
    ) -> HTTPResponse {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload) else {
            let fallback = Data(#"{"ok":false,"error":"internal error"}"#.utf8)
            return HTTPResponse(
                status: 500,
                reason: "Internal Server Error",
                headers: headers,
                body: fallback
            )
        }
        return HTTPResponse(
            status: status,
            reason: reasonPhrase(status),
            headers: headers,
            body: data
        )
    }

    static func health() -> HTTPResponse {
        HTTPResponse(
            status: 200,
            reason: "OK",
            headers: [:],
            body: Data(#"{"ok":true}"#.utf8)
        )
    }

    static func unauthorized() -> HTTPResponse {
        json(401, ErrorBody(ok: false, error: "unauthorized"), headers: ["WWW-Authenticate": "Bearer"])
    }
}

enum HTTPReadError: Error {
    case malformed(String)
    case headersTooLarge
    case bodyTooLarge(path: String)
    case lengthRequired
    case timeout
    case closed
    case io(String)

    var response: HTTPResponse {
        switch self {
        case .malformed(let message):
            return HTTPResponse.json(400, ErrorBody(ok: false, error: message))
        case .headersTooLarge:
            return HTTPResponse.json(400, ErrorBody(ok: false, error: "headers too large"))
        case .bodyTooLarge(_):
            return HTTPResponse.json(413, ErrorBody(ok: false, error: "request body exceeds limit"))
        case .lengthRequired:
            return HTTPResponse.json(411, ErrorBody(ok: false, error: "Content-Length required"))
        case .timeout:
            return HTTPResponse.json(408, ErrorBody(ok: false, error: "request timeout"))
        case .closed:
            return HTTPResponse.json(400, ErrorBody(ok: false, error: "incomplete request"))
        case .io:
            return HTTPResponse.json(400, ErrorBody(ok: false, error: "connection failed"))
        }
    }
}

/// HTTP/1.0 and HTTP/1.1 origin-form requests with Content-Length bodies.
/// Chunked transfer encoding is rejected. One request per connection.
enum HTTPReader {
    static func read(fd: Int32, maxHeaderBytes: Int, maxBodyBytes: Int) throws -> HTTPRequest {
        let marker = Data([13, 10, 13, 10])
        var buffer = Data()
        while buffer.range(of: marker) == nil {
            if buffer.count > maxHeaderBytes {
                throw HTTPReadError.headersTooLarge
            }
            let chunk = try readSome(fd, maxCount: 4096)
            if chunk.isEmpty { throw HTTPReadError.closed }
            buffer.append(chunk)
        }
        guard let separator = buffer.range(of: marker) else {
            throw HTTPReadError.malformed("missing header terminator")
        }
        let headerBytes = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
        if headerBytes.count > maxHeaderBytes {
            throw HTTPReadError.headersTooLarge
        }
        let prefetched = buffer.subdata(in: separator.upperBound..<buffer.endIndex)
        let head = try parseHead(headerBytes)
        if head.headers["transfer-encoding"] != nil {
            throw HTTPReadError.malformed("Transfer-Encoding is not supported; send Content-Length")
        }
        let length: Int
        if let contentLength = head.contentLength {
            if contentLength > maxBodyBytes {
                throw HTTPReadError.bodyTooLarge(path: head.path)
            }
            length = contentLength
        } else if head.method == "POST" {
            throw HTTPReadError.lengthRequired
        } else {
            length = 0
        }

        var body = Data(prefetched.prefix(length))
        let expect = head.headers["expect"]?.lowercased() ?? ""
        if expect.contains("100-continue") && body.count < length {
            try writeAll(fd, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        while body.count < length {
            let need = length - body.count
            let chunk = try readSome(fd, maxCount: min(need, 64 * 1024))
            if chunk.isEmpty { throw HTTPReadError.closed }
            body.append(chunk)
        }
        return HTTPRequest(
            method: head.method,
            path: head.path,
            query: head.query,
            headers: head.headers,
            body: body,
            version: head.version
        )
    }
}

enum HTTPWriter {
    static func send(_ fd: Int32, _ response: HTTPResponse) throws {
        var header = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        header += "Content-Type: application/json; charset=utf-8\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "X-Content-Type-Options: nosniff\r\n"
        for (name, value) in response.headers {
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"
        var bytes = Data(header.utf8)
        bytes.append(response.body)
        try writeAll(fd, bytes)
    }

    /// SSE after the body is already known. HTTP/1.1 uses chunked framing.
    /// HTTP/1.0 has no chunks; the following connection close ends the body.
    static func sendEventStream(
        _ fd: Int32,
        version: String,
        events: [Data],
        headers: [String: String]
    ) throws {
        let http11 = version == "HTTP/1.1"
        var header = "\(http11 ? "HTTP/1.1" : "HTTP/1.0") 200 OK\r\n"
        header += "Content-Type: text/event-stream; charset=utf-8\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n"
        header += "X-Content-Type-Options: nosniff\r\n"
        if http11 {
            header += "Transfer-Encoding: chunked\r\n"
        }
        for (name, value) in headers {
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"
        try writeAll(fd, Data(header.utf8))
        if http11 {
            for event in events {
                try writeAll(fd, OpenAICompat.chunkFrame(event))
            }
            try writeAll(fd, OpenAICompat.chunkTerminator())
        } else {
            for event in events {
                try writeAll(fd, event)
            }
        }
    }
}

private struct ParsedHead {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var contentLength: Int?
    var version: String
}

private func parseHead(_ data: Data) throws -> ParsedHead {
    let lines = try splitCRLFLines(data)
    guard let requestLine = lines.first, !requestLine.isEmpty else {
        throw HTTPReadError.malformed("empty request")
    }
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3 else {
        throw HTTPReadError.malformed("bad request line")
    }
    let method = String(parts[0])
    let target = String(parts[1])
    let version = String(parts[2])
    guard isUpperToken(method) else {
        throw HTTPReadError.malformed("bad method")
    }
    guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
        throw HTTPReadError.malformed("unsupported HTTP version")
    }
    guard target.hasPrefix("/"), isVisibleASCII(target) else {
        throw HTTPReadError.malformed("only origin-form paths are accepted")
    }

    let pathPart: String
    let queryPart: String
    if let question = target.firstIndex(of: "?") {
        pathPart = String(target[..<question])
        queryPart = String(target[target.index(after: question)...])
    } else {
        pathPart = target
        queryPart = ""
    }
    if pathPart.contains("..") || pathPart.contains("\\") || pathPart.contains("//") {
        throw HTTPReadError.malformed("invalid path")
    }
    var path = pathPart
    if path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }

    if lines.count > 65 {
        throw HTTPReadError.malformed("too many headers")
    }
    var headers: [String: String] = [:]
    var contentLength: Int?
    for line in lines.dropFirst() {
        if line.isEmpty {
            throw HTTPReadError.malformed("empty header line")
        }
        if line.first == " " || line.first == "\t" {
            throw HTTPReadError.malformed("obsolete line folding is not supported")
        }
        guard let colon = line.firstIndex(of: ":") else {
            throw HTTPReadError.malformed("header missing colon")
        }
        let name = String(line[..<colon])
        guard isHeaderName(name) else {
            throw HTTPReadError.malformed("bad header name")
        }
        var value = line[line.index(after: colon)...]
        while value.first == " " || value.first == "\t" { value = value.dropFirst() }
        while value.last == " " || value.last == "\t" { value = value.dropLast() }
        let text = String(value)
        guard text.unicodeScalars.allSatisfy({ $0.value == 9 || $0.value >= 32 }) else {
            throw HTTPReadError.malformed("bad header value")
        }
        let key = name.lowercased()
        if headers[key] != nil, key == "content-length" || key == "transfer-encoding" || key == "authorization" {
            throw HTTPReadError.malformed("duplicate \(name) header")
        }
        headers[key] = text
        if key == "content-length" {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0 >= "0" && $0 <= "9" }), let parsed = Int(text), parsed >= 0 else {
                throw HTTPReadError.malformed("bad Content-Length")
            }
            contentLength = parsed
        }
    }
    return ParsedHead(
        method: method,
        path: path,
        query: parseQuery(queryPart),
        headers: headers,
        contentLength: contentLength,
        version: version
    )
}

private func splitCRLFLines(_ data: Data) throws -> [String] {
    var lines: [String] = []
    var start = data.startIndex
    var index = data.startIndex
    while index < data.endIndex {
        if data[index] == 0 {
            throw HTTPReadError.malformed("NUL in headers")
        }
        if data[index] == 10 {
            var end = index
            if end > start, data[data.index(before: end)] == 13 {
                end = data.index(before: end)
            }
            let slice = data.subdata(in: start..<end)
            guard let line = String(data: slice, encoding: .isoLatin1) else {
                throw HTTPReadError.malformed("bad headers")
            }
            lines.append(line)
            start = data.index(after: index)
        }
        index = data.index(after: index)
    }
    // The header/body separator is CRLF CRLF. That match consumes the CRLF that
    // terminated the last header, so the final line has no LF of its own.
    if start != data.endIndex {
        var end = data.endIndex
        if end > start, data[data.index(before: end)] == 13 {
            end = data.index(before: end)
        }
        let slice = data.subdata(in: start..<end)
        if slice.contains(0) {
            throw HTTPReadError.malformed("NUL in headers")
        }
        guard let line = String(data: slice, encoding: .isoLatin1) else {
            throw HTTPReadError.malformed("bad headers")
        }
        lines.append(line)
    }
    return lines
}

private func parseQuery(_ query: String) -> [String: String] {
    guard !query.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
        let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = percentDecode(String(pieces[0])).lowercased()
        let value = pieces.count > 1 ? percentDecode(String(pieces[1])) : ""
        if !key.isEmpty {
            result[key] = value
        }
    }
    return result
}

func percentDecode(_ text: String) -> String {
    var decoded = ""
    var bytes: [UInt8] = []
    var index = text.startIndex

    func flush() {
        guard !bytes.isEmpty else { return }
        decoded += String(decoding: bytes, as: UTF8.self)
        bytes.removeAll(keepingCapacity: true)
    }

    while index < text.endIndex {
        let character = text[index]
        if character == "+" {
            flush()
            decoded.append(" ")
            index = text.index(after: index)
            continue
        }
        if character == "%", text.distance(from: index, to: text.endIndex) >= 3 {
            let first = text[text.index(after: index)]
            let second = text[text.index(index, offsetBy: 2)]
            if let byte = UInt8(String([first, second]), radix: 16) {
                bytes.append(byte)
                index = text.index(index, offsetBy: 3)
                continue
            }
        }
        flush()
        decoded.append(character)
        index = text.index(after: index)
    }
    flush()
    return decoded
}

private func isUpperToken(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { (0x41...0x5A).contains($0.value) }
}

private func isVisibleASCII(_ text: String) -> Bool {
    text.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
}

private func isHeaderName(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
        let value = scalar.value
        if value == 0x3A { return false }
        return (0x21...0x7E).contains(value)
    }
}

func reasonPhrase(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 408: return "Request Timeout"
    case 411: return "Length Required"
    case 413: return "Payload Too Large"
    case 415: return "Unsupported Media Type"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default: return "Error"
    }
}

private func readSome(_ fd: Int32, maxCount: Int) throws -> Data {
    var buffer = [UInt8](repeating: 0, count: maxCount)
    while true {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(fd, base, maxCount)
        }
        if count > 0 {
            return Data(buffer.prefix(count))
        }
        if count == 0 {
            return Data()
        }
        let error = errno
        if error == EINTR { continue }
        if error == EAGAIN || error == EWOULDBLOCK || error == ETIMEDOUT {
            throw HTTPReadError.timeout
        }
        throw HTTPReadError.io(String(cString: strerror(error)))
    }
}

func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var sent = 0
        while sent < raw.count {
            let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
            if count > 0 {
                sent += count
                continue
            }
            let error = errno
            if count < 0, error == EINTR { continue }
            if error == EAGAIN || error == EWOULDBLOCK || error == ETIMEDOUT {
                throw HTTPReadError.timeout
            }
            throw HTTPReadError.io(String(cString: strerror(error)))
        }
    }
}

func mediaType(from header: String?) -> String {
    guard let header else { return "" }
    let type = header.split(separator: ";", maxSplits: 1).first ?? ""
    return type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
