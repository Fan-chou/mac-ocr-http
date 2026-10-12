#!/bin/bash
# Build mac-ocr-http, install it for the current user, and bootstrap a LaunchAgent.
# The agent listens on OCR_HTTP_HOST (default 127.0.0.1; loopback/RFC1918 IPv4 only).
# No token is printed.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "install.sh must be run on macOS" >&2
  exit 1
fi

LABEL="${OCR_HTTP_LABEL:-com.example.mac-ocr-http}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SUPPORT="${HOME}/Library/Application Support/MacOcrHttp"
LOG_DIR="${HOME}/Library/Logs/MacOcrHttp"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
PLIST_DST="${LAUNCH_AGENTS}/${LABEL}.plist"
TOKEN_FILE="${APP_SUPPORT}/token"
BIN_DST="${APP_SUPPORT}/mac-ocr-http"
TEMPLATE="${ROOT}/install/com.example.mac-ocr-http.plist"
PORT="${OCR_HTTP_PORT:-8741}"
OPENAI_MODEL="${OCR_HTTP_OPENAI_MODEL:-mac-ocr}"
if ! [[ "$OPENAI_MODEL" =~ ^[A-Za-z0-9._:/-]{1,128}$ ]]; then
  echo "OCR_HTTP_OPENAI_MODEL must be 1...128 characters from [A-Za-z0-9._:/-]" >&2
  exit 1
fi
DEBUG_CAPTURE_DIR="${OCR_HTTP_DEBUG_CAPTURE_DIR:-}"
if [[ "$DEBUG_CAPTURE_DIR" == *$'\n'* || "$DEBUG_CAPTURE_DIR" == *"__"* ]]; then
  echo "OCR_HTTP_DEBUG_CAPTURE_DIR must not contain newlines or __" >&2
  exit 1
fi
HOSTS_RAW="${OCR_HTTP_HOST:-127.0.0.1}"
if ! [[ "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,200}$ ]]; then
  echo "OCR_HTTP_LABEL must be a launchd label such as com.example.mac-ocr-http" >&2
  exit 1
fi
DOMAIN="gui/$(id -u)"

# Match Config.swift: out-of-range integers are clamped, non-integers are refused.
take_int() {
  local name=$1 raw=$2 min=$3 max=$4
  if ! [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "${name} must be an integer (${min}...${max})" >&2
    exit 1
  fi
  if (( ${#raw} > 9 )); then
    echo "${name} clamped to ${max}" >&2
    printf '%s' "$max"
    return
  fi
  local value=$((10#$raw))
  if (( value < min )); then
    echo "${name}=${raw} clamped to ${min}" >&2
    value=$min
  elif (( value > max )); then
    echo "${name}=${raw} clamped to ${max}" >&2
    value=$max
  fi
  printf '%s' "$value"
}

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
  echo "OCR_HTTP_PORT must be 1...65535" >&2
  exit 1
fi

# Same rules as Config.swift validateListenHost: IPv4 literals in 127/8, 10/8,
# 172.16/12, 192.168/16 only. 0.0.0.0, wildcards and public addresses are refused.
check_host() {
  local h=$1 a b c d
  if ! [[ "$h" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    echo "OCR_HTTP_HOST entry '${h}' is not an IPv4 literal" >&2; exit 1
  fi
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]})); c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
  if (( a > 255 || b > 255 || c > 255 || d > 255 )); then
    echo "OCR_HTTP_HOST entry '${h}' is not an IPv4 literal" >&2; exit 1
  fi
  if (( a == 127 || a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) )); then
    printf '%s.%s.%s.%s' "$a" "$b" "$c" "$d"; return
  fi
  echo "refusing OCR_HTTP_HOST entry '${h}': only 127.0.0.0/8, 10/8, 172.16/12, 192.168/16 (never 0.0.0.0)" >&2
  exit 1
}
HOSTS=""
IFS=',' read -r -a HOST_LIST <<< "$HOSTS_RAW"
for raw_host in "${HOST_LIST[@]}"; do
  raw_host="${raw_host//[[:space:]]/}"
  host="$(check_host "$raw_host")"
  [[ ",${HOSTS}," == *",${host},"* ]] || HOSTS="${HOSTS:+${HOSTS},}${host}"
done
[[ -n "$HOSTS" ]] || { echo "OCR_HTTP_HOST is empty" >&2; exit 1; }
if [[ ",${HOSTS}," != *",127.0.0.1,"* ]]; then
  echo "warning: OCR_HTTP_HOST does not include 127.0.0.1; local callers on 127.0.0.1 will not connect" >&2
fi

VISION_WORKERS="$(take_int OCR_HTTP_VISION_WORKERS "${OCR_HTTP_VISION_WORKERS:-2}" 1 4)"
QUEUE_MAX="$(take_int OCR_HTTP_QUEUE_MAX "${OCR_HTTP_QUEUE_MAX:-64}" 1 256)"
QUEUE_TIMEOUT_MS="$(take_int OCR_HTTP_QUEUE_TIMEOUT_MS "${OCR_HTTP_QUEUE_TIMEOUT_MS:-180000}" 1 300000)"
DEBUG_CAPTURE_MAX="$(take_int OCR_HTTP_DEBUG_CAPTURE_MAX "${OCR_HTTP_DEBUG_CAPTURE_MAX:-50}" 1 10000)"

command -v swift >/dev/null || { echo "swift not found; install Xcode or the Command Line Tools" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "missing plist template: $TEMPLATE" >&2; exit 1; }

echo "Stopping a previous ${LABEL} if it is loaded"
launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true

echo "Building release binary"
swift build -c release --build-system native --package-path "$ROOT"
BUILT="${ROOT}/.build/release/mac-ocr-http"
[[ -x "$BUILT" ]] || { echo "build did not produce ${BUILT}" >&2; exit 1; }

mkdir -p "$APP_SUPPORT" "$LOG_DIR" "$LAUNCH_AGENTS"
chmod 700 "$APP_SUPPORT"
cp -f "$BUILT" "$BIN_DST"
chmod 755 "$BIN_DST"

if [[ -n "${OCR_HTTP_TOKEN:-}" ]]; then
  TOKEN="${OCR_HTTP_TOKEN}"
elif [[ -f "$TOKEN_FILE" ]]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  echo "Reusing ${TOKEN_FILE}"
else
  TOKEN="$(openssl rand -hex 32)"
  echo "Generated a new token in ${TOKEN_FILE}"
fi

if [[ "${#TOKEN}" -lt 16 || "$TOKEN" == *" "* || "$TOKEN" == *$'\n'* ]]; then
  echo "token must be at least 16 characters with no whitespace" >&2
  exit 1
fi

umask 077
printf '%s\n' "$TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

xml_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

BIN_ESC="$(xml_escape "$BIN_DST")"
WORK_ESC="$(xml_escape "$APP_SUPPORT")"
TOKEN_ESC="$(xml_escape "$TOKEN")"
PORT_ESC="$(xml_escape "$PORT")"
HOST_ESC="$(xml_escape "$HOSTS")"
WORKERS_ESC="$(xml_escape "$VISION_WORKERS")"
QUEUE_ESC="$(xml_escape "$QUEUE_MAX")"
TIMEOUT_ESC="$(xml_escape "$QUEUE_TIMEOUT_MS")"
MODEL_ESC="$(xml_escape "$OPENAI_MODEL")"
DEBUG_DIR_ESC="$(xml_escape "$DEBUG_CAPTURE_DIR")"
DEBUG_MAX_ESC="$(xml_escape "$DEBUG_CAPTURE_MAX")"
OUT_ESC="$(xml_escape "${LOG_DIR}/stdout.log")"
ERR_ESC="$(xml_escape "${LOG_DIR}/stderr.log")"

text="$(<"$TEMPLATE")"
text="${text//__BINARY__/${BIN_ESC}}"
text="${text//__WORKDIR__/${WORK_ESC}}"
text="${text//__PORT__/${PORT_ESC}}"
text="${text//__HOST__/${HOST_ESC}}"
text="${text//__VISION_WORKERS__/${WORKERS_ESC}}"
text="${text//__QUEUE_MAX__/${QUEUE_ESC}}"
text="${text//__QUEUE_TIMEOUT_MS__/${TIMEOUT_ESC}}"
text="${text//__OPENAI_MODEL__/${MODEL_ESC}}"
text="${text//__DEBUG_CAPTURE_DIR__/${DEBUG_DIR_ESC}}"
text="${text//__DEBUG_CAPTURE_MAX__/${DEBUG_MAX_ESC}}"
text="${text//__STDOUT__/${OUT_ESC}}"
text="${text//__STDERR__/${ERR_ESC}}"
text="${text//__LABEL__/${LABEL}}"
text="${text//__TOKEN__/${TOKEN_ESC}}"
umask 077
printf '%s\n' "$text" > "$PLIST_DST"
chmod 600 "$PLIST_DST"

if grep -E -q '__(BINARY|TOKEN|PORT|WORKDIR|STDOUT|STDERR|HOST|LABEL|VISION_WORKERS|QUEUE_MAX|QUEUE_TIMEOUT_MS|OPENAI_MODEL|DEBUG_CAPTURE_DIR|DEBUG_CAPTURE_MAX)__' "$PLIST_DST"; then
  echo "plist still contains placeholders" >&2
  exit 1
fi

echo "Bootstrapping ${PLIST_DST}"
launchctl bootstrap "$DOMAIN" "$PLIST_DST"
launchctl enable "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
launchctl kickstart -k "${DOMAIN}/${LABEL}"

echo
IFS=',' read -r -a BOUND <<< "$HOSTS"
for h in "${BOUND[@]}"; do
  echo "Listening on http://${h}:${PORT}"
done
echo "(use 127.0.0.1, not localhost, locally; an address missing at startup is retried every 30s — see stderr.log)"
echo "Vision workers: ${VISION_WORKERS}; queue: ${QUEUE_MAX}; queue wait: ${QUEUE_TIMEOUT_MS} ms"
echo "Token file (mode 0600, value not printed): ${TOKEN_FILE}"
echo "Logs: ${LOG_DIR}/stdout.log and stderr.log"
echo
echo "curl -sS http://127.0.0.1:${PORT}/health"
echo "curl -sS -H \"Authorization: Bearer \$(cat \"${TOKEN_FILE}\")\" http://127.0.0.1:${PORT}/languages"
