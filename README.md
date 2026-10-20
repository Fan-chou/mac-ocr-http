# mac-ocr-http

A local macOS HTTP service for Apple Vision OCR. It uses bearer auth, adaptive tiling for large images, Chinese and English, and groups recognized text into rows and columns.

A single native binary listens on **127.0.0.1** by default, and optionally on private LAN addresses (`OCR_HTTP_HOST`), started at login by a LaunchAgent and restarted if it crashes.

GitHub: [Fan-chou/mac-ocr-http](https://github.com/Fan-chou/mac-ocr-http). MIT, Copyright (c) 2026 Jack Chou (Fan-chou).

This tree compiles with the native Swift build system on macOS 13 or newer. On a machine that only has the Command Line Tools (Xcode.app present, license not agreed), the default XCBuild fails with “Unknown error parsing property list”. Use `--build-system native`.

## Security

- Listen addresses come from `OCR_HTTP_HOST` (or `--host`, same rules): a comma-separated list of IPv4 literals, default `127.0.0.1`. Only `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16` are accepted. `0.0.0.0`, `*`, hostnames, IPv6 and public addresses are a fatal config error. One socket is bound per address, and `getsockname` must return exactly that address.
- `GET /health` is open. `GET /languages`, `GET /stats`, `POST /ocr`, and `/v1/*` require `Authorization: Bearer <token>` on every address, LAN included. `OPTIONS /v1/*` is an unauthenticated CORS preflight and returns no data. Anyone on the LAN who has the token can OCR; treat it like a password.
- The server never reads a filesystem path and never fetches a URL. On `POST /ocr`, JSON fields `path`, `url`, `image_url`, and `file` are rejected. On `/v1/*`, `image_url` is accepted only as a `data:` base64 URL; `http:`, `https:`, and `file:` are rejected with HTTP 400.
- Chunked `Transfer-Encoding` on a request is rejected. Send `Content-Length` (curl does). A `stream: true` response is chunked HTTP/1.1; that is the server writing, not the client.
- Call `http://127.0.0.1:8741`, not `localhost`. `localhost` may resolve to `::1`, and this process does not listen there.

## Requirements

- macOS 13 or newer
- Xcode or the Command Line Tools (`swift`, `clang`)
- A logged-in GUI user for the LaunchAgent

## Build

```bash
swift build -c release --build-system native
```

The binary is `.build/release/mac-ocr-http`. It matches the architecture of the Mac that built it.

## Run in the foreground

```bash
export OCR_HTTP_TOKEN="$(openssl rand -hex 32)"
export OCR_HTTP_PORT=8741
.build/release/mac-ocr-http
```

Token lookup order: `OCR_HTTP_TOKEN`, then `OCR_HTTP_TOKEN_FILE`, then `~/Library/Application Support/MacOcrHttp/token`. The token must be at least 16 characters. Placeholder values are refused. The process does not print the token.

| Variable | Default |
|---|---|
| `OCR_HTTP_HOST` | `127.0.0.1`. Comma-separated, e.g. `127.0.0.1,192.168.1.50`. Loopback and RFC1918 only. |
| `OCR_HTTP_LABEL` | `com.example.mac-ocr-http`. LaunchAgent label. Set this to the label already installed on the machine when upgrading. |
| `OCR_HTTP_PORT` | `8741` |
| `OCR_HTTP_MAX_BODY_BYTES` | 20971520 (clamped to 1–32 MiB) |
| `OCR_HTTP_MAX_PIXELS` | 100000000 (clamped to 1000000–200000000). Refuses the image; does not shrink it. |
| `OCR_HTTP_MAX_PIXEL` | 4096 (clamped to 1024–8192). Long edge only when `scale=downscale`. |
| `OCR_HTTP_VISION_WORKERS` | `2` (clamped to 1–4). Number of recognition worker processes. Each runs one `VNImageRequestHandler` at a time; tiles of one image stay in that process. See [Worker processes](#worker-processes). |
| `OCR_HTTP_WORKER_TIMEOUT_MS` | `300000` (clamped to 5000–600000). Deadline for one recognition in a worker. Past it the worker is killed and the request is retried once on a fresh one. |
| `OCR_HTTP_WORKER_MAX_TASKS` | `500`. A worker is replaced (in the background) after this many requests. |
| `OCR_HTTP_WORKER_MAX_AGE_S` | `3600` (clamped to 60–604800). An idle worker older than this, by wall clock (so time asleep counts), is replaced. |
| `OCR_HTTP_QUEUE_MAX` | `64` (clamped to 1–256). Requests wait for a worker instead of failing immediately. |
| `OCR_HTTP_QUEUE_TIMEOUT_MS` | `180000` (clamped to 1–300000) |
| `OCR_HTTP_TILE_MIN_GLYPH_FRAC` | `0.012` (clamped to 0.001–0.2). `scale=auto` tiles when glyph size / long side is below this. `OCR_HTTP_TILE_MIN_TEXT_FRAC` is a deprecated alias, used only when the new variable is unset. |
| `OCR_HTTP_OPENAI_MODEL` | `mac-ocr`. The id returned by `GET /v1/models`. A chat request may name any model; the response echoes that name. |
| `OCR_HTTP_DEBUG_CAPTURE_DIR` | Unset. Off unless this is a directory path. See [Debug capture](#debug-capture). |
| `OCR_HTTP_DEBUG_CAPTURE_MAX` | `50` (clamped to 1–10000). How many captures to keep. |

## Install the LaunchAgent

`scripts/install.sh` builds the release binary, copies it to `~/Library/Application Support/MacOcrHttp/mac-ocr-http`, writes a mode `0600` token file (reused if it already exists), renders `~/Library/LaunchAgents/<OCR_HTTP_LABEL>.plist` mode `0600`, and bootstraps `gui/$(id -u)`. The default label is `com.example.mac-ocr-http`.

The plist template in `install/` contains placeholders. Do not `launchctl bootstrap` that file. The script is the installer.

```bash
./scripts/install.sh
# optional, written into the LaunchAgent plist:
# OCR_HTTP_HOST=127.0.0.1,192.168.1.50 OCR_HTTP_PORT=8741 \
#   OCR_HTTP_VISION_WORKERS=2 OCR_HTTP_QUEUE_MAX=64 \
#   OCR_HTTP_QUEUE_TIMEOUT_MS=180000 \
#   OCR_HTTP_TOKEN="$(openssl rand -hex 32)" ./scripts/install.sh
```

Logs: `~/Library/Logs/MacOcrHttp/stdout.log` and `stderr.log`. `KeepAlive` and `RunAtLoad` are set, with a 2 second throttle so a crash loop does not spin.

## LAN listening

```bash
OCR_HTTP_HOST=127.0.0.1,192.168.1.50 ./scripts/install.sh
lsof -nP -iTCP:8741 -sTCP:LISTEN   # one line per address, never *:8741
```

Keep `127.0.0.1` in the list so local callers never depend on Wi-Fi. LAN clients call `http://192.168.1.50:8741` with the same Bearer token. Replace `192.168.1.50` with that machine's address.

DHCP: an address that is not on any interface at startup (`EADDRNOTAVAIL`), or whose bind fails, is logged once to `stderr.log` as `listen 192.168.1.50:8741 unavailable (Can't assign requested address); retrying every 30s`. The other addresses keep serving. The missing one is retried every 30s in-process and logged once as `listen ... is now up`. If no address binds, the process stays up and keeps retrying, so launchd does not crash-loop. A fatal config error under launchd waits 30s before exiting. If the router hands the Mac a different IP, the old address simply never comes up: **reserve the Mac's IP in the router's DHCP settings** (static lease for its Wi-Fi MAC), or rerun `install.sh` with the new address.

Firewall: the macOS application firewall was off when this was set up, so nothing needs allowing. If you turn it on, allow `~/Library/Application Support/MacOcrHttp/mac-ocr-http` in System Settings → Network → Firewall → Options (rebuilding changes the binary, so macOS may ask again).

```bash
./scripts/uninstall.sh          # unload and delete the plist
./scripts/uninstall.sh --purge  # also delete the binary, token, and logs
```

## API

`GET /health` → `200` `{"ok":true}`. Unauthenticated and cheap. It does not read counters.

`GET /stats` → Bearer. `inFlight`, `queued`, `rejected`, `workers`, and `rssBytes` (`phys_footprint` of the HTTP process plus every worker process).

`GET /languages` → Bearer. `defaults` lists `zh-Hans`, `en-US`. `accurate` and `fast` are the Vision catalogs on this Mac, with those two first when present.

`POST /ocr` → Bearer. Either:

- `Content-Type: application/json` with `{"image":"<base64>","level":"accurate","scale":"auto","languages":["zh-Hans","en-US"]}`
- `Content-Type: image/*` and the raw file as the body. `level`, `scale`, `languages`, `maxPixel`, `script`, `layout`, `force`, `tileMinGlyphFrac`, and `fragments` are query parameters. A JSON field wins over the same query key. Query keys are lowercased. `tileMinTextFrac` is accepted as a deprecated alias when `tileMinGlyphFrac` is absent.

`level` is `accurate` (default) or `fast`. Omitted languages use `zh-Hans`, `en-US`, dropping any the OS does not support. The path is query or JSON `languages` → `makeJob` → `OCREngine.resolveLanguages` (checked against `supportedRecognitionLanguages` for that level) → `VNRecognizeTextRequest.recognitionLanguages`. `automaticallyDetectsLanguage` is set to `false` before that assignment. The response `languages` field is the array read back from the request, and `revision` is `request.revision`. On current Vision, `zh-Hans` and `zh-Hant` can share one model, so those two lists can still produce the same text; the echo shows which list was actually set. If a requested language includes Chinese or Japanese, `usesLanguageCorrection` is turned off.

`script` is `hans` or `auto`. The default is `hans` when `zh-Hans` is the first selected language and the request does not include `zh-Hant`. `hans` runs `CFStringTransform` with `Hant-Hans` on `lines[].text`, `rows[].text`, and `text`, then a fixed Japanese-shinjitai map (`発→发`, `気→气`, `満→满`, `対→对`, `実→实`, and the rest of the table in `Shinjitai.swift`). Kana is not in the table. `浄` maps to `净` and `済` maps to `济`. An explicit `zh-Hant` request does not convert, even if `script=hans`. `auto` does not convert.

`layout` is `rows` (default) or `document`. `rows` is the tile recognizer below and is what you want for this photo. `document` is opt-in. On the angled report page it was faster (about 1.2s against 3.7s) and the paragraph order was better, but the text was much worse: 1839 characters against about 3100, garbled, with 21 kana. Leave it off unless you are comparing layout. It calls `RecognizeDocumentsRequest` once on the full bitmap when the process is on macOS 26 or newer and this build was compiled with `OCR_HTTP_HAS_DOCUMENT_LAYOUT` (on by default; delete that define in `Package.swift` to build an SDK that does not have the symbol). The macOS 27 SDK needs the options object taken from the request, `recognitionLanguages` as `[Locale.Language]`, and a revision index rather than `rawValue`. It does not tile. The bitmap must be at most 8192px on a side and at most 40000000 pixels, otherwise `400` and the image is not shrunk. Paragraphs become `blocks[]`; each paragraph's lines become `lines[]` and `rows[]`. The async `perform` is bridged with a semaphore on the worker queue. There is no `await` in the pool. `level` is not a separate document-recognizer switch. Tables and lists stay inside the Vision observation; this response maps paragraphs, which is what that API uses for reading order.

`scale` is `auto` (default), `none`, `tile`, or `downscale`. Anything else is `400`.

- `auto` probes with one whole-image pass. When the long side is over 4096, that probe is drawn at 4096 and the boxes are scaled back onto the original pixel grid. A native whole pass and a 4096 pass produced byte-identical text on the 5712px report photo, because Vision already downsamples a whole image by its long side. The probe is kept when the measured glyphs are large enough. Otherwise the original bitmap is tiled, and the probe is not counted in `tiles`. A long side of at most 2048 is already one tile, so that page stays a single pass. A long side of at most 4096 is **not** an automatic whole pass: a 3024×4032 page of small type still tiles. `force=whole` or `force=tile` overrides the choice (`force` is rejected unless `scale=auto`). `tileMinGlyphFrac` overrides the threshold for that request (0.001–0.2). The response reports `mode` (`whole` or `tiled`), `glyphPx`, `glyphFrac`, and `tileDecision`.

- `fragments=drop` (default) removes UI noise from a whole-image pass: a short low-confidence observation far smaller than the main text that touches an image edge (corner watermark), a one-glyph low-confidence observation just left of a label (icon), a wide low-confidence leading glyph (icon read as a character), and a narrow low-confidence leading CJK glyph on the left image edge (character cut by the crop). Only Vision's lowest confidence bucket (below 0.4) is touched, and tiled passes are left alone because a tile edge is not an image edge. `fragments=keep` turns it off. `/v1` requests always use the default.
- `none` is the previous default: full resolution, and a tile grid when either side is longer than 2048. It does not run the whole-image probe.
- `tile` always uses that tiling path. A small image is one tile.
- `downscale` is the old path: the long edge is reduced to `maxPixel` or `OCR_HTTP_MAX_PIXEL` (default 4096, request values must be 1024–8192). Boxes are scaled back onto the original pixel grid. `OCR_HTTP_MAX_PIXEL` does nothing for `auto`, `none`, or `tile`.

The decision uses glyph size, not the median box height. A failing whole pass returns a few merged multi-line boxes, so the box height goes up: a 36px sweep page measured 0.030 of the image height while the pass failed (CER 0.85). That height signal got 12 of 63 decisions wrong. Glyph size is the median, over lines, of box width divided by width units (CJK and full-width characters count as 1, other characters as 0.55, whitespace skipped). Lines under 3 width units are ignored. Divide by the long side, which is what Vision scales by.

Tile when `glyphFrac` is below **0.012**, or when fewer than 8 qualifying lines were found. The line-count guard is what catches the 7000×5000 and 8400×6000 fixtures (the whole pass returns 0 lines) and a halftone page whose 4 junk lines report a bogus fraction around 0.05.

T = 0.012 is the minimum of a severity-weighted excess error on 57 ground-truth pages that need more than one tile (Mac, 2026-10-09): 0.312 at 0.012, against 0.405 at 0.011, 0.335 at 0.0125, and 0.438 at 0.014. Below 0.009 a whole pass failed 18 of 20 pages; between 0.009 and 0.012 it failed 5 of 16; at or above 0.012 it failed 0 of 21. Going whole by mistake costs about 0.2–0.8 CER. Tiling by mistake costs about 0.01–0.06. Clean renders cross nearer 0.0085–0.009; degraded photos cross at 0.012–0.013. On a 4032px long side, 0.012 is about 48px glyphs. A single-column page whose glyphs are about 56px on that long side stays one pass. A dense page whose glyphs are about 42px on a 5712px long side tiles. `tiles` counts the passes whose lines are returned. When `auto` tiles, `elapsedMs` also includes the probe.

Tiles are 2048px with 256px overlap, walked left-to-right, top-to-bottom, one Vision pass at a time inside the worker. When `auto` tiles after its probe, the tile side adapts to the probe's glyph height: `clamp(glyphPx / 0.011, 1024, 2048)` in bitmap pixels. Vision's accurate recognizer silently drops whole runs of lines once glyphs fall to about 0.7% of the tile side (a 1700×2048 tile of 15px text lost most of its lines; 1400px tiles of the same page lost none). Glyphs of about 23px or more keep the 2048 grid. A shrunken tile overlaps by three line heights (1.5× glyph each) and never less than 256; full 2048 tiles always overlap by exactly 256. An axis no longer than 1.3× a shrunken tile (and at most 2048) is not cut, so a 1700px-wide page of 15px text is read in full-width strips. `force=tile`, `scale=tile`, and `scale=none` keep the fixed 2048 grid.

Vision sometimes reads a short run of rotation-ambiguous digits upside down inside an upright page ("37" as "LE", "620" as "0Z9"); the quad of such a line comes back turned 180°. Upright beats flipped: a flipped line that an upright line covers (IoU ≥ 0.3, or the smaller box half covered) is dropped whatever its confidence. A flipped line with no upright counterpart is read again from a padded crop of the bitmap (at most 64 crops per request); only upright readings of that crop are kept, otherwise it is dropped. When more than 30% of the lines are flipped the page itself is upside down and nothing is changed. Every text comparison uses a match key computed once per line: NFKC (full-width digits and letters become half-width), every Unicode whitespace character removed, then `lowercased()`.

A fragment is dropped only when the boxes really coincide and the keys then match. Coincidence means IoU at least 0.5, the smaller box at least 80% inside the other, or the same row band with an x-overlap of at least 80% of the narrower width. Same band means the vertical overlap is at least 50% of the shorter height, or the center-y distance is at most half the median line height. A tile seam is about 256px, so two long fragments that only share that strip do not coincide and both stay. Pairs are limited to a y-window, and the key is compared only after geometry passes.

Each observation is tagged with the tile that produced it. Two lines that both sit fully in a tile's non-overlap interior are never removed as duplicates of each other. Two lines that each lie at least 80% inside the same overlap strip, on the same band, with matching keys and a real x-overlap, are duplicates: the one whose center is farther from its own tile's seam edge is kept. A single-tile image skips that dedupe and only groups rows and columns.

Keys match when they are equal, the shorter key (at least 4 characters) is contained in the longer, or Levenshtein similarity is at least 0.85. The same phrase on another row is not a duplicate. When one key contains the other, the longer text is kept even if its confidence is lower. Otherwise the higher confidence is kept. `lines[]` stays one entry per remaining observation, in center-y then x order, with original-pixel `bbox` and `quad`.

`rows[]` is the reading order, from a recursive XY-cut. Full-width whitespace at least one median line height tall is measured on the real y intervals (a 4px bin was hiding the header gap). Each such gap splits the page; the slices run top to bottom, then the cut repeats. Inside a slice, vertical gutters split columns. A projection gutter is an x-range no line box covers, wider than 1.5× the median line height, in a window at least three lines tall. A photo gutter is voted per row instead: three consecutive rows each open a gap of at least 1× that median, the shared overlap is at least 0.5×, and the median of the three gap widths is still at least 1.5×. The run keeps going while that x-range stays empty, so one long box that only narrows the shared overlap does not erase the column. A gap with both edges sitting on a tile crop is not a vote. Up to 15% of the lines in the run may cross the gutter; they stay with the column of their center. A window that found no gutter does not glue the lines inside it into one block. A line wider than 60% of the window is left out of the gutter projection so a banner does not hide the columns under it. A box that itself crosses a gutter is not glued into a column: it ends the band above it, and the lines on that row stay with it. Columns whose tops sit within 2× the median line height are read left to right; a card that starts far lower does not jump ahead of them. The cut repeats inside a column. `blocks[]` is `{bbox, rowIndices}`. Before any cut, a grid table is detected: at least three text rows whose cells fall into at least three shared columns (the union of cell x-extents), one cell per column, covering at least 60% of the lines, with a median cell of at most 16 characters. Three columns of running prose line up row by row as well; their long cells keep them prose. A table is not cut into columns: each table row becomes one row across all columns, cells left to right joined by a tab.

Inside a block, fragments cluster on y. A fragment joins the current row band when its center is within 0.5× the median line height of the band, and the band's center spread stays within 1.25× that median. A 50% height overlap is not enough on its own: two stacked lines with tall boxes stay two rows, so the lower line's left half is not trimmed away. Inside the band, fragments sort by x. The gap is measured from the running right edge. Touching or overlapping fragments stay on one row. A gap that overlaps a detected column gutter starts a new row even when a tile edge is involved. Otherwise a gap stays on one row only when the two fragments come from different tiles and one of them was actually cropped: the left fragment's right edge is within `max(8, min(24, 0.5×median))` pixels of its tile's right edge, or the right fragment's left edge is within that distance of its tile's left edge. A fragment that merely begins inside the overlap strip, with whitespace beside it, splits. Any other gap wider than 2× the median line height starts a new row. A gutter can leave a seam copy in another block. After the columns are ordered, a row whose box is at least 80% inside a larger row, and whose center is within one line height of that row, is folded back into it. A scrap of at most three characters, or narrower than two line heights, joins the same way when at least 80% of its width lies on the larger row. An oversized box does not swallow the line below it.

When two fragments in that row overlap in x, the right-hand fragment loses every character whose estimated center falls inside an earlier fragment. Character width is the fragment's box width divided by its character count. A normalized suffix/prefix match of 2 to 6 characters then tidies the cut. The cap is 6 so the next copy of a repeated phrase, past the overlap, is kept. A fragment that lies entirely inside a longer one is dropped, including a short seam scrap such as `ce` or `e`, unless it carries an `L###` or `E###` marker the text already kept does not. Characters outside the overlap are not dropped. Fragments are joined with a single space, or with no space when both characters at the join are CJK (Han, kana, or Hangul). `text` is `rows[].text` joined by newlines, one visual row per line. Each row's `confidence` is the mean of its lines, rounded to 4 decimals. `lineIndices` index into `lines[]`.

A `data:image/...;base64,` prefix is accepted. `http://`, `https://`, and `file:` are not.

Success is `200`:

```json
{
  "ok": true,
  "text": "line one",
  "width": 1200,
  "height": 800,
  "scale": "auto",
  "tiles": 1,
  "mode": "whole",
  "glyphPx": 25.97,
  "glyphFrac": 0.032468,
  "tileDecision": "whole: long side 800 <= 2048",
  "elapsedMs": 140,
  "languages": ["zh-Hans", "en-US"],
  "revision": 3,
  "script": "hans",
  "layout": "rows",
  "lines": [
    {
      "text": "line one",
      "confidence": 0.98,
      "bbox": {"x": 10.0, "y": 20.0, "width": 100.0, "height": 28.0},
      "quad": {
        "topLeft": {"x": 10.0, "y": 20.0},
        "topRight": {"x": 110.0, "y": 20.0},
        "bottomRight": {"x": 110.0, "y": 48.0},
        "bottomLeft": {"x": 10.0, "y": 48.0}
      }
    }
  ],
  "rows": [
    {
      "text": "line one",
      "bbox": {"x": 10.0, "y": 20.0, "width": 100.0, "height": 28.0},
      "confidence": 0.98,
      "lineIndices": [0]
    }
  ],
  "blocks": [
    {
      "bbox": {"x": 10.0, "y": 20.0, "width": 100.0, "height": 28.0},
      "rowIndices": [0]
    }
  ]
}
```

`width` and `height` are the original pixel size after EXIF orientation, including when `scale=downscale`. `bbox` and `quad` use that same grid (top left). Vision's normalized boxes use a bottom-left origin; the server flips Y, adds the tile origin, and scales back up if the bitmap was smaller than the original. `scale` echoes the request. `mode` is `whole` or `tiled`. `glyphPx` is the median glyph size in original pixels, and `glyphFrac` is that size divided by the long side, both taken from the probe when `scale=auto` ran one. `tileDecision` is the rule that picked `mode`. `tiles` is how many Vision passes contributed the returned lines. `elapsedMs` is decode plus every Vision pass, including an `auto` probe that was discarded, not time spent waiting for another OCR. Nothing is written to a temp file.

Errors use a non-200 status and `{"ok":false,"error":"..."}`: `400` bad input (including a bad `scale` or `maxPixel`), `401` missing or wrong token, `408` timeout, `411` missing `Content-Length`, `413` body cap (`"request body exceeds limit"`), `415` not an image, `500` Vision failure. An image whose oriented pixel count exceeds `OCR_HTTP_MAX_PIXELS` is also `413`, and it is not resized:

```json
{"ok":false,"error":"image too large","maxPixels":100000000,"width":12000,"height":9000}
```

Dimensions are read from the image header before the bitmap is allocated. `503` with `Retry-After: 1` means the wait queue is already full (`"queue full"`) or the caller waited `OCR_HTTP_QUEUE_TIMEOUT_MS` without a free worker (`"queue wait timed out"`). `/v1/*` uses the same 503 and `Retry-After`, with an OpenAI error object instead of `{"ok":false}`. A request that finds a free worker, or a free queue slot, is not rejected. Vision work runs in `OCR_HTTP_VISION_WORKERS` worker processes (default 2), one request at a time each, not an unbounded GCD fan-out. Connection threads are capped at queue size + worker count + 16, shared across all listen addresses, so every queued request has a thread and that thread blocks on a condition instead of spinning. `GET /health` does not enter the OCR queue; the extra 16 slots keep it from waiting out a full queue.

## OpenAI-compatible API

`/health`, `/languages`, `/stats`, and `/ocr` are unchanged. These routes are an extra way to OCR, for apps that only know a custom OpenAI endpoint.

Base URL `http://127.0.0.1:8741/v1` (or `http://192.168.1.50:8741/v1` on the LAN). API key is the bearer token. Model id is `mac-ocr` unless `OCR_HTTP_OPENAI_MODEL` is set. The server does not call OpenAI.

| Method | Path | |
|---|---|---|
| `GET` | `/v1/models` | `{"object":"list","data":[{"id":"mac-ocr","object":"model","created":…,"owned_by":"mac-ocr-http"}]}` |
| `GET` | `/v1/models/{id}` | That object, or 404 when `{id}` is not the configured model. |
| `POST` | `/v1/chat/completions` | OCR, then one `chat.completion`. `stream: true` is SSE. |
| `POST` | `/v1/responses` | Same OCR, Responses API shape (`output_text` and `output[].content[].text`). `stream: true` sends `response.output_text.delta`, then `response.completed`, then `data: [DONE]`. |
| `OPTIONS` | `/v1/*` | CORS preflight, no token, no body. |

**Which images.** Every `image_url` in the last `user` message, in part order. `image_url` may be `{"url":"data:image/png;base64,…","detail":"high"}` or a plain string (some clients send the string). `input_image` is accepted too. When that user message has no image, every image in the conversation is used, including system, developer, and assistant messages. Several images are recognized one after another on the same worker and joined with a blank line.

A request with no image at all is still HTTP 200, streaming or not, with `content` (and Responses `output_text`) set to an empty string. It does not enter the Vision queue. STranslate's Validate button ([`SettingsViewModel.ValidateAsync`](https://github.com/STranslate/STranslate/blob/main/src/Plugins/STranslate.Plugin.Ocr.OpenAI/ViewModel/SettingsViewModel.cs)) posts the enabled prompt as string messages with `stream: true` and no image, then calls `StreamPostAsync` and treats any non-2xx as failure. The callback discards each line, so the content does not have to be non-empty. An `http:`/`https:`/`file:` image, undecodable base64, or a non-image data URL is still HTTP 400.

A 4xx or 5xx on `/v1/*` is one stdout line: `METHOD /v1/... STATUS code`. The code is the error `code` field (`invalid_image_url`, `invalid_base64`, `queue_full`, `request_too_large`, …). The line does not include the body, the token, or the query string.

Text is not a prompt. `temperature`, `top_p`, `n` (the reply is always one choice), `max_tokens`, `max_completion_tokens`, `stop`, penalties, `user`, `tools`, `seed`, `logprobs`, `response_format`, `stream_options` (except `include_usage`), `reasoning_effort`, `thinking`, and unknown fields are ignored. `response_format: json_object` still returns plain text. The only hint that is read is a line `ocr-language: <tag>` or `recognition-language: <tag>` in any text part. The tag must be `zh` / `zh-Hans`, `zh-Hant`, `en` / `en-US`, `ja` / `ja-JP`, or `ko` / `ko-KR`. Anything else is ignored. Recognition then uses the default pipeline: `scale=auto`, accurate, `zh-Hans`+`en-US` unless that hint replaced the list, and `script=hans` when Simplified Chinese is first.

`model` may be any string and is copied into the response. If it is omitted, the configured id is used. `usage.prompt_tokens` is the Unicode scalar count of the text parts (images are not tokenized). `completion_tokens` is the scalar count of the OCR text. `total_tokens` is the sum. These are not BPE tokens. `system_fingerprint` is the constant `fp_macocr`.

`stream: true` runs OCR to completion, then writes SSE. The status line is sent only after OCR succeeds, so a bad request, a full queue, or a Vision error is a normal JSON body with its real status, never HTTP 200. HTTP/1.1 uses `Transfer-Encoding: chunked`. HTTP/1.0 writes the same events and the connection close ends the body. Chat chunks are: `delta.role = assistant`, then one chunk per output line (a blank line is its own chunk), then `finish_reason: stop`. When `stream_options.include_usage` is true, one more chunk has `"choices":[]` and `usage`. The stream ends with `data: [DONE]`.

Queue full and queue timeout stay **503** with `Retry-After: 1` and `"type":"server_error"`. An image over the pixel cap is **413**. A missing or wrong token is **401** `code: invalid_api_key`. The shared body cap is also **413**; on `/v1/*` that body is the OpenAI error object (`code: request_too_large`). `/ocr` still returns `{"ok":false,"error":"request body exceeds limit"}`.

**CORS.** `Access-Control-Allow-Origin: *` is set only on `/v1/*`, together with `GET, POST, OPTIONS` and `Authorization, Content-Type, Accept` (plus any extra preflight header names that are a single token). `Access-Control-Allow-Credentials` is not set. Immersive Translate's own Ollama note (`OLLAMA_ORIGINS=*`) shows that the extension's custom-endpoint fetch is subject to CORS, so a localhost OpenAI URL without these headers fails in the browser. A web page still cannot call the API unless it already has the bearer token: the browser will not attach the token file, and there is no cookie. `/ocr`, `/stats`, and `/languages` send no CORS headers. The header `api-key` (Easydict sends it next to `Authorization`) is ignored; the bearer token is what is checked.

**What those apps actually send**

- Bob's LLM OCR plugin ([`Henry-Jessie/bob-plugin-llm-ocr` `src/main.js`](https://github.com/Henry-Jessie/bob-plugin-llm-ocr/blob/main/src/main.js)) POSTs `{base}{path}` with `Authorization: Bearer`, a system string, and a user content array: a text part plus `image_url.url` set to `data:image/jpeg;base64,…`. It reads `choices[0].message.content` and does not stream. API URL `http://127.0.0.1:8741`, path `/v1/chat/completions`, model `mac-ocr`. The OpenAI *translate* plugin ([`nextai-translator/bob-plugin-openai-translator` `src/adapter/openai.ts`](https://github.com/nextai-translator/bob-plugin-openai-translator/blob/main/src/adapter/openai.ts)) sends text only. That request gets an empty 200, not recognized text. Point Bob's OCR plugin here when you want OCR.
- Easydict's custom OpenAI service ([`BaseOpenAIService.swift`](https://github.com/tisfeng/Easydict/blob/main/Easydict/Swift/Service/OpenAI/BaseOpenAIService.swift)) encodes a MacPaw `ChatQuery`: string `messages`, `model`, `temperature`, `stream`, and both `Authorization: Bearer` and `api-key`. Streaming requires `Content-Type: text/event-stream` and reads `choices[0].delta.content`; a JSON content type makes it fall back to one-shot. `GET` `…/models` expects `data[].id`. Its built-in OCR is the system OCR. A text-only lookup gets an empty completion. Set the endpoint to `http://127.0.0.1:8741/v1/chat/completions`, the key to the token, and the model to `mac-ocr` for a client path that attaches an image.
- Immersive Translate's custom OpenAI field wants the chat URL. Use `http://127.0.0.1:8741/v1/chat/completions`, or a base ending in `/v1` on versions that append `/chat/completions` themselves. API key is the token. Model `mac-ocr`. Page translation sends text batches and gets an empty completion; an image request that uses `image_url` data URLs is the one this server answers. Their docs for a local model tell you to open CORS (`OLLAMA_ORIGINS=*`), which is why `/v1/*` answers preflight.
- STranslate's OpenAI OCR plugin ([`Main.RecognizeAsync`](https://github.com/STranslate/STranslate/blob/main/src/Plugins/STranslate.Plugin.Ocr.OpenAI/Main.cs)) does not stream. Earlier prompt items are `{role, content}` strings. The last user message is a content array: a text part, then `image_url.url` set to `data:image/jpeg;base64,…` (low quality) or `data:image/png;base64,…` (medium). High quality is rejected in the plugin before the request. It reads `choices[0].message.content` and splits on newlines. `UrlHelper.BuildFinalUrl` turns a base of `http://127.0.0.1:8741/` or `http://127.0.0.1:8741/v1` into `http://127.0.0.1:8741/v1/chat/completions`. Validate is the text-only stream described above. Model `mac-ocr`, API key the token, temperature is ignored.

```bash
TOKEN="$(cat "${HOME}/Library/Application Support/MacOcrHttp/token")"
B64="$(base64 < page.png | tr -d '\n')"

curl -sS -H "Authorization: Bearer ${TOKEN}" http://127.0.0.1:8741/v1/models

curl -sS -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"mac-ocr\",\"messages\":[{\"role\":\"system\",\"content\":\"You are an OCR engine.\"},{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Read this.\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,${B64}\",\"detail\":\"high\"}}]}]}" \
  http://127.0.0.1:8741/v1/chat/completions

curl -N -sS -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"mac-ocr\",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":\"data:image/png;base64,${B64}\"}]}]}" \
  http://127.0.0.1:8741/v1/chat/completions
```

`scripts/openai_client_test.py` does the same calls through the official Python SDK (`pip install openai`): one image, two images, mixed text, extra parameters, and a stream. It generates its own PNGs. It does not read a photo from disk unless you pass `--image`.

```bash
pip install openai
OCR_HTTP_TOKEN="$(cat "${HOME}/Library/Application Support/MacOcrHttp/token")" \
  python3 scripts/openai_client_test.py
```

## Worker processes

The HTTP process only parses, authenticates and queues. Image decoding and Vision run in `OCR_HTTP_VISION_WORKERS` resident child processes: the same binary started as `mac-ocr-http --ocr-worker --parent-pid <pid> --slot <n>`. They show up in `ps` under the server. Each admission slot owns one worker. The request goes down a pipe as a JSON header plus the raw image bytes; the result comes back as JSON on a second pipe. The token is removed from the worker environment, and the worker inherits no sockets.

Why: a long-lived process can get into a state where every Vision call fails until it restarts. On 2026-10-20 a server that had been up for a day, across several sleep/wake cycles, answered every `/ocr` with `500 vision recognition failed: TextRecognition.CRImageReaderError error 1` (system log: `E5RT ... precompiled_compute_operation ... (Code: 13)`), while a fresh process recognised the same images. Now that only costs one worker.

When a worker returns a Vision error, crashes, closes its pipe, or misses `OCR_HTTP_WORKER_TIMEOUT_MS`, the server SIGKILLs it, reaps it, starts a fresh worker, and retries the request once there. The client sees one normal response. Only if the retry fails too does it get the usual error (`500`, never `200`). Bad input (`400`, `413`, `415`) is not retried. Workers are also replaced after `OCR_HTTP_WORKER_MAX_TASKS` requests, and an idle worker older than `OCR_HTTP_WORKER_MAX_AGE_S`, so the first request after a long sleep usually lands on a fresh process. A new worker warms the recognizer up on a small drawn image before it takes work.

No zombies, no orphans:

- every exited worker is reaped with `waitpid` exactly once, from a kqueue process-exit watch, a 5-second sweep, or the request thread that killed it;
- a worker exits by itself the moment the server dies, even mid-recognition (kqueue `NOTE_EXIT` on the parent pid), and on EOF of its request pipe;
- on `SIGTERM`/`SIGINT` (including `launchctl kickstart -k` and `bootout`) the server closes its listeners, sends `SIGTERM` to the workers, waits up to 3 s, `SIGKILL`s any left, reaps them all, then exits.

Server log lines start with `worker[<slot>] pid=<pid>` (`spawned`, `failed on attempt 1 (...); killed and reaped (...); retrying on a fresh worker`, `recycled`, `exited while idle`).

For tests only, `OCR_HTTP_WORKER_FAULT` makes workers fail on purpose: `crash:N` (abort), `exit:N`, `hang:N`, `hangterm:N` (hang and ignore `SIGTERM`), or `vision:N` (return `CRImageReaderError`), on every Nth task of each worker. `N=1` fails the retry too. The server logs a warning when it is set. Never set it in the LaunchAgent.

## Debug capture

Off by default. Set `OCR_HTTP_DEBUG_CAPTURE_DIR` to a directory and the server stores every OCR request from `POST /ocr`, `POST /v1/chat/completions`, and `POST /v1/responses` there. This is a debugging aid: it writes the user's images to disk.

Each request gets a numbered directory with the decoded image bytes (`image-0.png`, `image-0.jpg`, …) and a `meta.json` sidecar: timestamp, endpoint, client IP, status, error code, elapsedMs, mode, tiles, glyphFrac, the returned text and rows, and for `/v1` a summary of the messages (role, text parts, image count). The directory is mode `0700` and the files are mode `0600`. `OCR_HTTP_DEBUG_CAPTURE_MAX` (default 50) is a ring buffer; older directories are deleted.

The sidecar keeps the text prompt. It does not keep the `Authorization` header, the token, query keys, or the raw base64. A text-only Validate request is stored too, with empty text and no image file. Writes run on a background queue. A disk error is logged as `debug capture failed` and the OCR response is unchanged.

`scripts/install.sh` copies the two variables into the LaunchAgent plist. Leave the directory unset to keep capture off.

## curl

```bash
PORT=8741
TOKEN="$(cat "${HOME}/Library/Application Support/MacOcrHttp/token")"
BASE="http://127.0.0.1:${PORT}"

curl -sS "${BASE}/health"

curl -sS -H "Authorization: Bearer ${TOKEN}" "${BASE}/languages"

curl -sS -H "Authorization: Bearer ${TOKEN}" "${BASE}/stats"

curl -sS -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: image/png" \
  --data-binary @page.png \
  "${BASE}/ocr?level=accurate&languages=zh-Hans,en-US"

B64="$(base64 < page.png | tr -d '\n')"
curl -sS -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"image\":\"${B64}\",\"level\":\"accurate\",\"languages\":[\"zh-Hans\",\"en-US\"]}" \
  "${BASE}/ocr"
```

`fixtures/tiny.png` is 1×1. Vision rejects it, so `POST /ocr` of that file returns **500**. `./scripts/smoke.sh` still checks `/health` and a missing-token **401**. A real OCR check needs a larger image. Do not combine `level=fast` with `zh-Hans` or `zh-Hant`; the fast recognizer does not support them. Use `accurate` for Chinese, or omit those languages on `fast`.

```bash
./scripts/smoke.sh
```

Row grouping and dedupe are pure functions in `Sources/LineMergeCore`. Command Line Tools do not ship XCTest, so the check is an executable target rather than `swift test`:

```bash
swift run mac-ocr-line-merge-tests
```

## Memory

Each decode and each tile `perform` runs inside `autoreleasepool`. ImageIO is asked not to cache decoded buffers (`kCGImageSourceShouldCache` is false; `ShouldCacheImmediately` is not set). The bitmap is copied into a private buffer and the image source is dropped before recognition. Each tile crop is its own copy and is released before the next tile. A base64 JSON body is decoded once; that JSON text is released before the worker runs. The HTTP process keeps the compressed bytes until the worker answers, so it can retry on a fresh worker; the worker releases its copy after the bitmap copy, before `perform`. The only cache kept across requests is the supported-language lists. `rssBytes` on `GET /stats` is the number to watch: after a load it should sit on a plateau, not climb with request count. The tile path stays at the original resolution. `scale=auto` may draw an extra probe bitmap whose long side is at most 4096; that copy is released before tiling. The safety cap is `OCR_HTTP_MAX_PIXELS` (default 100000000, about 400MB of RGBA). Vision models stay in the OS and are not downloaded by this server.

## Large fixture

`scripts/gen-large-fixture.swift` draws a 7000×5000 PNG of 16px mixed Chinese and English, one known string per row, and writes that list beside it. The PNG is gitignored.

```bash
swift scripts/gen-large-fixture.swift
swift scripts/gen-large-fixture.swift -o /tmp/large-ocr.png --width 7000 --height 5000
```

The default files are `fixtures/large-ocr.png` and `fixtures/large-ocr.txt`. Each `.txt` line is the full row (`L001` … `E001`). Score a running server with `scripts/eval_large.py` (Mac only; it uses `launchctl`). Character recall is an exact LCS on whitespace-stripped text. `charRecall` uses `rows[].text`. `charRecallBbox` joins `lines[]` from bbox centers. `rowsPerGtRow` is the response row count divided by the GT row count. The script also records `languages`, `revision`, `script`, `layout`, and the `blocks` count when the response has them. L/E hits and duplicate counts use `rows[].text`. `text` is the same lines. Do not commit the PNG or the `scripts/results-*.json` the script writes. Compact `{text,x,y,w,h}` captures of the generated large-fixture `lines[]` live in `Sources/LineMergeTestRunner/Fixtures/` (`page-7000.json`, `page-8400.json`) and are what `swift run mac-ocr-line-merge-tests` rebuilds. The large-fixture check is rows/GT ≤ 1.03. Column order, seam folding, and the half-line center rule are covered by synthetic coordinates in that same runner.

```bash
python3 scripts/eval_large.py --runs 1 --modes none fixtures/large-ocr.png
```
