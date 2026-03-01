#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

warn_count=0

echo "[l10n-audit] Checking hardcoded UI text..."
HARDCODED=$(rg -n 'Text\("[^"\\]*[A-Za-z\u4e00-\u9fa5][^"\\]*"|Label\("[^"\\]*[A-Za-z\u4e00-\u9fa5][^"\\]*"|Button\("[^"\\]*[A-Za-z\u4e00-\u9fa5][^"\\]*"|TextField\("[^"\\]*[A-Za-z\u4e00-\u9fa5][^"\\]*"|\.help\("[^"\\]*[A-Za-z\u4e00-\u9fa5][^"\\]*"|accessibilityLabel\(Text\("[^"\\]*[A-Za-z\u4e00-\u9fa5][^"\\]*"' VoiceClear -g '*.swift' || true)
if [[ -n "$HARDCODED" ]]; then
  warn_count=$((warn_count + 1))
  echo "[WARN] Hardcoded UI text detected:"
  echo "$HARDCODED"
else
  echo "[OK] No hardcoded UI text found in SwiftUI callsites."
fi

echo "[l10n-audit] Checking missing localizations in Localizable.xcstrings..."
MISSING=$(jq -r '
  .strings
  | to_entries
  | map(select(.key != ""))
  | map(. as $entry | {
      key: $entry.key,
      missing: (["en", "zh-Hans", "zh-Hant"] | map(select(($entry.value.localizations[.] // null) == null)))
    })
  | map(select(.missing | length > 0))
' VoiceClear/Localizable.xcstrings)
if [[ "$MISSING" != "[]" ]]; then
  warn_count=$((warn_count + 1))
  echo "[WARN] Missing localization entries:"
  echo "$MISSING"
else
  echo "[OK] No missing localizations for en/zh-Hans/zh-Hant."
fi

echo "[l10n-audit] Checking suspicious typos..."
TYPO_HITS=$(jq -r '
  .strings
  | to_entries[]
  | . as $entry
  | ($entry.value.localizations // {})
  | to_entries[]
  | select((.value.stringUnit.value // "") | test("Englist|teh|langauge"; "i"))
  | "\($entry.key) [\(.key)] => \(.value.stringUnit.value)"
' VoiceClear/Localizable.xcstrings)
if [[ -n "$TYPO_HITS" ]]; then
  warn_count=$((warn_count + 1))
  echo "[WARN] Suspicious localization values found:"
  echo "$TYPO_HITS"
else
  echo "[OK] No suspicious typo hits in denylist."
fi

echo "[l10n-audit] Completed with ${warn_count} warning group(s)."
exit 0
