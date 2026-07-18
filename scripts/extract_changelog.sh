#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 64
fi

version="${1#v}"
changelog_path="${CHANGELOG_PATH:-CHANGELOG.md}"

if [[ ! -f "$changelog_path" ]]; then
  echo "Changelog not found: $changelog_path" >&2
  exit 66
fi

# Match the version heading structurally (string equality on the stripped
# heading token) so dots in the version are not regex wildcards, and stop at
# the first following heading instead of re-matching lookalikes.
awk -v version="$version" '
  BEGIN {
    in_section = 0
    found = 0
  }
  /^##[[:space:]]/ {
    if (in_section) {
      exit
    }
    token = $2
    sub(/\(.*$/, "", token)
    sub(/^v/, "", token)
    if (token == version) {
      in_section = 1
      found = 1
    }
    next
  }
  in_section {
    print
  }
  END {
    if (!found) {
      exit 1
    }
  }
' "$changelog_path" | sed '/./,$!d'
