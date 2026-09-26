#!/usr/bin/env bash
# Stamp a build version into an assembled site directory:
#   tools/stamp.sh <site-dir> <version>
#
# GitHub Pages caches every file independently, so right after a deploy a
# browser can pair a new index.html with old scripts or an old engine. The
# page's script and stylesheet URLs get ?v=<version>; qweb.js carries the
# same query to qgraph.wasm and to every worker it starts.
set -euo pipefail
SITE="$1"
VER="$2"
[[ "$VER" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad version: $VER" >&2; exit 1; }

sed -i -E \
  -e "s#(src=\"js/[A-Za-z0-9_-]+\.js)\"#\1?v=$VER\"#g" \
  -e "s#(href=\"styles/[A-Za-z0-9_-]+\.css)\"#\1?v=$VER\"#g" \
  "$SITE/index.html"
printf '{"version":"%s"}\n' "$VER" > "$SITE/version.json"

# Fail the deploy rather than ship a half-stamped site.
grep -q "js/qweb.js?v=$VER" "$SITE/index.html"
grep -q "styles/grapheditor.css?v=$VER" "$SITE/index.html"
! grep -qE 'src="js/[A-Za-z0-9_-]+\.js"' "$SITE/index.html"
echo ">> stamped $SITE as version $VER"
