#!/bin/bash
# Fails if a SwiftUI text initialiser interpolates into a string literal (LocalizedStringKey, so Markdown and
# localisation apply). Host-supplied text must use Text(verbatim:) / SafeTextView; non-host values use verbatim too.
set -euo pipefail
cd "$(dirname "$0")/.."
pattern='(Text|Label|Button|Section|LabeledContent|Toggle|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|alert|ProgressView|TextField)\("[^"]*\\\('
if grep -rnE "$pattern" App OrchKit/Sources/OrchUI --include=*.swift | grep -v '^App/Models/'; then
  echo "error: interpolated LocalizedStringKey text found; use Text(verbatim:)" >&2
  exit 1
fi
echo "verbatim text check OK"
