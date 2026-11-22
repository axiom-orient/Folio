#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
FOLIO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${FOLIO_BUILD_ROOT:-}" && "$FOLIO_BUILD_ROOT" != /* ]]; then printf '%s\n' 'FOLIO_BUILD_ROOT는 외부 절대 경로여야 합니다.' >&2; exit 2; fi
FOLIO_BOOTSTRAP_CACHE="${FOLIO_BUILD_ROOT:-$HOME/Library/Developer/FolioBuilds}/Bootstrap"
exec /usr/bin/xcrun swift run --scratch-path "$FOLIO_BOOTSTRAP_CACHE" --package-path "$FOLIO_ROOT" FolioDeveloper --root "$FOLIO_ROOT" "$@"
