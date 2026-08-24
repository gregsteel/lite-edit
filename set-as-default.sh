#!/bin/bash
# Install LiteEdit to /Applications (does not change default handlers).
# To set defaults for common text/config types, use:
#   LiteEdit → Register as Default for Common Types…
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="${ROOT}/LiteEdit.app"
APP_DST="/Applications/LiteEdit.app"

if [[ ! -d "${APP_SRC}" ]]; then
  echo "▸ Building LiteEdit.app first…"
  bash "${ROOT}/build.sh"
fi

echo "▸ Installing to ${APP_DST}…"
rm -rf "${APP_DST}"
cp -R "${APP_SRC}" "${APP_DST}"
xattr -rd com.apple.quarantine "${APP_DST}" 2>/dev/null || true

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"${LSREG}" -f "${APP_DST}"

echo ""
echo "✓ Installed to ${APP_DST}"
echo "  In LiteEdit: LiteEdit → Register as Default for Common Types…"
