#!/usr/bin/env bash
# Re-copies the wire-contract fixtures from dropp-attribution. Run after the server's `npm run fixtures`
# output changes, then commit contract/ together with any SDK changes it needs.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
server="${1:-$here/../dropp-attribution-server}"
src="$server/test/fixtures/contracts"
[ -d "$src" ] || { echo "No fixtures at $src (pass the server repo path as the first argument)"; exit 1; }
rm -rf "$here/contract"
mkdir -p "$here/contract"
cp -R "$src/." "$here/contract/"
echo "Synced contract/ from $src"
