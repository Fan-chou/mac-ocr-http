import Darwin
import Foundation

/// Child side of the worker pool: `mac-ocr-http --ocr-worker --parent-pid N --slot I`.
///
/// Lifetime rules, so a worker never outlives the HTTP process:
/// - A kqueue `NOTE_EXIT` watch on the parent pid calls `_exit` the moment the
///   parent dies, even while Vision is busy on the work queue.
/// - EOF on fd 0 (the parent closed the request pipe) exits too.
/// - A failed reply write (parent gone) exits.
/// - SIGTERM and SIGINT have their default action (the parent resets them at spawn).
enum WorkerMain {
    static func isWorkerInvocation(_ arguments: [String]) -> Bool {
        arguments.dropFirst().first == WorkerWire.workerFlag
    }

    static func run(_ arguments: [String]) -> Never {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        var parent: pid_t = 0
        var slot = "?"
        var index = 2
        while index < arguments.count {
            if arguments[index] == "--parent-pid", index + 1 < arguments.count {
                parent = pid_t(arguments[index + 1]) ?? 0
                index += 2
            } else if arguments[index] == "--slot", index + 1 < arguments.count {
                slot = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        guard parent > 1, getppid() == parent else {
            fputs("ocr-worker: parent pid mismatch (expected \(parent), have \(getppid())); exiting\n", stderr)
            Darwin._exit(2)
        }
        watchParent(parent)
        let fault = WorkerFault.fromEnvironment()
        if let fault {
            fputs("ocr-worker[\(slot)] pid=\(getpid()) FAULT INJECTION ON: \(fault.describe)\n", stderr)
        }

        let queue = DispatchQueue(label: "macocr.worker.vision")
        queue.async {
            serve(slot: slot, fault: fault)
        }
        dispatchMain()
    }

    /// Exits as soon as `parent` exits. The registration is checked against
    /// `getppid()` afterwards, so a parent that died before the watch was armed
    /// is also caught (the child is then reparented to launchd).
    private static func watchParent(_ parent: pid_t) {
        let kq = kqueue()
        guard kq >= 0 else { Darwin._exit(3) }
        var change = kevent64_s(
            ident: UInt64(parent),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: 0,
            ext: (0, 0)
        )
        if kevent64(kq, &change, 1, nil, 0, 0, nil) != 0 { Darwin._exit(0) }
        if getppid() != parent { Darwin._exit(0) }
        let thread = Thread {
            var event = kevent64_s()
            while true {
                let n = kevent64(kq, nil, 0, &event, 1, 0, nil)
                if n > 0 { Darwin._exit(0) }
                if n < 0 && errno != EINTR { Darwin._exit(0) }
            }
        }
        thread.name = "parent-watch"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    private static func serve(slot: String, fault: WorkerFault?) -> Never {
        let recognizer = VisionRecognizer()
        recognizer.warmUp()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let me = getpid()
        guard let hello = try? encoder.encode(WorkerReply(id: 0, hello: WorkerWire.protocolVersion, pid: me)),
              BlockingIO.writeFrame(WorkerWire.replyFD, hello) else {
            Darwin._exit(0)
        }
        var tasks = 0
        while true {
            guard let header = BlockingIO.readFrame(0) else { Darwin._exit(0) }
            guard let image = BlockingIO.readFrame(0) else { Darwin._exit(0) }
            guard let request = try? decoder.decode(WorkerRequest.self, from: header) else {
                fputs("ocr-worker[\(slot)] bad request frame; exiting\n", stderr)
                Darwin._exit(4)
            }
            tasks += 1
            var reply = WorkerReply(id: request.id)
            if let fault, fault.fires(on: tasks) {
                switch fault.mode {
                case .crash:
                    fputs("ocr-worker[\(slot)] pid=\(me) injected crash on task \(tasks)\n", stderr)
                    Darwin.abort()
                case .exit:
                    fputs("ocr-worker[\(slot)] pid=\(me) injected exit on task \(tasks)\n", stderr)
                    Darwin._exit(7)
                case .hang:
                    fputs("ocr-worker[\(slot)] pid=\(me) injected hang on task \(tasks)\n", stderr)
                    while true { Darwin.sleep(3600) }
                case .hangterm:
                    // Ignores SIGTERM too, to exercise the parent's SIGKILL fallback.
                    _ = Darwin.signal(SIGTERM, SIG_IGN)
                    fputs("ocr-worker[\(slot)] pid=\(me) injected hang (SIGTERM ignored) on task \(tasks)\n", stderr)
                    while true { Darwin.sleep(3600) }
                case .vision:
                    reply.failure = WorkerFailure(kind: "vision", message: "TextRecognition.CRImageReaderError error 1 (injected)")
                }
            }
            if reply.failure == nil {
                let holder = DataHolder(image)
                do {
                    reply.payload = try recognizer.recognize(
                        holder: holder,
                        job: request.job,
                        maxPixels: request.maxPixels,
                        maxPixel: request.maxPixel,
                        minGlyphFrac: request.minGlyphFrac
                    )
                } catch {
                    reply.failure = WorkerFailure(error)
                }
            }
            let data: Data
            if let encoded = try? encoder.encode(reply) {
                data = encoded
            } else {
                let fallback = WorkerReply(id: request.id, failure: WorkerFailure(kind: "internal", message: "could not encode OCR result"))
                data = (try? encoder.encode(fallback)) ?? Data()
            }
            guard BlockingIO.writeFrame(WorkerWire.replyFD, data) else { Darwin._exit(0) }
        }
    }
}

/// Test-only fault injection, read from `OCR_HTTP_WORKER_FAULT` in the worker's
/// environment: `crash:N`, `exit:N`, `hang:N`, `hangterm:N` (hang and ignore
/// SIGTERM), or `vision:N` fires on every Nth
/// task of each worker (N=1: every task, so the retry fails too). Unset in the
/// LaunchAgent; the HTTP process logs a warning when it is set.
struct WorkerFault {
    enum Mode: String { case crash, exit, hang, hangterm, vision }
    var mode: Mode
    var every: Int

    var describe: String { "\(mode.rawValue) every \(every) task(s)" }

    func fires(on task: Int) -> Bool { task % every == 0 }

    static func fromEnvironment() -> WorkerFault? {
        parse(ProcessInfo.processInfo.environment["OCR_HTTP_WORKER_FAULT"])
    }

    static func parse(_ raw: String?) -> WorkerFault? {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard let mode = Mode(rawValue: parts[0]) else { return nil }
        let every = parts.count > 1 ? max(1, Int(parts[1]) ?? 1) : 1
        return WorkerFault(mode: mode, every: every)
    }
}
