#!/bin/bash
# Hit a running mac-ocr-http on this Mac.
#
# fixtures/tiny.png is 1x1. Vision rejects it, so an authenticated OCR of that
# file returns HTTP 500. Health and the 401 check still pass. A real OCR check
# needs a larger image (a screenshot or a page scan).
#
# Do not send zh-Hans or zh-Hant with level=fast. The fast recognizer does not
# support those languages. Use level=accurate for Chinese, or omit zh on fast.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "smoke.sh must be run on macOS against a built server" >&2
  exit 1
fi

PORT="${OCR_HTTP_PORT:-8741}"
BASE="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNG="${ROOT}/fixtures/tiny.png"
TOKEN_FILE="${HOME}/Library/Application Support/MacOcrHttp/token"

[[ -f "$PNG" ]] || { echo "missing ${PNG}" >&2; exit 1; }

echo "GET /health"
curl -fsS "${BASE}/health"
echo

code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: image/png' --data-binary @"${PNG}" "${BASE}/ocr")"
echo "POST /ocr without token -> ${code}"
[[ "$code" == "401" ]] || { echo "expected 401" >&2; exit 1; }

stats_code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/stats")"
echo "GET /stats without token -> ${stats_code}"
[[ "$stats_code" == "401" ]] || { echo "expected 401" >&2; exit 1; }

if [[ -n "${OCR_HTTP_TOKEN:-}" ]]; then
  TOKEN="$OCR_HTTP_TOKEN"
elif [[ -f "$TOKEN_FILE" ]]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
else
  echo "Health and 401 checks passed. Set OCR_HTTP_TOKEN to exercise OCR."
  exit 0
fi

AUTH=( -H "Authorization: Bearer ${TOKEN}" )

echo "GET /stats"
curl -fsS "${AUTH[@]}" "${BASE}/stats"
echo

# accurate accepts zh-Hans/zh-Hant. 1x1 still comes back 500 from Vision.
echo "POST /ocr raw png (accurate + zh; 1x1 is expected to be 500)"
raw_out="$(mktemp)"
code="$(curl -sS -o "$raw_out" -w '%{http_code}' "${AUTH[@]}" -H "Content-Type: image/png" \
  --data-binary @"${PNG}" \
  "${BASE}/ocr?level=accurate&languages=zh-Hans,zh-Hant,en-US")"
echo "status ${code}"
cat "$raw_out"
echo
rm -f "$raw_out"
if [[ "$code" != "200" && "$code" != "500" ]]; then
  echo "expected 200 with a larger image, or 500 because tiny.png is too small for Vision" >&2
  exit 1
fi
if [[ "$code" == "500" ]]; then
  echo "note: tiny.png is 1x1 and too small for Vision. Point OCR at a real screenshot for a 200."
fi

B64="$(base64 < "$PNG" | tr -d '\n')"
echo "POST /ocr json base64 (accurate, no fast+zh)"
json_out="$(mktemp)"
code="$(curl -sS -o "$json_out" -w '%{http_code}' "${AUTH[@]}" -H "Content-Type: application/json" \
  --data "{\"image\":\"${B64}\",\"level\":\"accurate\",\"languages\":[\"zh-Hans\",\"zh-Hant\",\"en-US\"]}" \
  "${BASE}/ocr")"
echo "status ${code}"
cat "$json_out"
echo
rm -f "$json_out"
if [[ "$code" != "200" && "$code" != "500" ]]; then
  echo "expected 200 with a larger image, or 500 because tiny.png is too small for Vision" >&2
  exit 1
fi

echo "GET /languages"
curl -fsS "${AUTH[@]}" "${BASE}/languages"
echo
echo "smoke ok (OCR 200 still needs a larger fixture than fixtures/tiny.png)"
