#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v flutter >/dev/null 2>&1; then
  echo 'Flutter SDK not found. Install Flutter first: https://docs.flutter.dev/get-started/install'
  exit 1
fi
if [[ -e "$ROOT/mobile/android" || -e "$ROOT/mobile/ios" ]]; then
  echo 'Platform folders already exist; not overwriting. Run flutter pub get manually.'
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
flutter create --project-name khotwa --org org.khotwa --platforms android,ios "$TMP/khotwa"
cp -R "$TMP/khotwa/android" "$ROOT/mobile/android"
cp -R "$TMP/khotwa/ios" "$ROOT/mobile/ios"
cp "$TMP/khotwa/.metadata" "$ROOT/mobile/.metadata"
python3 "$ROOT/scripts/prepare_android_manifest.py" "$ROOT/mobile/android/app/src/main/AndroidManifest.xml"
cd "$ROOT/mobile"
flutter pub get
flutter analyze
flutter test
printf '\nReady: cd mobile && flutter run\n'
