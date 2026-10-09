#!/bin/sh
# Renders og/og.html into public/og.png (1200×630) with headless Chrome.
# Set CHROME to override the browser binary.
set -eu

cd "$(dirname "$0")/.."
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$chrome" ]; then
  echo "generate.sh: Chrome not found at $chrome; set CHROME" >&2
  exit 1
fi

work="$(mktemp -d)"
shot="$work/og.png"
pid=""
cleanup() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

# Headless Chrome on macOS can stay alive after writing the screenshot, so
# start it in the background and stop it once the file is complete.
"$chrome" \
  --headless=new \
  --user-data-dir="$work/profile" \
  --no-first-run \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor=1 \
  --window-size=1200,630 \
  --screenshot="$shot" \
  "file://$PWD/og/og.html" >/dev/null 2>&1 &
pid=$!

tries=0
while ! { [ -s "$shot" ] && sips -g pixelWidth "$shot" >/dev/null 2>&1; }; do
  tries=$((tries + 1))
  if [ "$tries" -gt 60 ]; then
    echo "generate.sh: Chrome did not write a screenshot within 30 s" >&2
    exit 1
  fi
  sleep 0.5
done
sleep 0.5

mv "$shot" public/og.png
echo "wrote public/og.png"
