#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: make_dmg.sh --app <TaskMenu.app> --version <x.y.z> --output-dir <dir>

Environment:
  SIGNING_IDENTITY              Optional Developer ID identity for signing the DMG.
  APPLE_ID                      Optional Apple ID for notarization.
  APPLE_TEAM_ID                 Optional Apple Developer Team ID for notarization.
  APPLE_APP_SPECIFIC_PASSWORD   Optional app-specific password for notarization.
EOF
}

app_path=""
version=""
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      app_path="$2"
      shift 2
      ;;
    --version)
      version="$2"
      shift 2
      ;;
    --output-dir)
      output_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [[ -z "$app_path" || -z "$version" || -z "$output_dir" ]]; then
  usage
  exit 64
fi

if [[ ! -d "$app_path" ]]; then
  echo "App bundle not found: $app_path" >&2
  exit 66
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app_path="$(cd "$(dirname "$app_path")" && pwd)/$(basename "$app_path")"

dmg_path="$output_dir/TaskMenu-${version}.dmg"
staging_dir="$(mktemp -d)"
trap 'rm -rf "$staging_dir"' EXIT

cp -R "$app_path" "$staging_dir/"
ln -s /Applications "$staging_dir/Applications"

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose "$app_path" || true

hdiutil create \
  -volname "TaskMenu ${version}" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$dmg_path"

if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$dmg_path"
  codesign --verify --verbose=2 "$dmg_path"
fi

if [[ -n "${APPLE_ID:-}" || -n "${APPLE_TEAM_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  if [[ -z "${APPLE_ID:-}" || -z "${APPLE_TEAM_ID:-}" || -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD must all be set to notarize." >&2
    exit 65
  fi

  xcrun notarytool submit "$dmg_path" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi

(cd "$output_dir" && shasum -a 256 "$(basename "$dmg_path")") | tee "${dmg_path}.sha256"

echo "$dmg_path"
