import Darwin
import Foundation

/// Wire format between the HTTP process and an `--ocr-worker` child.
///
/// Every frame is a 4-byte big-endian length followed by that many bytes.
/// Parent -> child (child fd 0): a JSON `WorkerRequest` frame, then a raw image frame.
/// Child -> parent (child fd 3): a JSON `WorkerReply` hello once at start,
/// then exactly one `WorkerReply` per request, in order.
/// Child stdout and stderr both go to the service's stderr log.
enum WorkerWire {
    static let protocolVersion = 1
    static let workerFlag = "--ocr-worker"
    /// Child-side descriptor for replies. 0 is requests, 1 and 2 are logs.
    static let replyFD: Int32 = 3
    static let maxFrameBytes = 256 * 1024 * 1024
}

struct WorkerRequest: Codable {
    var id: UInt64
    var job: OCRJob
    var maxPixels: Int
    var maxPixel: Int
    var minGlyphFrac: Double
}

struct WorkerFailure: Codable, Error {
    /// `tooLarge`, `unrecognized`, `badRequest`, `vision`, or `internal`.
    var kind: String
    var message: String
    var width: Int?
    var height: Int?
    var maxPixels: Int?

    init(kind: String, message: String, width: Int? = nil, height: Int? = nil, maxPixels: Int? = nil) {
        self.kind = kind
        self.message = message
        self.width = width
        self.height = height
        self.maxPixels = maxPixels
    }

    init(_ error: Error) {
        switch error {
        case let decode as ImageDecodeError:
            switch decode {
            case .tooLarge(let width, let height, let maxPixels):
                self.init(kind: "tooLarge", message: decode.description, width: width, height: height, maxPixels: maxPixels)
            case .unrecognized:
                self.init(kind: "unrecognized", message: decode.description)
            }
        case let engine as OCREngineError:
            switch engine {
            case .badRequest(let message):
                self.init(kind: "badRequest", message: message)
            case .vision(let message):
                self.init(kind: "vision", message: message)
            }
        default:
            self.init(kind: "internal", message: String(describing: error))
        }
    }

    /// The error the in-process code used to throw, so HTTP mapping is unchanged.
    var asError: Error {
        switch kind {
        case "tooLarge":
            return ImageDecodeError.tooLarge(width: width ?? 0, height: height ?? 0, maxPixels: maxPixels ?? 0)
        case "unrecognized":
            return ImageDecodeError.unrecognized
        case "badRequest":
            return OCREngineError.badRequest(message)
        case "vision":
            return OCREngineError.vision(message)
        default:
            return WorkerInternalError(message: message)
        }
    }
}

/// Falls into the server's generic `catch`, which answers 500 "internal error".
struct WorkerInternalError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

struct WorkerReply: Codable {
    var id: UInt64
    /// Set only on the hello frame.
    var hello: Int?
    var pid: Int32?
    var payload: OCRPayload?
    var failure: WorkerFailure?
}

// MARK: - Blocking frame I/O (child side)

enum BlockingIO {
    /// Reads exactly `count` bytes. nil on EOF or error.
    static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        if count == 0 { return Data() }
        var data = Data(count: count)
        var offset = 0
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while offset < count {
                let n = Darwin.read(fd, base + offset, count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        return ok ? data : nil
    }

    static func readFrame(_ fd: Int32) -> Data? {
        guard let header = readExactly(fd, 4) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length <= WorkerWire.maxFrameBytes else { return nil }
        return readExactly(fd, length)
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    static func writeFrame(_ fd: Int32, _ data: Data) -> Bool {
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        return writeAll(fd, header) && writeAll(fd, data)
    }
}

// MARK: - Deadline frame I/O (parent side, non-blocking descriptors)

enum PipeError: Error, CustomStringConvertible {
    case timeout
    case closed(String)

    var description: String {
        switch self {
        case .timeout: return "timed out"
        case .closed(let why): return why
        }
    }
}

enum DeadlineIO {
    private static func wait(_ fd: Int32, events: Int16, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw PipeError.timeout }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let ms = Int32(min(remaining * 1000, 60_000).rounded(.up))
            let n = Darwin.poll(&entry, 1, max(ms, 1))
            if n > 0 { return }
            if n == 0 { continue }
            if errno == EINTR { continue }
            throw PipeError.closed("poll: \(String(cString: strerror(errno)))")
        }
    }

    static func readExactly(_ fd: Int32, _ count: Int, deadline: Date) throws -> Data {
        if count == 0 { return Data() }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw PipeError.closed("buffer") }
            while offset < count {
                let n = Darwin.read(fd, base + offset, count - offset)
                if n > 0 { offset += n; continue }
                if n == 0 { throw PipeError.closed("worker closed its reply pipe") }
                if errno == EINTR { continue }
                if errno == EAGAIN { try wait(fd, events: Int16(POLLIN), deadline: deadline); continue }
                throw PipeError.closed("read: \(String(cString: strerror(errno)))")
            }
        }
        return data
    }

    static func readFrame(_ fd: Int32, deadline: Date) throws -> Data {
        let header = try readExactly(fd, 4, deadline: deadline)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length <= WorkerWire.maxFrameBytes else { throw PipeError.closed("oversized reply frame") }
        return try readExactly(fd, length, deadline: deadline)
    }

    static func writeAll(_ fd: Int32, _ data: Data, deadline: Date) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && errno == EAGAIN { try wait(fd, events: Int16(POLLOUT), deadline: deadline); continue }
                throw PipeError.closed("write: \(String(cString: strerror(errno)))")
            }
        }
    }

    static func writeFrame(_ fd: Int32, _ data: Data, deadline: Date) throws {
        var length = UInt32(data.count).bigEndian
        let header = Data(bytes: &length, count: 4)
        try writeAll(fd, header, deadline: deadline)
        try writeAll(fd, data, deadline: deadline)
    }
}
