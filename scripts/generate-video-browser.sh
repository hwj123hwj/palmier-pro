#!/bin/bash
# Generate a video via the Gemini web UI (Veo) using ego-browser, bound to the
# account profile that has video quota (default: the "Bilal" profile).
# No API key; consumes that account's Gemini web quota.
#
# Usage:
#   scripts/generate-video-browser.sh "prompt" [output.mp4] [profile-name] [--source-image path]
#
# With --source-image the image is uploaded as the conversation attachment and
# Veo animates it (image-to-video, first frame).
#
# Requirements: ego-browser CLI installed; the named profile logged into Gemini.
# Selectors verified against gemini.google.com as of 2026-08-16.
# NOTE: ego-browser does not forward environment variables to its node runtime,
# so parameters travel through a fixed bridge file (/tmp/palmier-video-bridge.txt).
# All values are base64 (prompts may contain newlines).
set -euo pipefail

SOURCE_IMAGE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --source-image)
      if [ $# -lt 2 ] || [ ! -f "$2" ]; then
        echo "source image not found: ${2:-<missing>}" >&2; exit 1
      fi
      SOURCE_IMAGE="$2"; shift 2 ;;
    --source-image=*)
      p="${1#*=}"
      if [ ! -f "$p" ]; then echo "source image not found: $p" >&2; exit 1; fi
      SOURCE_IMAGE="$p"; shift ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
PROMPT="${POSITIONAL[0]:?usage: generate-video-browser.sh \"prompt\" [output.mp4] [profile] [--source-image path]}"
# The web UI only invokes Veo for explicit video intent.
if printf '%s' "$PROMPT" | grep -qiE 'video|视频|动画|animate'; then
  EFFECTIVE_PROMPT="$PROMPT"
elif [ -n "$SOURCE_IMAGE" ]; then
  EFFECTIVE_PROMPT="Generate a video from the attached image: $PROMPT"
else
  EFFECTIVE_PROMPT="Generate a video: $PROMPT"
fi
OUT="${POSITIONAL[1]:-$HOME/Downloads/palmier-video-$(date +%H%M%S).mp4}"
PROFILE_NAME="${POSITIONAL[2]:-Bilal}"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; printf '\n'; }
BRIDGE=/tmp/palmier-video-bridge.txt
{
  b64 "$EFFECTIVE_PROMPT"
  b64 "$OUT"
  b64 "$PROFILE_NAME"
  b64 "$SOURCE_IMAGE"
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
const fs = await import('fs')
const dec = s => Buffer.from(s, 'base64').toString('utf8')
const [promptText, outPath, profileName, sourceImage] =
  fs.readFileSync('/tmp/palmier-video-bridge.txt', 'utf8').split('\n').filter(l => l.length > 0).map(dec)

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
// The Angular composer hydrates late on slow links — wait for it explicitly.
await waitForElement('rich-textarea .ql-editor', { timeout: 20 })
await wait(2)

// Attach the first frame. The composer's file input only mounts after opening
// the "Upload & tools" menu; the input's accept list is document-typed but CDP
// upload of an image is accepted (verified: "Uploading image" + attachment chip).
if (sourceImage) {
  try {
    await click('button[aria-label="Upload & tools"]', { label: 'open upload menu' })
  } catch (e) {
    await js(`(() => {
      const btn = [...document.querySelectorAll('button')].find(b =>
        /upload|上传|附件|attach/i.test((b.getAttribute('aria-label') || '') + (b.textContent || '')))
      if (btn) btn.click()
      return !!btn
    })()`)
  }
  await waitForElement('input[type="file"]', { timeout: 10 })
  await uploadFile('input[type="file"]', sourceImage)
  await wait(3)
}

await fillInput('rich-textarea .ql-editor', promptText)
await wait(1)

// The send button stays disabled while the attachment uploads — wait it out.
let sent = false
for (let i = 0; i < 30 && !sent; i++) {
  sent = await js(`(() => {
    const btn = document.querySelector('button.send-button, button[aria-label*="Send"]')
    if (!btn || btn.disabled || btn.getAttribute('aria-disabled') === 'true') return false
    btn.click()
    return true
  })()`)
  if (!sent) await wait(2)
}
if (!sent) { throw new Error('send button never became available') }

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
