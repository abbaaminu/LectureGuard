#!/usr/bin/env bash
# Build, verify and checksum installable LectureGuard release APKs.
#
#   tool/build_release_apks.sh                 # universal APK + per-ABI APKs
#   tool/build_release_apks.sh --universal-only
#   tool/build_release_apks.sh --verify-only    # re-check APKs already built
#
# Supabase credentials come from the environment (CI passes SUPABASE_URL and
# SUPABASE_ANON_KEY), otherwise from flutter_app/env.json (see env.example.json).
#
# Every APK is built signed (v1 + v2 + v3, see android/app/build.gradle.kts),
# zip-aligned, verified with apksigner and listed in SHA256SUMS.txt next to the
# binaries, so a downloaded file can be checked before it is copied to a phone.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd "$APP_DIR"

UNIVERSAL_ONLY=false
VERIFY_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --universal-only) UNIVERSAL_ONLY=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    -h | --help)
      sed -n '2,13p' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "error: unknown option '$arg'" >&2
      exit 64
      ;;
  esac
done

defines=()
if [[ "$VERIFY_ONLY" == true ]]; then
  : # credentials are only needed to build
elif [[ -n "${SUPABASE_URL:-}" && -n "${SUPABASE_ANON_KEY:-}" ]]; then
  defines+=(
    --dart-define="SUPABASE_URL=$SUPABASE_URL"
    --dart-define="SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY"
  )
elif [[ -f env.json ]]; then
  defines+=(--dart-define-from-file=env.json)
else
  echo "error: set SUPABASE_URL and SUPABASE_ANON_KEY, or create" >&2
  echo "       flutter_app/env.json (copy env.example.json and fill it in)." >&2
  exit 1
fi

SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/toolchains/android-sdk}}"
BUILD_TOOLS=$(
  find "$SDK_DIR/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    sort -V | tail -n 1 || true
)
if [[ -z "$BUILD_TOOLS" ]]; then
  echo "error: no Android build-tools found under $SDK_DIR/build-tools" >&2
  exit 1
fi

APKSIGNER="$BUILD_TOOLS/apksigner"
ZIPALIGN="$BUILD_TOOLS/zipalign"
if [[ ! -x "$APKSIGNER" && -f "$APKSIGNER.bat" ]]; then
  APKSIGNER="$APKSIGNER.bat"
fi
for tool in "$APKSIGNER" "$ZIPALIGN"; do
  if [[ ! -e "$tool" ]]; then
    echo "error: $tool missing from $BUILD_TOOLS (install Android build-tools)" >&2
    exit 1
  fi
done

if [[ "$VERIFY_ONLY" == true ]]; then
  echo "==> skipping builds (--verify-only)"
else
  echo "==> flutter build apk --release"
  flutter build apk --release --no-pub "${defines[@]}"

  if [[ "$UNIVERSAL_ONLY" == false ]]; then
    # Per-ABI APKs are roughly a third of the universal size, which matters
    # when the file is downloaded and side-loaded over a phone connection.
    echo "==> flutter build apk --release --split-per-abi"
    flutter build apk --release --no-pub --split-per-abi "${defines[@]}"
  fi
fi

OUT="build/app/outputs/flutter-apk"
shopt -s nullglob
apks=("$OUT"/app-*-release.apk "$OUT/app-release.apk")
shopt -u nullglob
if [[ ${#apks[@]} -eq 0 ]]; then
  echo "error: no APKs were produced in $OUT" >&2
  exit 1
fi

checksums="$OUT/SHA256SUMS.txt"
: >"$checksums"
debug_signed=false
v1_missing=()

for apk in "${apks[@]}"; do
  name=$(basename "$apk")
  echo "==> verifying $name"

  if ! "$ZIPALIGN" -c -v 4 "$apk" >/dev/null 2>&1; then
    echo "error: $name is not zip-aligned (install fails with INSTALL_PARSE_FAILED)" >&2
    exit 1
  fi

  # --min-sdk-version 21 makes apksigner validate the v1 (JAR) signature as
  # well; with the APK's own minSdk (24) it only checks v2/v3 and reports
  # "Verified using v1 scheme (JAR signing): false" for a perfectly good APK.
  if ! certs=$("$APKSIGNER" verify -v --print-certs --min-sdk-version 21 "$apk" 2>&1); then
    echo "error: $name is not signed correctly:" >&2
    echo "$certs" >&2
    exit 1
  fi
  # Surface the signer so a debug key can never be published unnoticed.
  grep -E 'Verified using|Signer #1 certificate DN' <<<"$certs" | sed 's/^/    /'
  if grep -q 'CN=Android Debug' <<<"$certs"; then
    debug_signed=true
  fi
  if ! grep -q 'Verified using v1 scheme (JAR signing): true' <<<"$certs"; then
    v1_missing+=("$name")
  fi

  printf '%s  %s\n' "$(sha256sum "$apk" | cut -d' ' -f1)" "$name" >>"$checksums"
done

if [[ ${#v1_missing[@]} -gt 0 ]]; then
  echo "error: v1 (JAR) signature missing from: ${v1_missing[*]}" >&2
  echo "       android/app/build.gradle.kts must keep enableV1Signing = true;" >&2
  echo "       v2-only APKs are rejected by some OEM package installers." >&2
  exit 1
fi

echo
echo "APKs in $APP_DIR/$OUT"
for apk in "${apks[@]}"; do
  printf '  %-28s %s\n' "$(basename "$apk")" "$(du -h "$apk" | cut -f1)"
done
echo "  SHA-256 checksums: $checksums"
echo
if [[ "$debug_signed" == true ]]; then
  echo "NOTICE: at least one APK is signed with the debug key (android/key.properties"
  echo "        is missing). It installs on a phone, but it can never be published or"
  echo "        used to update a Play/CI-signed install. See the README for the"
  echo "        keystore setup."
fi
