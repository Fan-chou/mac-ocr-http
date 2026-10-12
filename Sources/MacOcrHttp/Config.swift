import Darwin
import Foundation
import LineMergeCore

struct AppConfig: Sendable {
    var hosts: [String]
    var port: UInt16
    var token: String
    var maxBodyBytes: Int
    var maxPixels: Int
    /// Long-edge cap used only when the request asks for `scale=downscale`.
    var maxPixel: Int
    var visionWorkers: Int
    var queueMax: Int
    var queueTimeoutMs: Int
    /// `scale=auto`: tile when glyph size / long side is below this.
    var tileMinGlyphFrac: Double
    /// Model id listed by `GET /v1/models`. Chat requests may send any model string.
    var openAIModel: String
    /// `nil` unless `OCR_HTTP_DEBUG_CAPTURE_DIR` is set. Off by default.
    var debugCaptureDir: String?
    var debugCaptureMax: Int

    static let defaultHosts = ["127.0.0.1"]
    static let defaultPort: UInt16 = 8741
    static let defaultMaxBodyBytes = 20 * 1024 * 1024
    static let defaultMaxPixels = 100_000_000
    static let defaultMaxPixel = 4096
    static let defaultVisionWorkers = 2
    static let defaultQueueMax = 64
    static let defaultQueueTimeoutMs = 180_000
    static let defaultTileMinGlyphFrac = TilePolicy.defaultMinGlyphFrac
    static let defaultOpenAIModel = "mac-ocr"
    static let defaultDebugCaptureMax = 50

    static func load() throws -> AppConfig {
        let hostArgument = try parseArguments()
        let hosts = try parseHosts(hostArgument ?? ProcessInfo.processInfo.environment["OCR_HTTP_HOST"])
        let port = try parsePort()
        let token = try loadToken()
        let maxBodyBytes = clampedEnv(
            "OCR_HTTP_MAX_BODY_BYTES",
            default: defaultMaxBodyBytes,
            min: 1 * 1024 * 1024,
            max: 32 * 1024 * 1024
        )
        let maxPixels = clampedEnv(
            "OCR_HTTP_MAX_PIXELS",
            default: defaultMaxPixels,
            min: 1_000_000,
            max: 200_000_000
        )
        let maxPixel = clampedEnv(
            "OCR_HTTP_MAX_PIXEL",
            default: defaultMaxPixel,
            min: 1024,
            max: 8192
        )
        let visionWorkers = clampedEnv(
            "OCR_HTTP_VISION_WORKERS",
            default: defaultVisionWorkers,
            min: 1,
            max: 4
        )
        let queueMax = clampedEnv(
            "OCR_HTTP_QUEUE_MAX",
            default: defaultQueueMax,
            min: 1,
            max: 256
        )
        let queueTimeoutMs = clampedEnv(
            "OCR_HTTP_QUEUE_TIMEOUT_MS",
            default: defaultQueueTimeoutMs,
            min: 1,
            max: 300_000
        )
        let env = ProcessInfo.processInfo.environment
        let tileMinGlyphFrac = try parseTileMinGlyphFrac(
            env["OCR_HTTP_TILE_MIN_GLYPH_FRAC"],
            legacy: env["OCR_HTTP_TILE_MIN_TEXT_FRAC"]
        )
        let openAIModel = try parseOpenAIModel(env["OCR_HTTP_OPENAI_MODEL"])
        let debugCaptureDir = try parseDebugCaptureDir(env["OCR_HTTP_DEBUG_CAPTURE_DIR"])
        let debugCaptureMax = clampedEnv(
            "OCR_HTTP_DEBUG_CAPTURE_MAX",
            default: defaultDebugCaptureMax,
            min: 1,
            max: 10_000
        )
        return AppConfig(
            hosts: hosts,
            port: port,
            token: token,
            maxBodyBytes: maxBodyBytes,
            maxPixels: maxPixels,
            maxPixel: maxPixel,
            visionWorkers: visionWorkers,
            queueMax: queueMax,
            queueTimeoutMs: queueTimeoutMs,
            tileMinGlyphFrac: tileMinGlyphFrac,
            openAIModel: openAIModel,
            debugCaptureDir: debugCaptureDir,
            debugCaptureMax: debugCaptureMax
        )
    }
}

struct ConfigError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Returns the `--host` value if given (same syntax and checks as `OCR_HTTP_HOST`).
private func parseArguments() throws -> String? {
    let args = Array(CommandLine.arguments.dropFirst())
    var host: String?
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg == "--help" || arg == "-h" {
            printUsage()
            Darwin.exit(0)
        }
        if arg == "--port" || arg.hasPrefix("--port=") {
            throw ConfigError("set OCR_HTTP_PORT instead of --port")
        }
        if arg == "--host" || arg.hasPrefix("--host=") {
            let value: String
            if let eq = arg.range(of: "--host=") {
                value = String(arg[eq.upperBound...])
            } else {
                index += 1
                guard index < args.count else {
                    throw ConfigError("missing value for --host")
                }
                value = args[index]
            }
            host = value
            index += 1
            continue
        }
        throw ConfigError("unknown argument \(arg); pass --help")
    }
    return host
}

/// Comma-separated IPv4 list. Only 127.0.0.0/8 and RFC1918 private ranges are
/// allowed. Wildcards (0.0.0.0, *, empty), hostnames, IPv6 and public addresses
/// are a fatal config error.
func parseHosts(_ raw: String?) throws -> [String] {
    let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text.isEmpty { return AppConfig.defaultHosts }
    var hosts: [String] = []
    for part in text.split(separator: ",", omittingEmptySubsequences: false) {
        let host = part.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = try validateListenHost(host)
        let canonical = ipv4String(address)
        if !hosts.contains(canonical) { hosts.append(canonical) }
    }
    return hosts
}

func validateListenHost(_ host: String) throws -> in_addr {
    let refuse = { (why: String) in
        ConfigError("refusing OCR_HTTP_HOST entry '\(host)': \(why). Allowed: 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16; never 0.0.0.0 or a wildcard")
    }
    if host.isEmpty { throw refuse("empty entry") }
    if host == "*" || host == "0.0.0.0" || host == "::" || host.lowercased() == "any" {
        throw refuse("wildcard address")
    }
    // Strict dotted quad: inet_pton(AF_INET) on Darwin accepts only a.b.c.d.
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
        throw refuse("not a literal IPv4 address")
    }
    var address = in_addr()
    let rc = host.withCString { inet_pton(AF_INET, $0, &address) }
    guard rc == 1 else { throw refuse("not a literal IPv4 address") }
    let value = UInt32(bigEndian: address.s_addr)
    let a = value >> 24, b = (value >> 16) & 0xff
    if value == 0 { throw refuse("wildcard address") }
    let allowed = a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
    guard allowed else { throw refuse("not loopback or a private LAN address") }
    return address
}

func ipv4String(_ address: in_addr) -> String {
    let value = UInt32(bigEndian: address.s_addr)
    return "\(value >> 24).\((value >> 16) & 0xff).\((value >> 8) & 0xff).\(value & 0xff)"
}

private func printUsage() {
    let text = """
    mac-ocr-http — Apple Vision OCR over HTTP

    Listens on each address in OCR_HTTP_HOST (or --host), default 127.0.0.1.
    Only 127.0.0.0/8 and private 10/8, 172.16/12, 192.168/16 IPv4 literals are
    accepted; 0.0.0.0, wildcards, hostnames, IPv6 and public addresses are refused.

    Environment:
      OCR_HTTP_HOST             Comma-separated IPv4 list (default: 127.0.0.1)
      OCR_HTTP_TOKEN            Bearer token (required unless the token file exists)
      OCR_HTTP_TOKEN_FILE       Token file, mode 0600 (default: ~/Library/Application Support/MacOcrHttp/token)
      OCR_HTTP_PORT             TCP port (default: \(AppConfig.defaultPort))
      OCR_HTTP_MAX_BODY_BYTES   Request body cap, 1 MiB...32 MiB (default: \(AppConfig.defaultMaxBodyBytes))
      OCR_HTTP_MAX_PIXELS       Decoded pixel cap, 1000000...200000000 (default: \(AppConfig.defaultMaxPixels))
      OCR_HTTP_MAX_PIXEL        Downscale long edge, 1024...8192 (default: \(AppConfig.defaultMaxPixel))
      OCR_HTTP_VISION_WORKERS   Serial Vision workers, 1...4 (default: \(AppConfig.defaultVisionWorkers))
      OCR_HTTP_QUEUE_MAX        OCR wait queue, 1...256 (default: \(AppConfig.defaultQueueMax))
      OCR_HTTP_QUEUE_TIMEOUT_MS Queue wait, 1...300000 ms (default: \(AppConfig.defaultQueueTimeoutMs))
      OCR_HTTP_TILE_MIN_GLYPH_FRAC  scale=auto glyph/long-side threshold, 0.001...0.2 (default: \(AppConfig.defaultTileMinGlyphFrac))
      OCR_HTTP_TILE_MIN_TEXT_FRAC   deprecated alias of OCR_HTTP_TILE_MIN_GLYPH_FRAC
      OCR_HTTP_OPENAI_MODEL     Model id for GET /v1/models (default: \(AppConfig.defaultOpenAIModel))
      OCR_HTTP_DEBUG_CAPTURE_DIR  When set, store OCR inputs and a redacted sidecar (default: off)
      OCR_HTTP_DEBUG_CAPTURE_MAX  How many captures to keep, 1...10000 (default: \(AppConfig.defaultDebugCaptureMax))

    """
    fputs(text, stdout)
}

private func parsePort() throws -> UInt16 {
    let raw = ProcessInfo.processInfo.environment["OCR_HTTP_PORT"]?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let text = raw.isEmpty ? String(AppConfig.defaultPort) : raw
    guard let value = UInt16(text), value > 0 else {
        throw ConfigError("OCR_HTTP_PORT must be 1...65535")
    }
    return value
}

private func loadToken() throws -> String {
    let env = ProcessInfo.processInfo.environment
    let raw: String
    if let token = env["OCR_HTTP_TOKEN"], !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        raw = token
    } else {
        let path = env["OCR_HTTP_TOKEN_FILE"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/MacOcrHttp/token")
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConfigError("set OCR_HTTP_TOKEN or create \(path) (run scripts/install.sh)")
        }
        raw = try String(contentsOfFile: path, encoding: .utf8)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mode = attrs[.posixPermissions] as? NSNumber,
           mode.uint16Value & 0o077 != 0 {
            fputs("warning: token file \(path) is readable by group or others; chmod 600\n", stderr)
        }
    }
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.count < 16 || token.contains(where: { $0.isWhitespace }) {
        throw ConfigError("OCR_HTTP_TOKEN must be at least 16 characters with no whitespace")
    }
    let banned: Set<String> = ["__token__", "replace_me", "changeme", "token", "password"]
    if banned.contains(token.lowercased()) {
        throw ConfigError("refusing placeholder OCR_HTTP_TOKEN")
    }
    return token
}

func parseDebugCaptureDir(_ raw: String?) throws -> String? {
    let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text.isEmpty { return nil }
    if text.contains("\n") || text.contains("\u{0000}") || text.contains("__") {
        throw ConfigError("OCR_HTTP_DEBUG_CAPTURE_DIR must not contain newlines, NULs, or __")
    }
    return text
}

func parseTileMinGlyphFrac(_ raw: String?, legacy: String?) throws -> Double {
    let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !text.isEmpty {
        return try parseGlyphFrac(text, name: "OCR_HTTP_TILE_MIN_GLYPH_FRAC")
    }
    let old = legacy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !old.isEmpty {
        fputs("warning: OCR_HTTP_TILE_MIN_TEXT_FRAC is a deprecated alias of OCR_HTTP_TILE_MIN_GLYPH_FRAC\n", stderr)
        return try parseGlyphFrac(old, name: "OCR_HTTP_TILE_MIN_TEXT_FRAC")
    }
    return AppConfig.defaultTileMinGlyphFrac
}

func parseOpenAIModel(_ raw: String?) throws -> String {
    let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if text.isEmpty { return AppConfig.defaultOpenAIModel }
    let allowed = text.unicodeScalars.allSatisfy { scalar in
        let value = scalar.value
        return (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
            || value == 0x2E || value == 0x5F || value == 0x2D || value == 0x3A || value == 0x2F
    }
    guard text.count <= 128, allowed else {
        throw ConfigError("OCR_HTTP_OPENAI_MODEL must be 1...128 characters from [A-Za-z0-9._:/-]")
    }
    return text
}

private func parseGlyphFrac(_ text: String, name: String) throws -> Double {
    guard let value = Double(text), value >= 0.001, value <= 0.2 else {
        throw ConfigError("\(name) must be a number from 0.001 to 0.2")
    }
    return value
}

private func clampedEnv(_ key: String, default defaultValue: Int, min minValue: Int, max maxValue: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          let value = Int(raw) else {
        return defaultValue
    }
    return min(max(value, minValue), maxValue)
}
