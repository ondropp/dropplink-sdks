#!/usr/bin/env bash
# Builds the web SDK's script-tag file and copies it into dropp-attribution, which serves it as /_d/s.js on
# every link domain (assets/dropplink-web.js). Run on release, then commit the asset in the server repo.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
server="${1:-$here/../dropp-attribution-server}"
[ -d "$server/assets" ] || { echo "No assets/ in $server (pass the server repo path as the first argument)"; exit 1; }
(cd "$here/web" && npm run build)
cp "$here/web/dist/dropplink.min.js" "$server/assets/dropplink-web.js"
echo "Copied web/dist/dropplink.min.js to $server/assets/dropplink-web.js"
