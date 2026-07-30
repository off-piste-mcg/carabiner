#!/usr/bin/env bash
#
# fetch-deps.sh — download the binaries Carabiner.app bundles, into a gitignored cache.
# Idempotent: a binary that is already installed and intact is left alone.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/../app/.deps/bin"
LOCK="$HERE/deps.lock"
# Deliberately a sibling of DEST, not inside it: app/project.yml copies .deps/bin into the
# bundle as a folder reference, so anything sitting in there ships inside the signed app.
# Only the binaries themselves belong in DEST.
STAMPS="$HERE/../app/.deps/stamps"

mkdir -p "$DEST" "$STAMPS"
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
  stamp="$STAMPS/$name.sha256"
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

  rm -rf "${DEST:?}/_$name" "$DEST/$name"
  case "$url" in
    *.tar.gz) tar -xzf "$tmp/dl" -C "$tmp" ;;
    *)        mv "$tmp/dl" "$tmp/$name" ;;
  esac

  if [ -d "$tmp/$name" ]; then
    # A PyInstaller --onedir tree: a launcher plus an _internal/ of libraries. It lands as
    # bin/_<name>/ with a RELATIVE symlink bin/<name> beside it, so everything stays inside
    # the one directory project.yml copies and CARABINER_BIN points at — no change to the
    # bundle layout, GrabRunner, or the PATH contract. The launcher finds _internal from
    # its own real path, so resolving through the symlink is fine.
    mv "$tmp/$name" "$DEST/_$name"
    chmod +x "$DEST/_$name/$name"
    ln -s "_$name/$name" "$DEST/$name"
  else
    mv "$tmp/$name" "$DEST/$name"
    chmod +x "$DEST/$name"
  fi
  # Hash the launcher itself (following the symlink) — it is the thing that must not
  # change under us, and it is what the cache check re-reads next time.
  printf '%s  %s\n' "$sha" "$(sha_of "$DEST/$name")" > "$stamp"
done < "$LOCK"

echo
echo "Bundled binaries in $DEST:"
for b in yt-dlp ffmpeg gallery-dl; do
  kind="single file"
  [ -L "$DEST/$b" ] && kind="onedir → $(readlink "$DEST/$b")"
  printf '  %-11s %-24s %s\n' "$b" "$(lipo -archs "$DEST/$b" 2>/dev/null || echo '(not a Mach-O)')" "$kind"
done
