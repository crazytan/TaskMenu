#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: make_dmg.sh --app <TaskMenu.app> --version <x.y.z> --output-dir <dir>

Environment:
  SIGNING_IDENTITY              Optional Developer ID identity for signing the DMG.
  APP_STORE_CONNECT_KEY_ID      Optional App Store Connect API key ID for notarization.
  APP_STORE_CONNECT_ISSUER_ID   Optional App Store Connect issuer ID for notarization.
  APP_STORE_CONNECT_KEY_PATH    Optional path to the App Store Connect private key.
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

if [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" || -n "${APP_STORE_CONNECT_ISSUER_ID:-}" || -n "${APP_STORE_CONNECT_KEY_PATH:-}" ]]; then
  if [[ -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" || -z "${APP_STORE_CONNECT_KEY_PATH:-}" ]]; then
    echo "APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, and APP_STORE_CONNECT_KEY_PATH must all be set to notarize." >&2
    exit 65
  fi

  if [[ ! -f "$APP_STORE_CONNECT_KEY_PATH" ]]; then
    echo "App Store Connect key not found: $APP_STORE_CONNECT_KEY_PATH" >&2
    exit 65
  fi

  xcrun notarytool submit "$dmg_path" \
    --key "$APP_STORE_CONNECT_KEY_PATH" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --wait
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
fi

(cd "$output_dir" && shasum -a 256 "$(basename "$dmg_path")") | tee "${dmg_path}.sha256"

echo "$dmg_path"
