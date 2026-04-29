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

awk -v version="$version" '
  BEGIN {
    in_section = 0
    found = 0
  }
  $0 ~ "^##[[:space:]]+v?" version "([[:space:]]|$|\\()" {
    in_section = 1
    found = 1
    next
  }
  in_section && $0 ~ "^##[[:space:]]+" {
    exit
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
