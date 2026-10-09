#!/bin/bash
# Unload the LaunchAgent. Pass --purge to also delete the binary, token, and logs.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "uninstall.sh must be run on macOS" >&2
  exit 1
fi

LABEL="${OCR_HTTP_LABEL:-com.example.mac-ocr-http}"
APP_SUPPORT="${HOME}/Library/Application Support/MacOcrHttp"
LOG_DIR="${HOME}/Library/Logs/MacOcrHttp"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
PURGE=0
if [[ "${1:-}" == "--purge" ]]; then
  PURGE=1
elif [[ -n "${1:-}" ]]; then
  echo "usage: uninstall.sh [--purge]" >&2
  exit 1
fi

launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
if [[ -f "$PLIST_DST" ]]; then
  rm -f "$PLIST_DST"
  echo "Removed ${PLIST_DST}"
else
  echo "No plist at ${PLIST_DST}"
fi

if [[ "$PURGE" -eq 1 ]]; then
  rm -rf "$APP_SUPPORT" "$LOG_DIR"
  echo "Removed ${APP_SUPPORT} and ${LOG_DIR}"
else
  echo "Left the binary and token in ${APP_SUPPORT}"
  echo "Pass --purge to delete them and ${LOG_DIR}"
fi
