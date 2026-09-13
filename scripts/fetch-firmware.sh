#!/usr/bin/env bash
# fetch-firmware.sh — download one versioned Kobo firmware zip and lay out
# firmware/<version>/ for the emulator build.
#
# Usage:
#   fetch-firmware.sh <version> [--hw kobo3] [--url URL] [--out DIR] [--mirror]
#
# Examples:
#   fetch-firmware.sh 4.38.23684
#   fetch-firmware.sh 4.31.19086 --hw kobo3
#   fetch-firmware.sh 4.99.99999 --url https://example.com/kobo-update-4.99.99999.zip
set -euo pipefail

readonly CDN_BASE_URL="https://cdn.kobo.com/downloads/firmwares"
readonly MIRROR_BASE_URL="https://kfw.storage.pgaskin.net/firmwares"
readonly DEFAULT_HARDWARE="kobo3"
readonly DEFAULT_OUTPUT_ROOT="firmware"

print_usage() {
  cat <<'USAGE'
Usage: fetch-firmware.sh <version> [--hw NAME] [--url URL] [--out DIR] [--mirror]

  <version>   Firmware version, e.g. 4.38.23684 (never hardcoded; always an argument)
  --hw NAME   Hardware group, e.g. kobo3 for N905 Touch (default: kobo3)
  --url URL   Explicit zip URL (required for versions without a known CDN directory)
  --out DIR   Output root (default: firmware); version lands in DIR/<version>/
  --mirror    Use the pgaskin mirror instead of the Kobo CDN
  --help      Print this help
USAGE
}

die() {
  echo "fetch-firmware: error: $*" >&2
  exit 1
}

# Parse, don't validate: a known version maps to exactly one CDN month directory.
# Unknown versions are rejected here so callers must pass --url explicitly.
month_dir_for_version() {
  local version="$1"
  case "$version" in
    4.38.23684) printf 'Apr2026' ;;
    4.31.19086) printf 'Jan2022' ;;
    *) return 1 ;;
  esac
}

is_valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

main() {
  local version=""
  local hardware="$DEFAULT_HARDWARE"
  local explicit_url=""
  local output_root="$DEFAULT_OUTPUT_ROOT"
  local base_url="$CDN_BASE_URL"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h) print_usage; exit 0 ;;
      --hw) hardware="${2:?fetch-firmware: error: --hw needs a value}"; shift 2 ;;
      --url) explicit_url="${2:?fetch-firmware: error: --url needs a value}"; shift 2 ;;
      --out) output_root="${2:?fetch-firmware: error: --out needs a value}"; shift 2 ;;
      --mirror) base_url="$MIRROR_BASE_URL"; shift ;;
      --*) die "unknown flag: $1 (see --help)" ;;
      *) [[ -z "$version" ]] || die "unexpected extra argument: $1"; version="$1"; shift ;;
    esac
  done

  [[ -n "$version" ]] || { print_usage; die "missing <version> argument"; }
  is_valid_version "$version" || die "malformed version '$version' (want MAJOR.MINOR.BUILD like 4.38.23684)"
  [[ -n "$hardware" ]] || die "hardware group must not be empty"

  local zip_url="$explicit_url"
  if [[ -z "$zip_url" ]]; then
    local month_dir
    month_dir="$(month_dir_for_version "$version")" \
      || die "no known CDN directory for version '$version'; re-run with --url <zip-url>"
    zip_url="$base_url/$hardware/$month_dir/kobo-update-$version.zip"
  fi

  local version_dir="$output_root/$version"
  local zip_path="$version_dir/kobo-update-$version.zip"
  mkdir -p "$version_dir"

  echo "fetch-firmware: version=$version hardware=$hardware"
  echo "fetch-firmware: url=$zip_url"
  echo "fetch-firmware: dest=$zip_path"

  curl -fL --retry 3 --retry-delay 5 -C - --progress-bar -o "$zip_path" "$zip_url"

  [[ -s "$zip_path" ]] || die "downloaded zip is missing or empty: $zip_path"

  local zip_bytes zip_sha256
  zip_bytes="$(stat -c%s "$zip_path")"
  zip_sha256="$(sha256sum "$zip_path" | cut -d' ' -f1)"
  echo "fetch-firmware: bytes=$zip_bytes sha256=$zip_sha256"

  unzip -l "$zip_path" > "$version_dir/zip-contents.txt"

  grep -q 'KoboRoot.tgz' "$version_dir/zip-contents.txt" \
    || die "zip lacks KoboRoot.tgz; refusing to treat it as firmware"
  grep -q 'manifest.md5sum' "$version_dir/zip-contents.txt" \
    || die "zip lacks manifest.md5sum; refusing to treat it as firmware"

  # Extract boundary artifacts only; the rootfs itself is unpacked in Phase 2/3.
  unzip -o -q "$zip_path" 'KoboRoot.tgz' 'manifest.md5sum' 'upgrade/*' -d "$version_dir"
  [[ -f "$version_dir/KoboRoot.tgz" ]] || die "KoboRoot.tgz missing after extraction"

  cat > "$version_dir/fetch-info.txt" <<INFO
version=$version
hardware=$hardware
url=$zip_url
zip_bytes=$zip_bytes
zip_sha256=$zip_sha256
fetched_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INFO

  echo "fetch-firmware: extracted layout:"
  ls -la "$version_dir" "$version_dir/upgrade"
  echo "fetch-firmware: done ($version_dir)"
}

main "$@"
