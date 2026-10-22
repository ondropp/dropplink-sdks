#!/usr/bin/env bash
# Builds the web SDK and copies its script-tag bundle into dropp-attribution, which serves it at
# https://<link domain>/_d/s.js. Run after any change under web/src, then commit both repos.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
server="${1:-$here/../dropp-attribution-server}"
[ -d "$server/src" ] || { echo "No server repo at $server (pass its path as the first argument)"; exit 1; }
(cd "$here/web" && npm run build >/dev/null)
mkdir -p "$server/assets"
cp "$here/web/dist/dropplink.js" "$server/assets/dropplink-web.js"
echo "Copied web/dist/dropplink.js to $server/assets/dropplink-web.js"
