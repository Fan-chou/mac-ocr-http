import Darwin
import Foundation

do {
    let config = try AppConfig.load()
    let server = HTTPServer(config: config)
    try server.run()
} catch {
    fputs("fatal: \(error)\n", stderr)
    // Under launchd (parent pid 1) a bad config would restart every 2s.
    // Hold off so the log shows one line per 30s instead of a crash loop.
    if getppid() == 1 { sleep(30) }
    Darwin.exit(1)
}
