import Darwin
import Foundation
import LineMergeCore

enum AdmissionResult {
    case ready(Int)
    case full
    case timedOut
}

struct AdmissionSnapshot {
    var inFlight: Int
    var queued: Int
    var rejected: Int
}

/// Waiters block on `NSCondition` until a Vision worker is free, the wait
/// times out, or the queue is already at capacity. No polling.
final class OCRAdmission: @unchecked Sendable {
    private let condition = NSCondition()
    private var busy: [Bool]
    private var queued = 0
    private var rejected = 0
    let workers: Int
    let capacity: Int
    let timeout: TimeInterval

    init(workers: Int, capacity: Int, timeout: TimeInterval) {
        self.workers = workers
        self.capacity = capacity
        self.timeout = timeout
        self.busy = Array(repeating: false, count: workers)
    }

    func acquire() -> AdmissionResult {
        condition.lock()
        defer { condition.unlock() }
        if let index = busy.firstIndex(of: false) {
            busy[index] = true
            return .ready(index)
        }
        if queued >= capacity {
            rejected += 1
            return .full
        }
        queued += 1
        let deadline = Date().addingTimeInterval(timeout)
        while busy.firstIndex(of: false) == nil {
            if !condition.wait(until: deadline) {
                if busy.firstIndex(of: false) != nil { break }
                queued -= 1
                rejected += 1
                return .timedOut
            }
        }
        queued -= 1
        let index = busy.firstIndex(of: false)!
        busy[index] = true
        return .ready(index)
    }

    func release(_ index: Int) {
        condition.lock()
        if busy.indices.contains(index) {
            busy[index] = false
        }
        condition.signal()
        condition.unlock()
    }

    func snapshot() -> AdmissionSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return AdmissionSnapshot(
            inFlight: busy.filter { $0 }.count,
            queued: queued,
            rejected: rejected
        )
    }
}

final class HTTPServer: @unchecked Sendable {
    let config: AppConfig
    private let auth: BearerAuth
    private let admission: OCRAdmission
    private let vision: WorkerPool

    init(config: AppConfig) {
        self.config = config
        self.auth = BearerAuth(token: config.token)
        self.admission = OCRAdmission(
            workers: config.visionWorkers,
            capacity: config.queueMax,
            timeout: TimeInterval(config.queueTimeoutMs) / 1000
        )
        self.vision = WorkerPool(settings: WorkerPool.Settings(
            workers: config.visionWorkers,
            timeoutMs: config.workerTimeoutMs,
            maxTasks: config.workerMaxTasks,
            maxAgeSeconds: config.workerMaxAgeSeconds
        ))
        self.slots = DispatchSemaphore(value: config.queueMax + config.visionWorkers + 16)
        if let dir = config.debugCaptureDir {
            self.debugStore = DebugCaptureStore(directory: dir, maxCount: config.debugCaptureMax)
        } else {
            self.debugStore = nil
        }
    }

    private let listenLock = NSLock()
    private var listeners: [String: CloseOnce] = [:]
    private var pending: [String] = []
    private var retryTimer: DispatchSourceTimer?
    private let connectionQueue = DispatchQueue(label: "macocr.http", attributes: .concurrent)
    /// Disk writes for `OCR_HTTP_DEBUG_CAPTURE_DIR`. Never waited on by a request.
    private let debugQueue = DispatchQueue(label: "macocr.debug-capture")
    private let debugStore: DebugCaptureStore?
    /// One handler thread per queued OCR, plus the running workers, plus a few
    /// slots so /health and /stats are not stuck behind a full queue. Shared by
    /// every listening address.
    private let slots: DispatchSemaphore
    static let retryInterval: TimeInterval = 30

    /// Binds one socket per configured address, each with its own accept loop,
    /// all feeding the same handler, queue, and Vision workers. Addresses that
    /// cannot be bound (DHCP lease not up yet, port busy) are retried every 30s
    /// in-process, so launchd never sees a crash loop. Never returns.
    func run() throws -> Never {
        ignoreSignals()
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                self?.closeAllListeners()
                // Workers first: SIGTERM, 3 s grace, SIGKILL, reap. Then exit.
                self?.vision.shutdown(grace: 3)
                Darwin.exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        log("mac-ocr-http starting hosts=\(config.hosts.joined(separator: ",")) port=\(config.port) workers=\(config.visionWorkers) queue=\(config.queueMax) model=\(config.openAIModel)")
        log("recognition runs in \(config.visionWorkers) worker process(es): timeout=\(config.workerTimeoutMs)ms maxTasks=\(config.workerMaxTasks) maxAge=\(config.workerMaxAgeSeconds)s")
        vision.start()
        if let dir = config.debugCaptureDir {
            log("debug capture on dir=\(dir) max=\(config.debugCaptureMax) (stores request images on disk)")
        }
        for host in config.hosts {
            if !tryListen(host, retrying: false) {
                listenLock.lock(); pending.append(host); listenLock.unlock()
            }
        }
        listenLock.lock()
        let boundCount = listeners.count
        let missing = pending
        listenLock.unlock()
        if boundCount == 0 {
            fputs("no listen address could be bound; retrying every \(Int(Self.retryInterval))s\n", stderr)
        }
        if !missing.isEmpty { startRetryTimer() }
        dispatchMain()
    }

    private var signalSources: [DispatchSourceSignal] = []

    /// Returns true if the address is now listening.
    private func tryListen(_ host: String, retrying: Bool) -> Bool {
        do {
            let fd = try bindListener(host: host, port: config.port)
            let socket = CloseOnce(fd: fd)
            listenLock.lock()
            listeners[host] = socket
            listenLock.unlock()
            if retrying {
                fputs("listen \(host):\(config.port) is now up\n", stderr)
            } else {
                log("mac-ocr-http listening on http://\(host):\(config.port)")
            }
            let thread = Thread { [self] in acceptLoop(fd: fd, host: host) }
            thread.name = "accept \(host)"
            thread.start()
            return true
        } catch let error as BindError {
            if !retrying {
                fputs("listen \(host):\(config.port) unavailable (\(error.reason)); retrying every \(Int(Self.retryInterval))s\n", stderr)
            }
            return false
        } catch {
            if !retrying {
                fputs("listen \(host):\(config.port) unavailable (\(error)); retrying every \(Int(Self.retryInterval))s\n", stderr)
            }
            return false
        }
    }

    private func startRetryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macocr.listen-retry"))
        timer.schedule(deadline: .now() + Self.retryInterval, repeating: Self.retryInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.listenLock.lock()
            let hosts = self.pending
            self.listenLock.unlock()
            var still: [String] = []
            for host in hosts where !self.tryListen(host, retrying: true) {
                still.append(host)
            }
            self.listenLock.lock()
            self.pending = still
            self.listenLock.unlock()
            if still.isEmpty {
                self.retryTimer?.cancel()
                self.retryTimer = nil
            }
        }
        retryTimer = timer
        timer.resume()
    }

    private func closeAllListeners() {
        listenLock.lock()
        let all = Array(listeners.values)
        listenLock.unlock()
        all.forEach { $0.close() }
    }

    private func acceptLoop(fd listenFD: Int32, host: String) {
        while true {
            slots.wait()
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.accept(listenFD, raw, &length)
                }
            }
            if client < 0 {
                let error = errno
                slots.signal()
                if error == EINTR || error == ECONNABORTED || error == ECONNRESET { continue }
                if error == EBADF || error == EINVAL { break }
                fputs("accept failed on \(host): \(String(cString: strerror(error)))\n", stderr)
                usleep(50_000)
                continue
            }
            let peer = ipv4String(address.sin_addr)
            configureClient(client)
            connectionQueue.async {
                defer {
                    Darwin.close(client)
                    self.slots.signal()
                }
                self.handle(client, peer: peer)
            }
        }
    }

    private func handle(_ fd: Int32, peer: String) {
        let work: RequestWork
        do {
            let request = try HTTPReader.read(
                fd: fd,
                maxHeaderBytes: 16 * 1024,
                maxBodyBytes: config.maxBodyBytes
            )
            work = classify(request)
        } catch let error as HTTPReadError {
            if case .closed = error { return }
            if case .io(let message) = error {
                fputs("io: \(message)\n", stderr)
            }
            if case .bodyTooLarge(let method, let path) = error, isV1(path) {
                let response = openAIFailure(
                    OpenAICompat.APIError.invalid(
                        "request body exceeds limit",
                        code: "request_too_large",
                        status: 413
                    ),
                    cors: defaultV1CORS()
                )
                log(OpenAICompat.accessLog(method: method, path: path, status: response.status, code: response.logCode))
                try? HTTPWriter.send(fd, response)
                capture(
                    endpoint: path,
                    peer: peer,
                    status: response.status,
                    errorCode: response.logCode,
                    images: [],
                    passes: [],
                    messages: nil,
                    method: method
                )
                return
            }
            log("- - \(error.response.status)")
            try? HTTPWriter.send(fd, error.response)
            if case .bodyTooLarge(let method, let path) = error {
                capture(
                    endpoint: path,
                    peer: peer,
                    status: error.response.status,
                    errorCode: nativeErrorCode(error.response),
                    images: [],
                    passes: [],
                    messages: nil,
                    method: method
                )
            }
            return
        } catch {
            let response = HTTPResponse.json(500, ErrorBody(ok: false, error: "internal error"))
            fputs("handler error: \(error)\n", stderr)
            log("- - 500")
            try? HTTPWriter.send(fd, response)
            return
        }

        switch work {
        case .http(let response, let method, let path, let seed):
            log(OpenAICompat.accessLog(method: method, path: path, status: response.status, code: isV1(path) ? response.logCode : nil))
            try? HTTPWriter.send(fd, response)
            if let seed {
                let code = response.status < 400 ? nil : (isV1(path) ? response.logCode : nativeErrorCode(response))
                capture(
                    endpoint: path,
                    peer: peer,
                    status: response.status,
                    errorCode: code,
                    images: seed.images,
                    passes: [],
                    messages: seed.messages,
                    method: method
                )
            }
        case .ocr(let holder, let job, let method, let path):
            // Keep the original bytes only when capture is on. Otherwise Vision
            // still drops the buffer at the start of recognize.
            let snapshot: Data? = debugStore == nil ? nil : holder.data
            let (response, passes) = performOCR(holder, job)
            log(OpenAICompat.accessLog(method: method, path: path, status: response.status, code: nil))
            try? HTTPWriter.send(fd, response)
            if let snapshot {
                capture(
                    endpoint: path,
                    peer: peer,
                    status: response.status,
                    errorCode: response.status >= 400 ? nativeErrorCode(response) : nil,
                    images: [snapshot],
                    passes: passes,
                    messages: nil,
                    method: method
                )
            }
        case .openai(let job):
            let images = debugStore == nil ? [] : job.images
            switch performOpenAI(job) {
            case .json(let response, let passes):
                log(OpenAICompat.accessLog(method: job.method, path: job.path, status: response.status, code: response.logCode))
                try? HTTPWriter.send(fd, response)
                capture(
                    endpoint: job.path,
                    peer: peer,
                    status: response.status,
                    errorCode: response.logCode,
                    images: images,
                    passes: passes,
                    messages: job.messages,
                    method: job.method
                )
            case .events(let events, let passes):
                log(OpenAICompat.accessLog(method: job.method, path: job.path, status: 200, code: nil))
                try? HTTPWriter.sendEventStream(fd, version: job.version, events: events, headers: job.cors)
                capture(
                    endpoint: job.path,
                    peer: peer,
                    status: 200,
                    errorCode: nil,
                    images: images,
                    passes: passes,
                    messages: job.messages,
                    method: job.method
                )
            }
        }
    }

    /// Copies the capture onto `debugQueue` and returns. A disabled store does no work.
    private func capture(
        endpoint: String,
        peer: String,
        status: Int,
        errorCode: String?,
        images: [Data],
        passes: [DebugPassSummary],
        messages: [DebugMessageSummary]?,
        method: String
    ) {
        guard let debugStore, method == "POST", isCapturePath(endpoint), DebugCapture.records(status: status) else { return }
        let meta = DebugCapture.makeMeta(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            endpoint: endpoint,
            clientIP: peer,
            status: status,
            errorCode: status >= 400 ? errorCode : nil,
            passes: passes,
            messages: messages
        )
        debugQueue.async {
            do {
                try debugStore.save(meta: meta, images: images)
            } catch {
                let reason = String(String(describing: error).prefix(180))
                fputs("debug capture failed: \(reason)\n", stderr)
            }
        }
    }

    /// `request` dies with this function, so the raw body is released before Vision runs.
    private func classify(_ request: HTTPRequest) -> RequestWork {
        if isV1(request.path) {
            return classifyV1(request)
        }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return httpWork(HTTPResponse.health(), request.method, request.path)
        case ("GET", "/languages"):
            return httpWork(languages(request), request.method, request.path)
        case ("GET", "/stats"):
            return httpWork(stats(request), request.method, request.path)
        case ("POST", "/ocr"):
            guard auth.allows(request.headers) else {
                return httpWork(.unauthorized(), request.method, request.path)
            }
            do {
                let parsed = try parseOCRBody(request)
                if parsed.data.isEmpty {
                    return httpWork(
                        HTTPResponse.json(400, ErrorBody(ok: false, error: "empty image")),
                        request.method,
                        request.path,
                        seed: failedOCRSeed(request)
                    )
                }
                return .ocr(DataHolder(parsed.data), parsed.job, request.method, request.path)
            } catch let error as BadRequest {
                return httpWork(
                    HTTPResponse.json(400, ErrorBody(ok: false, error: error.message)),
                    request.method,
                    request.path,
                    seed: failedOCRSeed(request)
                )
            } catch {
                return httpWork(
                    HTTPResponse.json(400, ErrorBody(ok: false, error: "bad request")),
                    request.method,
                    request.path,
                    seed: failedOCRSeed(request)
                )
            }
        case (_, "/health"), (_, "/languages"), (_, "/stats"):
            return httpWork(methodNotAllowed("GET"), request.method, request.path)
        case (_, "/ocr"):
            return httpWork(methodNotAllowed("POST"), request.method, request.path)
        default:
            return httpWork(
                HTTPResponse.json(404, ErrorBody(ok: false, error: "not found")),
                request.method,
                request.path
            )
        }
    }

    private func languages(_ request: HTTPRequest) -> HTTPResponse {
        guard auth.allows(request.headers) else {
            return .unauthorized()
        }
        do {
            return HTTPResponse.json(200, try vision.languageCatalog())
        } catch {
            fputs("languages error: \(error)\n", stderr)
            return HTTPResponse.json(500, ErrorBody(ok: false, error: "could not list languages"))
        }
    }

    private func stats(_ request: HTTPRequest) -> HTTPResponse {
        guard auth.allows(request.headers) else {
            return .unauthorized()
        }
        let snap = admission.snapshot()
        return HTTPResponse.json(200, StatsBody(
            ok: true,
            inFlight: snap.inFlight,
            queued: snap.queued,
            rejected: snap.rejected,
            workers: config.visionWorkers,
            rssBytes: physicalFootprint() + vision.workerFootprintBytes()
        ))
    }

    private func performOCR(_ holder: DataHolder, _ job: OCRJob) -> (HTTPResponse, [DebugPassSummary]) {
        switch admission.acquire() {
        case .full:
            return (busy("queue full"), [])
        case .timedOut:
            return (busy("queue wait timed out"), [])
        case .ready(let index):
            defer { admission.release(index) }
            do {
                let payload = try vision.recognize(
                    on: index,
                    holder: holder,
                    job: job,
                    maxPixels: config.maxPixels,
                    maxPixel: config.maxPixel,
                    minGlyphFrac: config.tileMinGlyphFrac
                )
                let response = HTTPResponse.json(200, OCRSuccessBody(
                    ok: true,
                    text: payload.text,
                    width: payload.width,
                    height: payload.height,
                    scale: payload.scale,
                    tiles: payload.tiles,
                    mode: payload.mode,
                    glyphPx: payload.glyphPx,
                    glyphFrac: payload.glyphFrac,
                    tileDecision: payload.tileDecision,
                    elapsedMs: payload.elapsedMs,
                    languages: payload.languages,
                    revision: payload.revision,
                    script: payload.script,
                    layout: payload.layout,
                    lines: payload.lines,
                    rows: payload.rows,
                    blocks: payload.blocks
                ))
                return (response, [DebugPassSummary(
                    elapsedMs: payload.elapsedMs,
                    mode: payload.mode,
                    tiles: payload.tiles,
                    glyphFrac: payload.glyphFrac,
                    text: payload.text,
                    rows: payload.rows.map(\.text)
                )])
            } catch let error as ImageDecodeError {
                switch error {
                case .tooLarge(let width, let height, let maxPixels):
                    return (HTTPResponse.json(413, TooLargeBody(
                        ok: false,
                        error: "image too large",
                        maxPixels: maxPixels,
                        width: width,
                        height: height
                    )), [])
                case .unrecognized:
                    return (HTTPResponse.json(415, ErrorBody(ok: false, error: error.description)), [])
                }
            } catch let error as OCREngineError {
                switch error {
                case .badRequest(let message):
                    return (HTTPResponse.json(400, ErrorBody(ok: false, error: message)), [])
                case .vision(let message):
                    let trimmed = message.count > 180 ? String(message.prefix(180)) : message
                    fputs("vision error: \(trimmed)\n", stderr)
                    return (HTTPResponse.json(500, ErrorBody(ok: false, error: "vision recognition failed: \(trimmed)")), [])
                }
            } catch {
                fputs("ocr error: \(error)\n", stderr)
                return (HTTPResponse.json(500, ErrorBody(ok: false, error: "internal error")), [])
            }
        }
    }

    private func classifyV1(_ request: HTTPRequest) -> RequestWork {
        if request.method == "OPTIONS" {
            return httpWork(v1Preflight(request), request.method, request.path)
        }
        let cors = v1CORS(request)
        guard auth.allows(request.headers) else {
            return httpWork(openAIUnauthorized(cors), request.method, request.path)
        }
        if request.method == "GET", request.path == "/v1/models" {
            let created = Int(Date().timeIntervalSince1970)
            return httpWork(
                v1JSON(200, OpenAICompat.modelsList(id: config.openAIModel, created: created), cors: cors),
                request.method,
                request.path
            )
        }
        if request.method == "GET", request.path.hasPrefix("/v1/models/") {
            let raw = String(request.path.dropFirst("/v1/models/".count))
            let id = percentDecode(raw)
            if id == config.openAIModel {
                let created = Int(Date().timeIntervalSince1970)
                return httpWork(
                    v1JSON(200, OpenAICompat.modelJSON(id: id, created: created), cors: cors),
                    request.method,
                    request.path
                )
            }
            return httpWork(
                openAIFailure(
                    .invalid("The model '\(id)' does not exist", param: "model", code: "model_not_found", status: 404),
                    cors: cors
                ),
                request.method,
                request.path
            )
        }
        if request.path == "/v1/models" || request.path.hasPrefix("/v1/models/") {
            return httpWork(
                openAIFailure(.invalid("method not allowed", code: "method_not_allowed", status: 405), cors: cors, extra: ["Allow": "GET, OPTIONS"]),
                request.method,
                request.path
            )
        }
        if request.method == "POST",
           (request.path == "/v1/chat/completions" || request.path == "/v1/responses") {
            do {
                let parsed = try request.path.hasSuffix("/responses")
                    ? OpenAICompat.parseResponses(request.body)
                    : OpenAICompat.parseChat(request.body)
                let model = parsed.model ?? config.openAIModel
                return .openai(OpenAIJob(
                    method: request.method,
                    path: request.path,
                    version: request.version,
                    images: parsed.images.map(\.data),
                    stream: parsed.stream,
                    includeUsage: parsed.includeUsage,
                    model: model,
                    languages: parsed.languages,
                    promptScalars: parsed.promptScalars,
                    wire: parsed.wire,
                    cors: cors,
                    messages: debugStore == nil ? nil : DebugCapture.messageSummaries(json: request.body)
                ))
            } catch let error as OpenAICompat.APIError {
                return httpWork(
                    openAIFailure(error, cors: cors),
                    request.method,
                    request.path,
                    seed: v1FailureSeed(request)
                )
            } catch {
                return httpWork(
                    openAIFailure(.invalid("bad request", code: "invalid_json"), cors: cors),
                    request.method,
                    request.path,
                    seed: v1FailureSeed(request)
                )
            }
        }
        if request.path == "/v1/chat/completions" || request.path == "/v1/responses" {
            return httpWork(
                openAIFailure(.invalid("method not allowed", code: "method_not_allowed", status: 405), cors: cors, extra: ["Allow": "POST, OPTIONS"]),
                request.method,
                request.path
            )
        }
        return httpWork(
            openAIFailure(.invalid("not found", code: "not_found", status: 404), cors: cors),
            request.method,
            request.path
        )
    }

    private func performOpenAI(_ job: OpenAIJob) -> OpenAIOutcome {
        if job.images.isEmpty {
            return openAIResult(job, content: "", passes: [])
        }
        switch admission.acquire() {
        case .full:
            return .json(openAIFailure(
                OpenAICompat.APIError(status: 503, message: "queue full", type: "server_error", param: nil, code: "queue_full"),
                cors: job.cors,
                extra: ["Retry-After": "1"]
            ), [])
        case .timedOut:
            return .json(openAIFailure(
                OpenAICompat.APIError(status: 503, message: "queue wait timed out", type: "server_error", param: nil, code: "queue_timeout"),
                cors: job.cors,
                extra: ["Retry-After": "1"]
            ), [])
        case .ready(let index):
            defer { admission.release(index) }
            let ocrJob = OCRJob(
                level: .accurate,
                languages: job.languages,
                scale: .auto,
                maxPixel: nil,
                force: nil,
                tileMinGlyphFrac: nil,
                script: nil,
                layout: .rows
            )
            var images = job.images
            var texts: [String] = []
            var passes: [DebugPassSummary] = []
            texts.reserveCapacity(images.count)
            for offset in images.indices {
                let holder = DataHolder(images[offset])
                images[offset] = Data()
                do {
                    let payload = try vision.recognize(
                        on: index,
                        holder: holder,
                        job: ocrJob,
                        maxPixels: config.maxPixels,
                        maxPixel: config.maxPixel,
                        minGlyphFrac: config.tileMinGlyphFrac
                    )
                    texts.append(payload.text)
                    passes.append(DebugPassSummary(
                        elapsedMs: payload.elapsedMs,
                        mode: payload.mode,
                        tiles: payload.tiles,
                        glyphFrac: payload.glyphFrac,
                        text: payload.text,
                        rows: payload.rows.map(\.text)
                    ))
                } catch {
                    return .json(openAIFailure(openAIMap(error), cors: job.cors), passes)
                }
            }
            return openAIResult(job, content: texts.joined(separator: "\n\n"), passes: passes)
        }
    }

    /// Chat or Responses bytes. A text-only probe calls this without taking a worker.
    private func openAIResult(_ job: OpenAIJob, content: String, passes: [DebugPassSummary]) -> OpenAIOutcome {
        let created = Int(Date().timeIntervalSince1970)
        let usage = OpenAICompat.Usage(promptScalars: job.promptScalars, completion: content)
        let id = OpenAICompat.completionID(prefix: job.wire == .chat ? "chatcmpl-" : "resp_")
        if job.stream {
            return .events(OpenAICompat.sseEvents(
                wire: job.wire,
                id: id,
                created: created,
                model: job.model,
                content: content,
                usage: usage,
                includeUsage: job.includeUsage
            ), passes)
        }
        let body: Data
        switch job.wire {
        case .chat:
            body = OpenAICompat.chatCompletionJSON(id: id, created: created, model: job.model, content: content, usage: usage)
        case .responses:
            body = OpenAICompat.responsesJSON(id: id, created: created, model: job.model, content: content, usage: usage)
        }
        return .json(v1JSON(200, body, cors: job.cors), passes)
    }

    private func httpWork(
        _ response: HTTPResponse,
        _ method: String,
        _ path: String,
        seed: CaptureSeed? = nil
    ) -> RequestWork {
        .http(response, method, path, seed)
    }

    /// Decoded image bytes when the body is an image or a JSON `image` field.
    /// A failed decode stores no file, so the base64 text is not written.
    private func failedOCRSeed(_ request: HTTPRequest) -> CaptureSeed? {
        guard debugStore != nil else { return nil }
        return CaptureSeed(images: debugImages(from: request), messages: nil)
    }

    private func v1FailureSeed(_ request: HTTPRequest) -> CaptureSeed? {
        guard debugStore != nil else { return nil }
        return CaptureSeed(
            images: [],
            messages: DebugCapture.messageSummaries(json: request.body)
        )
    }
}

private struct CaptureSeed {
    var images: [Data]
    var messages: [DebugMessageSummary]?
}

private enum RequestWork {
    case http(HTTPResponse, String, String, CaptureSeed?)
    case ocr(DataHolder, OCRJob, String, String)
    case openai(OpenAIJob)
}

private enum OpenAIOutcome {
    case json(HTTPResponse, [DebugPassSummary])
    case events([Data], [DebugPassSummary])
}

private struct OpenAIJob {
    var method: String
    var path: String
    var version: String
    var images: [Data]
    var stream: Bool
    var includeUsage: Bool
    var model: String
    var languages: [String]?
    var promptScalars: Int
    var wire: OpenAICompat.Wire
    var cors: [String: String]
    var messages: [DebugMessageSummary]?
}

private func isCapturePath(_ path: String) -> Bool {
    path == "/ocr" || path == "/v1/chat/completions" || path == "/v1/responses"
}

private func nativeErrorCode(_ response: HTTPResponse) -> String? {
    guard response.status >= 400,
          let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let error = object["error"] as? String,
          !error.isEmpty,
          error.count <= 200 else {
        return nil
    }
    return error
}

/// Original image bytes for a failed `/ocr` request. JSON base64 is decoded;
/// the text form is not kept.
private func debugImages(from request: HTTPRequest) -> [Data] {
    let type = mediaType(from: request.headers["content-type"])
    if type == "application/json" || type == "text/json" {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let image = object["image"] as? String,
              let data = try? decodeBase64Image(image),
              !data.isEmpty else {
            return []
        }
        return [data]
    }
    if type == "application/octet-stream" || type.hasPrefix("image/") {
        return request.body.isEmpty ? [] : [request.body]
    }
    return []
}

private func isV1(_ path: String) -> Bool {
    path == "/v1" || path.hasPrefix("/v1/")
}

private func defaultV1CORS() -> [String: String] {
    [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Authorization, Content-Type, Accept",
        "Access-Control-Max-Age": "600",
    ]
}

private func v1CORS(_ request: HTTPRequest) -> [String: String] {
    var headers = defaultV1CORS()
    if let requested = request.headers["access-control-request-headers"] {
        let names = requested.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let safe = names.filter { name in
            !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (0x30...0x39).contains(value)
                    || (0x41...0x5A).contains(value)
                    || (0x61...0x7A).contains(value)
                    || value == 0x2D
            }
        }
        if !safe.isEmpty {
            var seen = Set(headers["Access-Control-Allow-Headers", default: ""].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            })
            var allow = headers["Access-Control-Allow-Headers"] ?? ""
            for name in safe where seen.insert(name.lowercased()).inserted {
                allow += ", \(name)"
            }
            headers["Access-Control-Allow-Headers"] = allow
        }
    }
    return headers
}

private func v1JSON(_ status: Int, _ body: Data, cors: [String: String]) -> HTTPResponse {
    HTTPResponse(status: status, reason: reasonPhrase(status), headers: cors, body: body)
}

private func openAIFailure(
    _ error: OpenAICompat.APIError,
    cors: [String: String],
    extra: [String: String] = [:]
) -> HTTPResponse {
    var headers = cors
    for (name, value) in extra {
        headers[name] = value
    }
    return HTTPResponse(
        status: error.status,
        reason: reasonPhrase(error.status),
        headers: headers,
        body: OpenAICompat.errorJSON(error),
        logCode: error.code
    )
}

private func openAIUnauthorized(_ cors: [String: String]) -> HTTPResponse {
    openAIFailure(
        .invalid("invalid API key", param: nil, code: "invalid_api_key", status: 401),
        cors: cors,
        extra: ["WWW-Authenticate": "Bearer"]
    )
}

private func v1Preflight(_ request: HTTPRequest) -> HTTPResponse {
    HTTPResponse(status: 204, reason: "No Content", headers: v1CORS(request), body: Data())
}

private func openAIMap(_ error: Error) -> OpenAICompat.APIError {
    if let error = error as? ImageDecodeError {
        switch error {
        case .tooLarge(let width, let height, let maxPixels):
            return .invalid(
                "image too large (\(width)x\(height), max \(maxPixels) pixels)",
                code: "image_too_large",
                status: 413
            )
        case .unrecognized:
            return .invalid("unrecognized image data", code: "invalid_image")
        }
    }
    if let error = error as? OCREngineError {
        switch error {
        case .badRequest(let message):
            return .invalid(message, code: "invalid_request")
        case .vision(let message):
            let trimmed = message.count > 180 ? String(message.prefix(180)) : message
            return OpenAICompat.APIError(
                status: 500,
                message: "vision recognition failed: \(trimmed)",
                type: "server_error",
                param: nil,
                code: "recognition_failed"
            )
        }
    }
    return OpenAICompat.APIError(
        status: 500,
        message: "internal error",
        type: "server_error",
        param: nil,
        code: "internal_error"
    )
}

private func busy(_ message: String) -> HTTPResponse {
    HTTPResponse.json(503, ErrorBody(ok: false, error: message), headers: ["Retry-After": "1"])
}

func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.phys_footprint)
}

private func parseOCRBody(_ request: HTTPRequest) throws -> (data: Data, job: OCRJob) {
    let type = mediaType(from: request.headers["content-type"])
    switch type {
    case "application/json", "text/json":
        return try parseJSONOCR(request.body, query: request.query)
    case "application/octet-stream":
        return (request.body, try jobFromQuery(request.query))
    case "":
        if looksLikeJSONObject(request.body) {
            return try parseJSONOCR(request.body, query: request.query)
        }
        return (request.body, try jobFromQuery(request.query))
    default:
        if type.hasPrefix("image/") {
            return (request.body, try jobFromQuery(request.query))
        }
        throw BadRequest(message: "content type must be application/json or image/*")
    }
}

private func parseJSONOCR(_ body: Data, query: [String: String]) throws -> (data: Data, job: OCRJob) {
    let object: Any
    do {
        object = try JSONSerialization.jsonObject(with: body)
    } catch {
        throw BadRequest(message: "invalid JSON")
    }
    guard let dict = object as? [String: Any] else {
        throw BadRequest(message: "JSON object required")
    }
    let forbidden = ["path", "url", "image_url", "imageUrl", "file"]
    if dict["image"] == nil {
        for key in forbidden where dict[key] != nil {
            throw BadRequest(message: "filesystem paths and remote URLs are not accepted")
        }
        throw BadRequest(message: "JSON field image (base64) is required")
    }
    guard let image = dict["image"] as? String else {
        throw BadRequest(message: "image must be a base64 string")
    }
    let data = try decodeBase64Image(image)
    let levelText: String?
    if dict["level"] != nil {
        guard let text = dict["level"] as? String else {
            throw BadRequest(message: "level must be accurate or fast")
        }
        levelText = text
    } else {
        levelText = query["level"]
    }
    let languages = try languagesFromJSON(dict["languages"]) ?? languagesFromQuery(query["languages"])
    let scriptText = try optionalString(dict["script"], name: "script", allowed: "hans or auto") ?? query["script"]
    let layoutText = try optionalString(dict["layout"], name: "layout", allowed: "rows or document") ?? query["layout"]
    let scaleText: String?
    if dict["scale"] != nil {
        guard let text = dict["scale"] as? String else {
            throw BadRequest(message: "scale must be auto, none, tile, or downscale")
        }
        scaleText = text
    } else {
        scaleText = query["scale"]
    }
    let forceText = try optionalString(dict["force"], name: "force", allowed: "whole or tile") ?? query["force"]
    let fragmentsText = try optionalString(dict["fragments"], name: "fragments", allowed: "drop or keep") ?? query["fragments"]
    let fracText = try fracString(dict["tileMinGlyphFrac"])
        ?? query["tileminglyphfrac"]
        ?? fracString(dict["tileMinTextFrac"])
        ?? query["tilemintextfrac"]
    let maxPixelText: String?
    if dict["maxPixel"] != nil {
        maxPixelText = try maxPixelString(dict["maxPixel"])
    } else {
        maxPixelText = query["maxPixel"]
    }
    let job = try makeJob(
        levelText: levelText,
        languages: languages,
        scaleText: scaleText,
        maxPixelText: maxPixelText,
        scriptText: scriptText,
        layoutText: layoutText,
        forceText: forceText,
        fracText: fracText,
        fragmentsText: fragmentsText
    )
    return (data, job)
}

private func jobFromQuery(_ query: [String: String]) throws -> OCRJob {
    try makeJob(
        levelText: query["level"],
        languages: languagesFromQuery(query["languages"]),
        scaleText: query["scale"],
        maxPixelText: query["maxPixel"],
        scriptText: query["script"],
        layoutText: query["layout"],
        forceText: query["force"],
        fracText: query["tileminglyphfrac"] ?? query["tilemintextfrac"],
        fragmentsText: query["fragments"]
    )
}

private func makeJob(
    levelText: String?,
    languages: [String]?,
    scaleText: String?,
    maxPixelText: String?,
    scriptText: String?,
    layoutText: String?,
    forceText: String?,
    fracText: String?,
    fragmentsText: String? = nil
) throws -> OCRJob {
    let scale = try parseScale(scaleText)
    let force = try parseForce(forceText)
    if force != nil, scale != .auto {
        throw BadRequest(message: "force applies only to scale=auto")
    }
    return OCRJob(
        level: try parseLevel(levelText),
        languages: languages,
        scale: scale,
        maxPixel: try parseMaxPixel(maxPixelText),
        force: force,
        tileMinGlyphFrac: try parseRequestFrac(fracText),
        script: try parseScript(scriptText),
        layout: try parseLayout(layoutText),
        fragments: try parseFragments(fragmentsText)
    )
}

private func optionalString(_ value: Any?, name: String, allowed: String) throws -> String? {
    guard let value else { return nil }
    guard let text = value as? String else {
        throw BadRequest(message: "\(name) must be \(allowed)")
    }
    return text
}

private func parseScript(_ raw: String?) throws -> ScriptMode? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    switch trimmed.lowercased() {
    case "hans":
        return .hans
    case "auto":
        return .auto
    default:
        throw BadRequest(message: "script must be hans or auto")
    }
}

private func parseLayout(_ raw: String?) throws -> LayoutMode {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return .rows }
    switch trimmed.lowercased() {
    case "rows":
        return .rows
    case "document":
        return .document
    default:
        throw BadRequest(message: "layout must be rows or document")
    }
}

private func parseScale(_ raw: String?) throws -> ScaleMode {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return .auto }
    switch trimmed.lowercased() {
    case "auto":
        return .auto
    case "none":
        return .none
    case "tile":
        return .tile
    case "downscale":
        return .downscale
    default:
        throw BadRequest(message: "scale must be auto, none, tile, or downscale")
    }
}

private func parseFragments(_ raw: String?) throws -> Bool {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return true }
    switch trimmed.lowercased() {
    case "drop":
        return true
    case "keep":
        return false
    default:
        throw BadRequest(message: "fragments must be drop or keep")
    }
}

private func parseForce(_ raw: String?) throws -> TileForce? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return nil }
    switch trimmed.lowercased() {
    case "whole":
        return .whole
    case "tile":
        return .tile
    default:
        throw BadRequest(message: "force must be whole or tile")
    }
}

private func parseRequestFrac(_ raw: String?) throws -> Double? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let value = Double(trimmed), value >= 0.001, value <= 0.2 else {
        throw BadRequest(message: "tileMinGlyphFrac must be a number from 0.001 to 0.2")
    }
    return value
}

private func fracString(_ value: Any?) throws -> String? {
    guard let value else { return nil }
    if value is Bool {
        throw BadRequest(message: "tileMinGlyphFrac must be a number from 0.001 to 0.2")
    }
    if let text = value as? String {
        return text
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    throw BadRequest(message: "tileMinGlyphFrac must be a number from 0.001 to 0.2")
}

private func parseMaxPixel(_ raw: String?) throws -> Int? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let value = Int(trimmed), value >= 1024, value <= 8192 else {
        throw BadRequest(message: "maxPixel must be an integer from 1024 to 8192")
    }
    return value
}

private func maxPixelString(_ value: Any?) throws -> String {
    if value is Bool {
        throw BadRequest(message: "maxPixel must be an integer from 1024 to 8192")
    }
    if let value = value as? String {
        return value
    }
    if let number = value as? NSNumber {
        let double = number.doubleValue
        guard double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) else {
            throw BadRequest(message: "maxPixel must be an integer from 1024 to 8192")
        }
        return String(number.intValue)
    }
    throw BadRequest(message: "maxPixel must be an integer from 1024 to 8192")
}

private func parseLevel(_ raw: String?) throws -> RecognitionLevel {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return .accurate }
    switch trimmed.lowercased() {
    case "accurate":
        return .accurate
    case "fast":
        return .fast
    default:
        throw BadRequest(message: "level must be accurate or fast")
    }
}

private func languagesFromQuery(_ raw: String?) -> [String]? {
    guard let raw else { return nil }
    let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts
}

private func languagesFromJSON(_ value: Any?) throws -> [String]? {
    guard let value else { return nil }
    if let list = value as? [String] {
        return list
    }
    if let list = value as? [Any] {
        var languages: [String] = []
        for item in list {
            guard let language = item as? String else {
                throw BadRequest(message: "languages must be strings")
            }
            languages.append(language)
        }
        return languages
    }
    if let one = value as? String {
        return languagesFromQuery(one)
    }
    throw BadRequest(message: "languages must be an array of strings")
}

private func decodeBase64Image(_ raw: String) throws -> Data {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = text.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file:") {
        throw BadRequest(message: "filesystem paths and remote URLs are not accepted")
    }
    if lower.hasPrefix("data:") {
        guard let comma = text.firstIndex(of: ",") else {
            throw BadRequest(message: "invalid data URL")
        }
        let meta = text[..<comma].lowercased()
        guard meta.contains(";base64") else {
            throw BadRequest(message: "data URL must be base64")
        }
        text = String(text[text.index(after: comma)...])
    }
    guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters), !data.isEmpty else {
        throw BadRequest(message: "invalid base64 image")
    }
    return data
}

private func looksLikeJSONObject(_ data: Data) -> Bool {
    guard let prefix = String(data: data.prefix(64), encoding: .utf8) else { return false }
    return prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
}

private func methodNotAllowed(_ allow: String) -> HTTPResponse {
    HTTPResponse.json(405, ErrorBody(ok: false, error: "method not allowed"), headers: ["Allow": allow])
}

struct BindError: Error {
    var reason: String
}

/// Binds exactly `host` (already validated by `validateListenHost`) and checks
/// with getsockname that the kernel bound that same address.
private func bindListener(host: String, port: UInt16) throws -> Int32 {
    let expected = try validateListenHost(host)
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw BindError(reason: "socket: \(String(cString: strerror(errno)))")
    }
    var shouldClose = true
    defer {
        if shouldClose { Darwin.close(fd) }
    }
    var reuse: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var noSigPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    let flags = Darwin.fcntl(fd, F_GETFD, Int32(0))
    if flags >= 0 {
        _ = Darwin.fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = expected

    let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
            Darwin.bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else {
        throw BindError(reason: String(cString: strerror(errno)))
    }
    guard Darwin.listen(fd, 128) == 0 else {
        throw BindError(reason: "listen: \(String(cString: strerror(errno)))")
    }
    try verifyBound(fd, expected: expected, host: host)
    shouldClose = false
    return fd
}

private func verifyBound(_ fd: Int32, expected: in_addr, host: String) throws {
    var address = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
            Darwin.getsockname(fd, sock, &length)
        }
    }
    guard result == 0,
          address.sin_family == sa_family_t(AF_INET),
          address.sin_addr.s_addr == expected.s_addr,
          address.sin_addr.s_addr != INADDR_ANY else {
        throw ConfigError("refusing to listen: socket is not bound to \(host)")
    }
}

private func configureClient(_ fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval()
    timeout.tv_sec = 30
    timeout.tv_usec = 0
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

private func ignoreSignals() {
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
    _ = Darwin.signal(SIGTERM, SIG_IGN)
    _ = Darwin.signal(SIGINT, SIG_IGN)
}

/// Closes a listening socket once. `accept` unblocks on close; a second close
/// would reuse the file descriptor number and close the wrong socket.
final class CloseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) { self.fd = fd }

    func close() {
        lock.lock()
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 {
            Darwin.close(current)
        }
    }
}

private func log(_ message: String) {
    fputs(message + "\n", stdout)
    fflush(stdout)
}
