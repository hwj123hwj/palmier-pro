#!/bin/bash
# Generate a video via the Gemini web UI (Veo) using ego-browser, bound to the
# account profile that has video quota (default: the "Bilal" profile).
# No API key; consumes that account's Gemini web quota.
#
# Usage:
#   scripts/generate-video-browser.sh "prompt" [output.mp4] [profile-name]
#
# Requirements: ego-browser CLI installed; the named profile logged into Gemini.
# Selectors verified against gemini.google.com as of 2026-08-16.
# NOTE: ego-browser does not forward environment variables to its node runtime,
# so parameters travel through a fixed bridge file (/tmp/palmier-video-bridge.txt).
set -euo pipefail

PROMPT="${1:?usage: generate-video-browser.sh \"prompt\" [output.mp4] [profile-name]}"
# The web UI only invokes Veo for explicit video intent.
if printf '%s' "$PROMPT" | grep -qiE 'video|视频|动画|animate'; then
  EFFECTIVE_PROMPT="$PROMPT"
else
  EFFECTIVE_PROMPT="Generate a video: $PROMPT"
fi
OUT="${2:-$HOME/Downloads/palmier-video-$(date +%H%M%S).mp4}"
PROFILE_NAME="${3:-Bilal}"

BRIDGE=/tmp/palmier-video-bridge.txt
printf '%s\n%s\n%s\n' "$EFFECTIVE_PROMPT" "$OUT" "$PROFILE_NAME" > "$BRIDGE"
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
const fs = await import('fs')
const [promptText, outPath, profileName] = fs.readFileSync('/tmp/palmier-video-bridge.txt', 'utf8').split('\n')

// Task spaces bind a browser profile at creation; reuse ours, or create it
// on the account profile that carries the video quota.
const SPACE = 'palmier web video'
const spaces = await listTaskSpaces()
let task = spaces.spaces?.find?.(s => s.name === SPACE) || spaces.find?.(s => s.name === SPACE)
if (!task) {
  const profiles = await listProfiles()
  const list = profiles.profiles || profiles
  const profile = list.find(p => p.name === profileName || p.id === profileName)
  if (!profile) { throw new Error('profile not found: ' + profileName) }
  const created = await ego.createTaskSpace(SPACE, profile.id)
  task = await useOrCreateTaskSpace(created.id)
} else {
  task = await useOrCreateTaskSpace(task.id ?? SPACE)
}

await openOrReuseTab('https://gemini.google.com/app', { wait: true, timeout: 30 })
await wait(3)

await fillInput('rich-textarea .ql-editor', promptText)
await wait(1)
const sent = await js(`(() => {
  const btn = document.querySelector('button.send-button, button[aria-label*="Send"]')
  if (!btn || btn.disabled) return false
  btn.click()
  return true
})()`)
if (!sent) { throw new Error('send button not available') }

// Veo renders a <video> when done; ~1 min typical, allow 6.
let src = null
for (let i = 0; i < 36 && !src; i++) {
  await wait(10)
  src = await js(`(() => {
    const v = (document.querySelector('main') || document.body).querySelector('video')
    return v && v.src ? v.src : null
  })()`)
}
if (!src) { throw new Error('no video appeared within 360s') }

// The download URL requires the browser's Google cookies — fetch in-page and
// base64 there; raw binary crossing CDP loses bytes.
const b64 = await js(`(async () => {
  const res = await fetch(${JSON.stringify(src)}, { credentials: 'include' })
  const blob = await res.blob()
  return await new Promise(resolve => {
    const fr = new FileReader()
    fr.onload = () => resolve(fr.result.split(',')[1])
    fr.readAsDataURL(blob)
  })
})()`)
const buf = Buffer.from(b64, 'base64')
if (buf.subarray(4, 8).toString() !== 'ftyp') {
  throw new Error('downloaded bytes are not an MP4')
}
fs.writeFileSync(outPath, buf)
cliLog('saved ' + outPath + ' (' + buf.length + ' bytes)')
await completeTaskSpace(task.id, { keep: false })
EOF
echo "==> $OUT"
