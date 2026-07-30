#!/usr/bin/env bash
#
# fetch-deps.sh — download the binaries Carabiner.app bundles, into a gitignored cache.
# Idempotent: a binary that is already installed and intact is left alone.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/../app/.deps/bin"
LOCK="$HERE/deps.lock"

mkdir -p "$DEST"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

while read -r name url sha; do
  case "$name" in ''|\#*) continue ;; esac

  # The lock pins the hash of what we DOWNLOAD, but for a .tar.gz what lands in the cache
  # is the binary extracted from it — a different file with a different hash. Comparing the
  # installed binary against the lock directly would therefore never match and we would
  # re-download ~42 MB on every build. So each install drops a stamp recording both hashes:
  #   <hash of the downloaded artifact>  <hash of the installed binary>
  # A cache hit needs both to agree — the first catches a changed lock entry, the second
  # catches a tampered-with cached binary.
  stamp="$DEST/.$name.sha256"
  if [ -f "$DEST/$name" ] && [ -f "$stamp" ]; then
    read -r stamped_src stamped_bin < "$stamp" || true
    if [ "${stamped_src:-}" = "$sha" ] && [ "${stamped_bin:-}" = "$(sha_of "$DEST/$name")" ]; then
      echo "✓ $name (cached)"; continue
    fi
  fi

  echo "→ $name"
  curl -fsSL "$url" -o "$tmp/dl"

  # Verify BEFORE unpacking or running anything. A tarball is unpacked only after its
  # hash matches, so a compromised release can't execute anything during extraction.
  actual="$(sha_of "$tmp/dl")"
  [ "$actual" = "$sha" ] || {
    echo "✗ $name checksum mismatch" >&2
    echo "  expected $sha" >&2
    echo "  actual   $actual" >&2
    exit 1
  }

  case "$url" in
    *.tar.gz) tar -xzf "$tmp/dl" -C "$tmp" && mv "$tmp/$name" "$DEST/$name" ;;
    *)        mv "$tmp/dl" "$DEST/$name" ;;
  esac
  chmod +x "$DEST/$name"
  printf '%s  %s\n' "$sha" "$(sha_of "$DEST/$name")" > "$stamp"
done < "$LOCK"

echo
echo "Bundled binaries in $DEST:"
for b in yt-dlp ffmpeg gallery-dl; do
  printf '  %-11s %s\n' "$b" "$(lipo -archs "$DEST/$b" 2>/dev/null || echo '(not a Mach-O)')"
done
