# Agents

macOS-only Swift package `MacOcrHttp`. Binary name `mac-ocr-http`. Do not claim `swift build` or Vision OCR ran unless you actually did it on a Mac. Linux CI cannot compile this package.

## Do not

- Bind `0.0.0.0`, a wildcard, IPv6, or a public address. Listen addresses come only from `OCR_HTTP_HOST`/`--host`, validated to 127/8 + RFC1918 by `validateListenHost`. Keep Bearer on everything but `/health`.
- Read a path from the request, or download an image URL. That includes `file://` and "the client is local".
- `await` inside Vision recognition, or add an unbounded `Task`/`DispatchQueue.global` fan-out. Each `OCR_HTTP_VISION_WORKERS` slot is one worker child process (`--ocr-worker`) that runs one `perform` at a time on its one serial queue. Tiles of one image stay in that process. The recognize body stays synchronous.
- Run Vision in the HTTP process, or let a worker outlive it. Every child is reaped exactly once through `WorkerProcess.reap`; workers watch the parent pid with kqueue `NOTE_EXIT`; `SIGTERM` shuts workers down (SIGTERM, 3 s, SIGKILL, reap) before exit. Do not pass the token or any socket to a worker. `OCR_HTTP_WORKER_FAULT` is a test hook and never goes in the LaunchAgent.
- Silently downscale the tile path. Default `scale` is `auto`: one probe pass at a long side of at most 4096, then a full-resolution tile grid only when glyph size / long side is under `OCR_HTTP_TILE_MIN_GLYPH_FRAC` (default 0.012) or the probe found fewer than 8 lines of at least 3 width units. A long side of at most 2048 stays one pass. `scale=none` is the old grid (tile when either side is over 2048) with no probe. `OCR_HTTP_MAX_PIXEL` applies only to `scale=downscale`. `force=whole` or `force=tile` is only valid with `scale=auto`.
- Drop an OCR fragment because its box only shares the tile-overlap sliver, or because the normalized text is similar. Dedupe requires real geometric coincidence (IoU ≥ 0.5, 80% containment, or same-band x-overlap ≥ 80% of the narrower width). A one-tile image skips dedupe. Row joining trims only the characters whose estimated x lies inside an earlier fragment. A gap is kept on one row only when the fragment was cropped by its own tile edge; a column gutter still splits. Column gutters are whitespace wider than 1.5× the median line height. Seam fragments are stitched in `Sources/LineMergeCore`.
- Return HTTP 200 for a failed OCR. Error JSON uses 4xx/5xx.
- Commit a real token, or put one in `install/com.example.mac-ocr-http.plist`. `scripts/install.sh` substitutes placeholders and chmod `600`. The LaunchAgent label is `OCR_HTTP_LABEL`, default `com.example.mac-ocr-http`.
- Add a third-party HTTP stack. The reader accepts HTTP/1.0 and 1.1 origin-form with `Content-Length` only.

## Layout

- `Sources/MacOcrHttp/HTTP` — per-address listen sockets, strict HTTP/1.1, routes
- `Sources/MacOcrHttp/Auth/BearerAuth.swift` — Bearer compare
- `Sources/LineMergeCore` — pure dedupe and row grouping (no Vision). `text` is one visual row per line; `lines[]` stay granular; `rows[]` carries the joined text. `swift run mac-ocr-line-merge-tests`.
- `Sources/MacOcrHttp/OCR` — ImageIO decode, EXIF, geometry, tiling, the in-worker Vision recognizer
- `Sources/MacOcrHttp/Worker` — worker child processes: pipe protocol, child main loop, parent pool (spawn, retry, reap, shutdown)
- `install/com.example.mac-ocr-http.plist` — template, not a loadable agent
- `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/smoke.sh`, `scripts/eval_large.py`

Default port `8741`. Token env `OCR_HTTP_TOKEN`. Health is unauthenticated. `/languages`, `/stats`, and `/ocr` are not.

Chinese and Japanese language tags force `usesLanguageCorrection = false`. Default language order is `zh-Hans`, `en-US`.

Pixel boxes are top-left. Vision normalized rects are bottom-left: `y = (1 - origin.y - height) * pixelHeight`.
