import Darwin
import Foundation

/// Parent side: `OCR_HTTP_VISION_WORKERS` resident child processes, one per
/// admission slot. The HTTP process only parses, authenticates and queues; a
/// child decodes the image and runs Vision. A child that reports a Vision
/// error, dies, or misses `OCR_HTTP_WORKER_TIMEOUT_MS` is SIGKILLed, reaped,
/// replaced, and the request is retried once on the fresh child.
///
/// No zombies or orphans:
/// - every child is reaped with `waitpid` exactly once (`WorkerProcess.reap`),
///   from a kqueue process-exit source, a 5 s sweep, or the request thread;
/// - children exit on their own when this process dies (see `WorkerMain`);
/// - `shutdown` (SIGTERM/SIGINT) sends SIGTERM, waits, then SIGKILLs and reaps.
final class WorkerPool: @unchecked Sendable {
    struct Settings {
        var workers: Int
        var timeoutMs: Int
        var maxTasks: Int
        var maxAgeSeconds: Int
    }

    private let settings: Settings
    private let slots: [WorkerSlot]
    private let languages = LanguageCache()
    private let executable: String
    private let environment: [String]
    private let monitorQueue = DispatchQueue(label: "macocr.worker.monitor")
    private let recycleQueue = DispatchQueue(label: "macocr.worker.recycle")
    private var sweepTimer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var shuttingDown = false
    private var live: [pid_t: WorkerProcess] = [:]
    private var nextID: UInt64 = 1
    private var restarts = 0

    init(settings: Settings) {
        self.settings = settings
        self.slots = (0..<max(1, settings.workers)).map { WorkerSlot(index: $0) }
        self.executable = currentExecutablePath()
        // The token never reaches a child.
        self.environment = ProcessInfo.processInfo.environment
            .filter { $0.key != "OCR_HTTP_TOKEN" && $0.key != "OCR_HTTP_TOKEN_FILE" }
            .map { "\($0.key)=\($0.value)" }
    }

    /// Spawns every worker and starts the sweep. Call after SIGPIPE is ignored.
    func start() {
        if let fault = ProcessInfo.processInfo.environment["OCR_HTTP_WORKER_FAULT"], !fault.isEmpty {
            fputs("WARNING: OCR_HTTP_WORKER_FAULT=\(fault) is set; workers will fail on purpose (tests only)\n", stderr)
        }
        for slot in slots {
            slot.lock.lock()
            _ = try? ensureWorker(slot)
            slot.lock.unlock()
        }
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.sweep() }
        sweepTimer = timer
        timer.resume()
    }

    func languageCatalog() throws -> LanguageCatalog {
        languages.catalog()
    }

    /// Blocks the calling connection thread (never an async context) until the
    /// worker for `index` answers. Admission guarantees one caller per index.
    func recognize(
        on index: Int,
        holder: DataHolder,
        job: OCRJob,
        maxPixels: Int,
        maxPixel: Int,
        minGlyphFrac: Double
    ) throws -> OCRPayload {
        let slot = slots[index]
        let image = holder.data
        holder.data = Data()
        stateLock.lock()
        let id = nextID
        nextID += 1
        stateLock.unlock()
        let header = try JSONEncoder().encode(WorkerRequest(
            id: id,
            job: job,
            maxPixels: maxPixels,
            maxPixel: maxPixel,
            minGlyphFrac: minGlyphFrac
        ))

        slot.lock.lock()
        defer { slot.lock.unlock() }
        var lastError: Error = OCREngineError.vision("recognition worker unavailable")
        for attempt in 1...2 {
            let worker: WorkerProcess
            do {
                worker = try ensureWorker(slot)
            } catch {
                lastError = error
                break
            }
            let deadline = Date().addingTimeInterval(TimeInterval(settings.timeoutMs) / 1000)
            do {
                let reply = try exchange(worker, id: id, header: header, image: image, deadline: deadline)
                if let payload = reply.payload {
                    worker.tasks += 1
                    if worker.tasks >= settings.maxTasks {
                        scheduleRecycle(slot, worker, reason: "served \(worker.tasks) tasks")
                    }
                    return payload
                }
                let failure = reply.failure ?? WorkerFailure(kind: "internal", message: "empty worker reply")
                guard failure.kind == "vision" else {
                    // Bad input or bad parameters: the worker is fine, the answer is final.
                    worker.tasks += 1
                    throw failure.asError
                }
                lastError = failure.asError
                replace(slot, worker, reason: "vision error: \(failure.message.prefix(160))", attempt: attempt)
            } catch let error as PipeError {
                switch error {
                case .timeout:
                    lastError = OCREngineError.vision("recognition worker timed out after \(settings.timeoutMs) ms")
                case .closed:
                    lastError = OCREngineError.vision("recognition worker exited unexpectedly")
                }
                replace(slot, worker, reason: "\(error)", attempt: attempt)
            }
        }
        throw lastError
    }

    /// `phys_footprint` of every live worker, so `/stats` `rssBytes` still
    /// covers all memory the service uses (HTTP process + workers).
    func workerFootprintBytes() -> UInt64 {
        stateLock.lock()
        let pids = Array(live.keys)
        stateLock.unlock()
        var total: UInt64 = 0
        for pid in pids {
            var info = rusage_info_v2()
            let rc = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw in
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, raw)
                }
            }
            if rc == 0 { total += info.ri_phys_footprint }
        }
        return total
    }

    /// SIGTERM to every child, up to `grace` seconds to exit, then SIGKILL.
    /// Every child is reaped before this returns.
    func shutdown(grace: TimeInterval) {
        stateLock.lock()
        shuttingDown = true
        let workers = Array(live.values)
        stateLock.unlock()
        sweepTimer?.cancel()
        for worker in workers { worker.signal(SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        var pending = workers
        while !pending.isEmpty && Date() < deadline {
            pending = pending.filter { !$0.reap(blocking: false) }
            if !pending.isEmpty { usleep(20_000) }
        }
        for worker in pending {
            fputs("worker pid=\(worker.pid) did not exit on SIGTERM; SIGKILL\n", stderr)
            worker.kill()
        }
        for worker in workers { forget(worker) }
    }

    // MARK: - Internals (slot lock held unless noted)

    private func ensureWorker(_ slot: WorkerSlot) throws -> WorkerProcess {
        if let current = slot.process {
            if current.reap(blocking: false) {
                fputs("worker[\(slot.index)] pid=\(current.pid) had exited (\(current.exitDescription)); replacing\n", stderr)
                retire(slot, current)
            } else if current.age > TimeInterval(settings.maxAgeSeconds) {
                retireGracefully(slot, current, reason: "age \(Int(current.age))s")
            } else {
                return current
            }
        }
        stateLock.lock()
        let stopping = shuttingDown
        stateLock.unlock()
        if stopping { throw OCREngineError.vision("server is shutting down") }
        let worker = try spawn(slot: slot.index)
        slot.process = worker
        return worker
    }

    private func exchange(_ worker: WorkerProcess, id: UInt64, header: Data, image: Data, deadline: Date) throws -> WorkerReply {
        let decoder = JSONDecoder()
        if !worker.greeted {
            let frame = try DeadlineIO.readFrame(worker.fromChild, deadline: deadline)
            guard let hello = try? decoder.decode(WorkerReply.self, from: frame),
                  hello.hello == WorkerWire.protocolVersion,
                  hello.pid == worker.pid else {
                throw PipeError.closed("bad hello from worker")
            }
            worker.greeted = true
        }
        try DeadlineIO.writeFrame(worker.toChild, header, deadline: deadline)
        try DeadlineIO.writeFrame(worker.toChild, image, deadline: deadline)
        let frame = try DeadlineIO.readFrame(worker.fromChild, deadline: deadline)
        guard let reply = try? decoder.decode(WorkerReply.self, from: frame), reply.id == id else {
            throw PipeError.closed("unreadable reply from worker")
        }
        return reply
    }

    /// Failure path: SIGKILL, reap, close, spawn a fresh one for the retry.
    private func replace(_ slot: WorkerSlot, _ worker: WorkerProcess, reason: String, attempt: Int) {
        worker.kill()
        stateLock.lock()
        restarts += 1
        let total = restarts
        stateLock.unlock()
        fputs("worker[\(slot.index)] pid=\(worker.pid) failed on attempt \(attempt) (\(reason)); killed and reaped (\(worker.exitDescription)); restarts=\(total)\(attempt == 1 ? "; retrying on a fresh worker" : "")\n", stderr)
        retire(slot, worker)
        stateLock.lock()
        let stopping = shuttingDown
        stateLock.unlock()
        if !stopping, let fresh = try? spawn(slot: slot.index) {
            slot.process = fresh
        }
    }

    /// Already dead and reaped: close our pipe ends and drop it.
    private func retire(_ slot: WorkerSlot, _ worker: WorkerProcess) {
        worker.closePipes()
        forget(worker)
        if slot.process === worker { slot.process = nil }
    }

    /// Healthy but due for replacement: EOF on its stdin, short wait, SIGKILL fallback.
    private func retireGracefully(_ slot: WorkerSlot, _ worker: WorkerProcess, reason: String) {
        worker.closeRequestPipe()
        let deadline = Date().addingTimeInterval(2)
        while !worker.reap(blocking: false) && Date() < deadline { usleep(10_000) }
        if !worker.reap(blocking: false) { worker.kill() }
        fputs("worker[\(slot.index)] pid=\(worker.pid) recycled (\(reason))\n", stderr)
        retire(slot, worker)
    }

    /// After a response is returned, replace the worker off the request path.
    private func scheduleRecycle(_ slot: WorkerSlot, _ worker: WorkerProcess, reason: String) {
        recycleQueue.async { [self] in
            slot.lock.lock()
            defer { slot.lock.unlock() }
            guard slot.process === worker else { return }
            retireGracefully(slot, worker, reason: reason)
            _ = try? ensureWorker(slot)
        }
    }

    private func forget(_ worker: WorkerProcess) {
        stateLock.lock()
        if live[worker.pid] === worker { live[worker.pid] = nil }
        stateLock.unlock()
        worker.exitSource?.cancel()
        worker.exitSource = nil
    }

    /// Not under the slot lock. Reaps exited children, and replaces dead or
    /// over-age idle workers when their slot is free.
    private func sweep() {
        stateLock.lock()
        let stopping = shuttingDown
        let workers = Array(live.values)
        stateLock.unlock()
        for worker in workers { _ = worker.reap(blocking: false) }
        guard !stopping else { return }
        for slot in slots where slot.lock.try() {
            defer { slot.lock.unlock() }
            if let current = slot.process, !current.isReaped, current.age <= TimeInterval(settings.maxAgeSeconds) {
                continue
            }
            if let current = slot.process, current.isReaped, current.age < 2 {
                continue // crashed right after spawn: leave it to the next request, no spawn loop
            }
            _ = try? ensureWorker(slot)
        }
    }

    private func onExit(_ worker: WorkerProcess) {
        guard worker.reap(blocking: false) else { return }
        stateLock.lock()
        let stopping = shuttingDown
        stateLock.unlock()
        guard !stopping else { return }
        // A worker that dies while idle is replaced now if its slot is free;
        // otherwise the request thread that holds the slot sees EOF and replaces it.
        let slot = slots[worker.slot]
        guard slot.lock.try() else { return }
        defer { slot.lock.unlock() }
        guard slot.process === worker else { return }
        fputs("worker[\(slot.index)] pid=\(worker.pid) exited while idle (\(worker.exitDescription)); reaped\n", stderr)
        retire(slot, worker)
        if worker.age >= 2 { _ = try? ensureWorker(slot) }
    }

    private func spawn(slot: Int) throws -> WorkerProcess {
        let worker = try WorkerProcess.spawn(
            executable: executable,
            slot: slot,
            environment: environment
        )
        let source = DispatchSource.makeProcessSource(identifier: worker.pid, eventMask: .exit, queue: monitorQueue)
        source.setEventHandler { [weak self, weak worker] in
            guard let self, let worker else { return }
            self.onExit(worker)
        }
        worker.exitSource = source
        stateLock.lock()
        live[worker.pid] = worker
        stateLock.unlock()
        source.resume()
        fputs("worker[\(slot)] pid=\(worker.pid) spawned\n", stderr)
        return worker
    }
}

final class WorkerSlot: @unchecked Sendable {
    let index: Int
    let lock = NSLock()
    var process: WorkerProcess?
    init(index: Int) { self.index = index }
}

final class WorkerProcess: @unchecked Sendable {
    let pid: pid_t
    let slot: Int
    let toChild: Int32
    let fromChild: Int32
    let started = Date()
    var tasks = 0
    var greeted = false
    var exitSource: DispatchSourceProcess?

    private let lock = NSLock()
    private var reaped = false
    private var status: Int32 = 0
    private var requestOpen = true
    private var replyOpen = true

    private init(pid: pid_t, slot: Int, toChild: Int32, fromChild: Int32) {
        self.pid = pid
        self.slot = slot
        self.toChild = toChild
        self.fromChild = fromChild
    }

    var age: TimeInterval { Date().timeIntervalSince(started) }

    var isReaped: Bool {
        lock.lock(); defer { lock.unlock() }
        return reaped
    }

    var exitDescription: String {
        lock.lock(); defer { lock.unlock() }
        guard reaped else { return "running" }
        let signal = status & 0x7f
        if signal == 0 { return "exit \((status >> 8) & 0xff)" }
        return "signal \(signal)"
    }

    /// `waitpid` at most once per child, under the lock, so a recycled pid is
    /// never waited on by mistake. Returns true once the child is reaped.
    @discardableResult
    func reap(blocking: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if reaped { return true }
        var value: Int32 = 0
        while true {
            let result = waitpid(pid, &value, blocking ? 0 : WNOHANG)
            if result == pid {
                reaped = true
                status = value
                return true
            }
            if result == 0 { return false }
            if errno == EINTR { continue }
            // ECHILD: nothing left to wait for.
            reaped = true
            return true
        }
    }

    func signal(_ sig: Int32) {
        lock.lock(); defer { lock.unlock() }
        if !reaped { _ = Darwin.kill(pid, sig) }
    }

    /// SIGKILL and a blocking reap.
    func kill() {
        signal(SIGKILL)
        reap(blocking: true)
    }

    func closeRequestPipe() {
        lock.lock(); defer { lock.unlock() }
        if requestOpen { Darwin.close(toChild); requestOpen = false }
    }

    func closePipes() {
        lock.lock(); defer { lock.unlock() }
        if requestOpen { Darwin.close(toChild); requestOpen = false }
        if replyOpen { Darwin.close(fromChild); replyOpen = false }
    }

    static func spawn(executable: String, slot: Int, environment: [String]) throws -> WorkerProcess {
        var request: [Int32] = [-1, -1]
        var reply: [Int32] = [-1, -1]
        guard pipe(&request) == 0 else { throw OCREngineError.vision("worker pipe failed") }
        guard pipe(&reply) == 0 else {
            Darwin.close(request[0]); Darwin.close(request[1])
            throw OCREngineError.vision("worker pipe failed")
        }
        for fd in [request[1], reply[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, request[0], 0)
        posix_spawn_file_actions_adddup2(&actions, reply[1], WorkerWire.replyFD)
        posix_spawn_file_actions_adddup2(&actions, 2, 1)
        posix_spawn_file_actions_addinherit_np(&actions, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors above reach the child: no listen or client sockets.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let args = [executable, WorkerWire.workerFlag, "--parent-pid", String(getpid()), "--slot", String(slot)]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        Darwin.close(request[0])
        Darwin.close(reply[1])
        guard rc == 0 else {
            Darwin.close(request[1]); Darwin.close(reply[0])
            throw OCREngineError.vision("could not start recognition worker: \(String(cString: strerror(rc)))")
        }
        return WorkerProcess(pid: pid, slot: slot, toChild: request[1], fromChild: reply[0])
    }
}

private func currentExecutablePath() -> String {
    if let url = Bundle.main.executableURL {
        return url.resolvingSymlinksInPath().path
    }
    return CommandLine.arguments[0]
}
