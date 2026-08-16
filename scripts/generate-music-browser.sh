#!/bin/bash
# Generate music via the Gemini web UI (Lyria) using ego-browser, bound to the
# account profile that has video quota (default: the "Bilal" profile).
# No API key; consumes that account's Gemini web quota.
#
# Usage:
#   scripts/generate-music-browser.sh "prompt" [output.mp4] [profile-name]
#
# Requirements: ego-browser CLI installed; the named profile logged into Gemini.
# Selectors verified against gemini.google.com as of 2026-08-16.
# NOTE: ego-browser does not forward environment variables to its node runtime,
# so parameters travel through a fixed bridge file (/tmp/palmier-music-bridge.txt).
set -euo pipefail

PROMPT="${1:?usage: generate-music-browser.sh \"prompt\" [output.mp4] [profile-name]}"
OUT="${2:-$HOME/Downloads/palmier-music-$(date +%H%M%S).mp4}"
PROFILE_NAME="${3:-Bilal}"

BRIDGE=/tmp/palmier-music-bridge.txt
printf '%s\n%s\n%s\n' "$PROMPT" "$OUT" "$PROFILE_NAME" > "$BRIDGE"
trap 'rm -f "$BRIDGE"' EXIT

ego-browser nodejs <<'EOF'
const fs = await import('fs')
const [promptText, outPath, profileName] = fs.readFileSync('/tmp/palmier-music-bridge.txt', 'utf8').split('\n')

// Task spaces bind a browser profile at creation; reuse ours, or create it
// on the account profile that carries the video quota.
const SPACE = 'palmier web music'
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

// Music renders in a <video> element (AAC in mp4); ~30s typical, allow 6.
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
// Kick the fetch off in-page (results land in window.__palmierDL) and poll —
// one long js() await would hit the evaluate timeout on slow transfers.
await js(`(() => {
  window.__palmierDL = { state: 'running' }
  fetch(${JSON.stringify(src)}, { credentials: 'include' })
    .then(r => r.blob())
    .then(blob => new Promise(resolve => {
      const fr = new FileReader()
      fr.onload = () => resolve(fr.result.split(',')[1])
      fr.readAsDataURL(blob)
    }))
    .then(b64 => { window.__palmierDL = { state: 'done', b64 } })
    .catch(e => { window.__palmierDL = { state: 'failed', error: String(e) } })
  return true
})()`)
let b64 = null
for (let i = 0; i < 60 && !b64; i++) {
  await wait(2)
  const st = await js(`(() => window.__palmierDL)()`)
  if (st && st.state === 'failed') { throw new Error('fetch failed: ' + st.error) }
  if (st && st.state === 'done') b64 = st.b64
}
if (!b64) { throw new Error('download did not finish within 120s') }
const buf = Buffer.from(b64, 'base64')
if (buf.subarray(4, 8).toString() !== 'ftyp') {
  throw new Error('downloaded bytes are not an MP4')
}
fs.writeFileSync(outPath, buf)
cliLog('saved ' + outPath + ' (' + buf.length + ' bytes)')
await completeTaskSpace(task.id, { keep: false })
EOF
echo "==> $OUT"
