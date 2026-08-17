#!/bin/bash
# Generate an image via the ChatGPT web UI using ego-browser (reuses your login;
# no API key, billed only against your ChatGPT subscription quota).
#
# Usage:
#   scripts/generate-image-browser.sh "prompt" [output.png]
#
# Requirements: ego-browser CLI installed and ChatGPT logged in.
# Selectors verified against chatgpt.com as of 2026-08-16 — update if the UI changes.
# NOTE: ego-browser does not forward environment variables to its node runtime,
# so the prompt and output path are passed through a fixed bridge file
# (/tmp/palmier-gen-bridge.txt) — concurrent runs would collide.
set -euo pipefail

PROMPT="${1:?usage: generate-image-browser.sh \"prompt\" [output.png]}"
OUT="${2:-$HOME/Downloads/palmier-gen-$(date +%H%M%S).png}"

BRIDGE=/tmp/palmier-gen-bridge.txt
printf '%s\n%s\n' "$PROMPT" "$OUT" > "$BRIDGE"
trap 'rm -f "$BRIDGE"' EXIT


# GUI-launched callers pass a minimal PATH — resolve ego-browser absolutely.
EGO_BIN="$(command -v ego-browser || true)"
if [ -z "$EGO_BIN" ]; then
  for candidate in "$HOME/.local/bin/ego-browser" /usr/local/bin/ego-browser /opt/homebrew/bin/ego-browser; do
    if [ -x "$candidate" ]; then EGO_BIN="$candidate"; break; fi
  done
fi
if [ -z "$EGO_BIN" ]; then
  echo "ego-browser not found in PATH, ~/.local/bin, /usr/local/bin, or /opt/homebrew/bin" >&2
  exit 1
fi

"$EGO_BIN" nodejs <<'EOF'
const task = await useOrCreateTaskSpace('palmier web generation')
const fs = await import('fs')
const [promptText, outPath] = fs.readFileSync('/tmp/palmier-gen-bridge.txt', 'utf8').split('\n')

await openOrReuseTab('https://chatgpt.com/', { wait: true, timeout: 30 })
await wait(3)
await fillInput('#prompt-textarea', promptText)
await wait(1)
await click('button[data-testid="send-button"]', { label: 'send prompt' })

// Poll for the generated image (large, non-avatar). A fresh chat has none.
let src = null
for (let i = 0; i < 24 && !src; i++) {
  await wait(5)
  src = await js(String.raw`(() => {
    const main = document.querySelector('main') || document.body
    const im = [...main.querySelectorAll('img')].find(x =>
      x.naturalWidth > 256 && x.naturalHeight > 256 &&
      !x.src.includes('avatar') && !x.src.includes('openai-logo'))
    return im ? im.src : null
  })()`)
}
if (!src) { throw new Error('no image appeared within 120s') }

// Fetch inside the page (carries cookies) and base64 there — raw binary
// crossing the CDP boundary loses bytes.
const b64 = await js(String.raw`(async () => {
  const res = await fetch(${JSON.stringify(src)}, { credentials: 'include' })
  const blob = await res.blob()
  return await new Promise(resolve => {
    const fr = new FileReader()
    fr.onload = () => resolve(fr.result.split(',')[1])
    fr.readAsDataURL(blob)
  })
})()`)
const buf = Buffer.from(b64, 'base64')
if (buf.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') {
  throw new Error('downloaded bytes are not a PNG')
}
fs.writeFileSync(outPath, buf)
cliLog('saved ' + outPath + ' (' + buf.length + ' bytes)')
await completeTaskSpace(task.id, { keep: false })
EOF
echo "==> $OUT"
