#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBXPROJ="$ROOT_DIR/NoiseClear.xcodeproj/project.pbxproj"

if [[ ! -f "$PBXPROJ" ]]; then
  echo "[ERROR] project.pbxproj not found: $PBXPROJ"
  exit 1
fi

current_version="$(grep -m1 -E 'CURRENT_PROJECT_VERSION = [0-9]+;' "$PBXPROJ" | sed -E 's/.*= ([0-9]+);/\1/')"

if [[ -z "$current_version" ]]; then
  echo "[ERROR] Cannot find CURRENT_PROJECT_VERSION in $PBXPROJ"
  exit 1
fi

if [[ $# -gt 1 ]]; then
  echo "Usage: ./scripts/bump_build_number.sh [target_build_number]"
  exit 1
fi

if [[ $# -eq 1 ]]; then
  target_version="$1"
  if [[ ! "$target_version" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] target_build_number must be an integer"
    exit 1
  fi
  if (( target_version <= current_version )); then
    echo "[ERROR] target_build_number ($target_version) must be greater than current ($current_version)"
    exit 1
  fi
else
  target_version=$((current_version + 1))
fi

perl -i -pe "s/CURRENT_PROJECT_VERSION = ${current_version};/CURRENT_PROJECT_VERSION = ${target_version};/g" "$PBXPROJ"

updated_count="$(grep -c "CURRENT_PROJECT_VERSION = ${target_version};" "$PBXPROJ")"
if [[ "$updated_count" -lt 1 ]]; then
  echo "[ERROR] Failed to update build number"
  exit 1
fi

echo "[OK] CURRENT_PROJECT_VERSION: ${current_version} -> ${target_version}"
