#!/usr/bin/env python3
"""Large-image OCR comparison for mac-ocr-http (scale=downscale|none|tile).

usage: eval_large.py [--runs 3] [--no-restart] [--modes downscale,none,tile] IMAGE.png [IMAGE.png ...]
Each IMAGE needs a sidecar IMAGE.txt (one GT row per line, "Lnnn ... Ennn").
Token is read from the token file and never printed. Results -> JSON on stdout + results-*.json.

Character recall is an exact LCS on whitespace-stripped text (difflib's
SequenceMatcher mis-aligns this repeated filler). charRecall scores rows[].text.
charRecallBbox always joins lines[] on the client from bbox centers. The
baf496c Mac figures 93.2% (7000×5000) and 91.3% (8400×6000) are charRecallBbox,
not charRecallText. rowsPerGtRow is len(rows) / len(GT). The response also
echoes languages, revision, script (hans|auto), layout (rows|document), and blocks.
"""
import json, os, re, subprocess, sys, threading, time, urllib.request, urllib.error

HOST = os.environ.get("OCR_EVAL_HOST", "127.0.0.1")
PORT = int(os.environ.get("OCR_HTTP_PORT", "8741"))
BASE = f"http://{HOST}:{PORT}"
LABEL = os.environ.get("OCR_HTTP_LABEL", "com.example.mac-ocr-http")
TOKEN_FILE = os.path.expanduser("~/Library/Application Support/MacOcrHttp/token")
LANGS = "zh-Hans,en-US"
WS = re.compile(r"\s+")


def token():
    with open(TOKEN_FILE) as f:
        return f.read().strip()


def http(method, path, body=None, ctype=None, auth=True, timeout=300):
    req = urllib.request.Request(BASE + path, data=body, method=method)
    if auth:
        req.add_header("Authorization", "Bearer " + token())
    if ctype:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def service_pid():
    out = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True, text=True).stdout
    m = re.search(r"\bpid = (\d+)", out)
    return int(m.group(1)) if m else None


def restart():
    subprocess.run(["launchctl", "kickstart", "-k", f"gui/{os.getuid()}/{LABEL}"], check=True, capture_output=True)
    for _ in range(100):
        time.sleep(0.2)
        try:
            if http("GET", "/health", auth=False, timeout=2)[0] == 200:
                break
        except Exception:
            pass
    time.sleep(0.5)


class Poller:
    """Polls /stats rssBytes and ps RSS every 100ms; keeps the max."""
    def __init__(self, pid):
        self.pid, self.stop_ev = pid, threading.Event()
        self.max_stats, self.max_ps_kb, self.samples = 0, 0, 0
        self.threads = [threading.Thread(target=self._stats, daemon=True), threading.Thread(target=self._ps, daemon=True)]

    def _stats(self):
        while not self.stop_ev.is_set():
            try:
                s, b = http("GET", "/stats", timeout=2)
                if s == 200:
                    self.max_stats = max(self.max_stats, int(json.loads(b).get("rssBytes", 0)))
                    self.samples += 1
            except Exception:
                pass
            self.stop_ev.wait(0.1)

    def _ps(self):
        while not self.stop_ev.is_set():
            try:
                out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.pid)], capture_output=True, text=True).stdout.strip()
                if out:
                    self.max_ps_kb = max(self.max_ps_kb, int(out))
            except Exception:
                pass
            self.stop_ev.wait(0.1)

    def __enter__(self):
        for t in self.threads: t.start()
        return self

    def __exit__(self, *a):
        self.stop_ev.set()
        for t in self.threads: t.join()


def load_gt(png):
    gt = []
    with open(os.path.splitext(png)[0] + ".txt", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            m = re.match(r"\s*L(\d+)\b.*\bE(\d+)\s*$", line)
            if m:
                gt.append((m.group(1), line))
    return gt


def lcs_length(left, right):
    """Exact longest common subsequence length. O(len(left) * len(right))."""
    if not left or not right:
        return 0
    if len(right) > len(left):
        left, right = right, left
    previous = [0] * (len(right) + 1)
    for char in left:
        current = [0]
        running = 0
        for index, other in enumerate(right):
            up = previous[index + 1]
            if char == other:
                running = previous[index] + 1
            elif running < up:
                running = up
            current.append(running)
        previous = current
    return previous[-1]


def char_recall(gt, out_lines):
    """GT line -> best output line (exact LCS, whitespace removed). Candidates: output lines carrying the
    row's L/E marker, else lines between the neighbouring matched rows (max 12), else none."""
    outs = [WS.sub("", l) for l in out_lines]
    marker_idx = {}
    for num, _ in gt:
        marker_idx[num] = [i for i, l in enumerate(outs) if f"L{num}" in l or f"E{num}" in l]
    total = matched = 0
    nums = [n for n, _ in gt]
    for k, (num, line) in enumerate(gt):
        g = WS.sub("", line)
        total += len(g)
        cand = marker_idx[num]
        if not cand:
            lo = max([max(marker_idx[n]) for n in nums[:k] if marker_idx[n]] or [-1])
            hi = min([min(marker_idx[n]) for n in nums[k + 1:] if marker_idx[n]] or [len(outs)])
            cand = list(range(lo + 1, hi))[:12]
        best = 0
        for i in cand:
            best = max(best, lcs_length(g, outs[i]))
        matched += best
    return matched / total if total else 0.0


def bbox_rows(lines):
    """Supplementary: join `lines` fragments whose bbox vertical centres are within half a line height
    into one row (left to right). Lets char recall see a GT row that came back as several fragments."""
    items = sorted(((l["bbox"]["y"] + l["bbox"]["height"] / 2, l["bbox"]["height"], l["bbox"]["x"], l["text"]) for l in lines))
    rows, cur, cy, ch = [], [], None, None
    for yc, h, x, t in items:
        if cur and abs(yc - cy) <= 0.5 * max(ch, h):
            cur.append((x, t)); continue
        if cur: rows.append(" ".join(t for _, t in sorted(cur)))
        cur, cy, ch = [(x, t)], yc, h
    if cur: rows.append(" ".join(t for _, t in sorted(cur)))
    return rows


def row_texts(rows):
    out = []
    for row in rows or []:
        if isinstance(row, dict):
            text = row.get("text") or ""
            if str(text).strip():
                out.append(str(text))
    return out


def nonempty_lines(text):
    return [line for line in (text or "").split("\n") if line.strip()]


def score(gt, text, lines, rows=None):
    """Primary recall is rows[].text. Fall back to a client bbox join, then raw text."""
    primary = row_texts(rows)
    source = "rows"
    if not primary:
        joined = bbox_rows(lines) if lines else []
        if joined:
            primary = joined
            source = "bbox"
        else:
            primary = nonempty_lines(text)
            source = "text"
    blob = "\n".join(primary)
    le = sum(1 for num, _ in gt if f"L{num}" in blob and f"E{num}" in blob)
    dup = sum(1 for num, _ in gt if max(blob.count(f"L{num}"), blob.count(f"E{num}")) >= 2)
    return {
        "source": source,
        "le": le,
        "dup": dup,
        "charRecall": char_recall(gt, primary),
        "charRecallText": char_recall(gt, nonempty_lines(text)),
        "charRecallBbox": char_recall(gt, bbox_rows(lines)) if lines else 0.0,
        "primaryLines": len(primary),
    }


def run_one(png, mode, gt):
    body = open(png, "rb").read()
    pid = service_pid()
    q = f"/ocr?level=accurate&scale={mode}&languages={LANGS}"
    with Poller(pid) as p:
        t0 = time.time()
        status, raw = http("POST", q, body=body, ctype="image/png")
        wall = (time.time() - t0) * 1000
        time.sleep(0.15)
    rec = {"image": os.path.basename(png), "mode": mode, "status": status, "wallMs": round(wall),
           "peakRssBytes": p.max_stats, "peakPsRssBytes": p.max_ps_kb * 1024, "statsSamples": p.samples, "pid": pid}
    try:
        d = json.loads(raw)
    except Exception:
        rec["error"] = raw[:200].decode("utf-8", "replace")
        return rec
    if status != 200:
        rec["error"] = d
        return rec
    if os.environ.get("OCR_EVAL_SAVE"):
        os.makedirs(os.environ["OCR_EVAL_SAVE"], exist_ok=True)
        with open(os.path.join(os.environ["OCR_EVAL_SAVE"], f"{os.path.basename(png)}-{mode}-{time.strftime('%H%M%S')}.json"), "wb") as f:
            f.write(raw)
    rows = d.get("rows") or []
    lines = d.get("lines") or []
    scored = score(gt, d.get("text", ""), lines, rows)
    rec.update(elapsedMs=d.get("elapsedMs"), tiles=d.get("tiles"), scale=d.get("scale"),
               mode=d.get("mode"), glyphPx=d.get("glyphPx"), glyphFrac=d.get("glyphFrac"),
               tileDecision=d.get("tileDecision"),
               lines=len(lines), rows=len(rows), textLines=len(nonempty_lines(d.get("text", ""))),
               textRows=scored["primaryLines"], gtLines=len(gt), recallSource=scored["source"],
               leRecall=round(scored["le"] / len(gt), 4) if gt else 0.0, leHits=scored["le"],
               charRecall=round(scored["charRecall"], 4), charRecallText=round(scored["charRecallText"], 4),
               charRecallBbox=round(scored["charRecallBbox"], 4), dupGtLines=scored["dup"],
               rowsPerGtRow=round(len(rows) / len(gt), 4) if gt else 0.0,
               languages=d.get("languages"), revision=d.get("revision"), script=d.get("script"),
               layout=d.get("layout"), blocks=len(d.get("blocks") or []))
    return rec


def main():
    args = sys.argv[1:]
    runs, restart_between, modes = 3, True, ["downscale", "none", "tile"]
    imgs = []
    while args:
        a = args.pop(0)
        if a == "--runs": runs = int(args.pop(0))
        elif a == "--no-restart": restart_between = False
        elif a == "--modes": modes = args.pop(0).split(",")
        else: imgs.append(a)
    results = []
    for png in imgs:
        gt = load_gt(png)
        for mode in modes:
            if restart_between:
                restart()
            for r in range(runs):
                rec = run_one(png, mode, gt)
                rec["run"] = r + 1
                rec["at"] = time.strftime("%H:%M:%S")
                results.append(rec)
                print(json.dumps(rec, ensure_ascii=False), flush=True)
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"results-{time.strftime('%Y%m%d-%H%M%S')}.json")
    with open(out, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=1)
    print("saved", out, flush=True)


if __name__ == "__main__":
    main()
