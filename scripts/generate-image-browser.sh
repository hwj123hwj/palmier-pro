#!/bin/bash
# Generate an image via the ChatGPT web UI using ego-browser (reuses your login;
# no API key, billed only against your ChatGPT subscription quota).
#
# Usage:
#   scripts/generate-image-browser.sh "prompt" [output.png] [--reference-image path]...
#
# Reference images are attached to the prompt before sending, so the model
# edits / stays consistent with them.
#
# Requirements: ego-browser CLI installed and ChatGPT logged in.
# Selectors verified against chatgpt.com as of 2026-08-16 — update if the UI changes.
# NOTE: ego-browser does not forward environment variables to its node runtime,
# so parameters travel through a fixed bridge file (/tmp/palmier-gen-bridge.txt)
# — concurrent runs would collide. All values are base64 (prompts may contain
# newlines).
set -euo pipefail

REFS=()
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reference-image)
      if [ $# -lt 2 ] || [ ! -f "$2" ]; then
        echo "reference image not found: ${2:-<missing>}" >&2; exit 1
      fi
      REFS+=("$2"); shift 2 ;;
    --reference-image=*)
      p="${1#*=}"
      if [ ! -f "$p" ]; then echo "reference image not found: $p" >&2; exit 1; fi
      REFS+=("$p"); shift ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
PROMPT="${POSITIONAL[0]:?usage: generate-image-browser.sh \"prompt\" [output.png] [--reference-image path]...}"
# The web UI only invokes its image tool for explicit image intent.
if printf '%s' "$PROMPT" | grep -qiE '^(生成|画)|图片|image|generate|create|draw|illustrat|参考|based on|edit|style'; then
  EFFECTIVE_PROMPT="$PROMPT"
else
  EFFECTIVE_PROMPT="生成一张图片：$PROMPT"
fi
OUT="${POSITIONAL[1]:-$HOME/Downloads/palmier-gen-$(date +%H%M%S).png}"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; printf '\n'; }
BRIDGE=/tmp/palmier-gen-bridge.txt
{
  b64 "$EFFECTIVE_PROMPT"
  b64 "$OUT"
  for r in ${REFS[@]+"${REFS[@]}"}; do b64 "$r"; done
} > "$BRIDGE"
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
const dec = s => Buffer.from(s, 'base64').toString('utf8')
const lines = fs.readFileSync('/tmp/palmier-gen-bridge.txt', 'utf8').split('\n').filter(l => l.length > 0)
const promptText = dec(lines[0])
const outPath = dec(lines[1])
const refPaths = lines.slice(2).map(dec)

await openOrReuseTab('https://chatgpt.com/', { wait: true, timeout: 30 })
await waitForElement('#prompt-textarea', { timeout: 20 })
await wait(2)

// Attach references through the composer's hidden file input before typing.
for (const ref of refPaths) {
  await uploadFile('input[type="file"]', ref)
}
if (refPaths.length > 0) {
  await wait(2)
  // The attachments echo into the sent message — remember every image src
  // currently on the page so the result detection can skip them.
  await js(`(() => {
    window.__palmierRefSrcs = new Set([...document.images].map(i => i.src))
    return window.__palmierRefSrcs.size
  })()`)
}
await fillInput('#prompt-textarea', promptText)
await wait(1)

// The send button stays disabled while attachments upload — wait it out.
let sent = false
for (let i = 0; i < 20 && !sent; i++) {
  sent = await js(`(() => {
    const btn = document.querySelector('button[data-testid="send-button"]')
    if (!btn || btn.disabled || btn.getAttribute('aria-disabled') === 'true') return false
    btn.click()
    return true
  })()`)
  if (!sent) await wait(2)
}
if (!sent) { throw new Error('send button never became available') }

// Poll for a NEW generated image (large, non-avatar) that was not on the page
// when the references were attached. Results render at the bottom, so among
// new candidates the last in DOM order is the freshest.
let src = null
for (let i = 0; i < 30 && !src; i++) {
  await wait(5)
  src = await js(String.raw`(() => {
    const refSrcs = window.__palmierRefSrcs
    const main = document.querySelector('main') || document.body
    const imgs = [...main.querySelectorAll('img')].filter(x =>
      x.naturalWidth > 256 && x.naturalHeight > 256 &&
      !x.src.includes('avatar') && !x.src.includes('openai-logo') &&
      !(refSrcs && refSrcs.has(x.src)))
    return imgs.length ? imgs[imgs.length - 1].src : null
  })()`)
}
if (!src) { throw new Error('no image appeared within 150s') }

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
