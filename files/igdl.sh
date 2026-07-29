#!/usr/bin/env bash
#
# igdl.sh — PROVEN working logic from prior iteration. This is the reference
# implementation the tool should be built around. Currently lives as two zsh
# functions (igdl / igdls). Included here verbatim so Claude Code starts from
# working code rather than reconstructing it.
#
# Requires: yt-dlp, ffmpeg. (gallery-dl to be added for image/carousel support.)
# Cookies: reads the user's Chrome session — mandatory for Instagram.

# --- Instagram video downloader — WITH SOUND ---
# Handles /p/, /reel/, /reels/. Auto-names from shortcode. Re-encodes to a
# QuickTime-friendly yuv420p H.264 mp4. Cleans up the temp file.
igdl() {
  local code
  code=$(echo "$1" | sed -E 's#.*/(p|reel|reels)/([^/?]+).*#\2#')
  cd ~/Downloads && \
  yt-dlp --cookies-from-browser chrome -o "src.%(ext)s" "$1" && \
  ffmpeg -y -i "src.mp4" -c:v libx264 -c:a aac -pix_fmt yuv420p "${code}_fixed.mp4" && \
  rm -f "src.mp4" && \
  echo "✓ Saved ${code}_fixed.mp4 to Downloads"
}

# --- Instagram video downloader — SILENT ---
# Same as above but grabs best-video-only (-f bv) and strips audio (-an).
igdls() {
  local code
  code=$(echo "$1" | sed -E 's#.*/(p|reel|reels)/([^/?]+).*#\2#')
  cd ~/Downloads && \
  yt-dlp --cookies-from-browser chrome -f "bv" -o "src.%(ext)s" "$1" && \
  ffmpeg -y -i "src.mp4" -c:v libx264 -pix_fmt yuv420p -an "${code}_fixed.mp4" && \
  rm -f "src.mp4" && \
  echo "✓ Saved ${code}_fixed.mp4 (silent) to Downloads"
}

# --- Specific carousel slide (manual pattern used when video isn't slide 1) ---
# Parse img_index=N from the URL, pass as --playlist-items N, suffix output _sN.
#   yt-dlp --cookies-from-browser chrome --playlist-items 2 -o "src.%(ext)s" "URL"
#   ffmpeg -y -i src.mp4 ... "CODE_s2_fixed.mp4"
# NOTE: if the targeted slide is an IMAGE, yt-dlp errors "No video formats found!"
#       -> that slide must be fetched with gallery-dl, not yt-dlp.

# --- Other platforms, proven one-offs ---
# YouTube (prefers QuickTime-friendly H.264/AAC; caps at 1080p — 4k is vp9/av1):
#   yt-dlp --cookies-from-browser chrome -S "vcodec:h264,res,acodec:aac" \
#     --merge-output-format mp4 -o "%(id)s.%(ext)s" "URL"
# Pinterest (public pins, no cookies needed; image pins may need i.pinimg.com/originals):
#   yt-dlp -o "pin_%(id)s.%(ext)s" "URL"
# Direct CDN mp4 that returns a tiny error blob to bare curl (e.g. cargo.site):
#   needs browser-like headers —
#   curl -L -O -H "User-Agent: Mozilla/5.0 ..." -H "Referer: https://SITE/" "URL"
# LinkedIn: yt-dlp extractor is flaky ("Unable to extract video"); fall back to
#   the Network tab (.m3u8/.mpd/licdn) — video is often a blob, so DevTools not bookmarklet.
