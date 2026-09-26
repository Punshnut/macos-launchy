#!/usr/bin/env bash

set -euo pipefail

APP_NAME="Launchy"
PRODUCT_NAME="launchy"
VERBOSE="${VERBOSE:-0}"
COLOR="${COLOR:-1}"
ARCHES=(${ARCHES:-arm64 x86_64})

if [[ -t 1 && -z "${NO_COLOR:-}" && "$COLOR" != "0" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_BLUE=""
fi

log_header() { echo "${C_BOLD}$*${C_RESET}"; }
log_step() { echo "${C_BLUE}›${C_RESET} $*"; }
log_item() { echo "  - $*"; }
log_dim() { echo "${C_DIM}$*${C_RESET}"; }
log_error() { echo "${C_RED}✖${C_RESET} $*" >&2; }
log_success() { echo "${C_GREEN}✔${C_RESET} $*"; }

START_TIME="$(date +%s)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/${APP_NAME}.app"
INFO_PLIST="$PROJECT_ROOT/Resources/Info.plist"
ICON_BUNDLE="$PROJECT_ROOT/Resources/Launchy.icon"
ICON_NAME="Launchy"
# Resolved artifacts (e.g. Sparkle.xcframework) live under the arch-specific --build-path
# used below, not a shared ".build/artifacts" — computed once the first arch is known.
SPARKLE_FRAMEWORK_SRC="${SPARKLE_FRAMEWORK_SRC:-}"
BUILD_LOG="$PROJECT_ROOT/.derived/build_app.log"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/launchy-build.XXXXXX")"

trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$PROJECT_ROOT/.derived"

triple_for_arch() {
  case "$1" in
    arm64) echo "arm64-apple-macosx13.0" ;;
    x86_64) echo "x86_64-apple-macosx13.0" ;;
    *)
      log_error "Unsupported architecture: $1"
      exit 1
      ;;
  esac
}

# Swift's unified build system (6.4+) resolves --show-bin-path to the same
# ".build/out/Products/Release" directory for every --triple, so per-arch release
# builds must use distinct --build-path directories or they overwrite each other's
# binary before lipo can combine them.
build_path_for_arch() {
  echo "$PROJECT_ROOT/.build/arch-$1"
}

show_bin_path() {
  local triple="$1"
  local build_path="$2"
  swift build -c release --triple "$triple" --build-path "$build_path" --show-bin-path
}

build_arch() {
  local arch="$1"
  local triple build_path
  triple="$(triple_for_arch "$arch")"
  build_path="$(build_path_for_arch "$arch")"
  if [[ "$VERBOSE" == "1" ]]; then
    swift build -c release --triple "$triple" --build-path "$build_path"
  else
    swift build -c release --triple "$triple" --build-path "$build_path" >>"$BUILD_LOG" 2>&1
  fi
}

create_app_icon() {
  local actool_out="$TMP_DIR/ActoolOutput"
  mkdir -p "$actool_out"

  # Launchy.icon is an Icon Composer bundle (icon.json), a macOS 26 Tahoe-era format;
  # actool requires --minimum-deployment-target 26.0 to compile it, but that only affects
  # this icon-catalog compile step. It flattens down to a normal Assets.car/.icns that the
  # app still loads fine on its real floor (LSMinimumSystemVersion 13.0 / Package.swift .v13).
  # Do not "fix" this to match the app's deployment target — it will break the icon compile.
  xcrun actool "$ICON_BUNDLE" --compile "$actool_out" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist "$TMP_DIR/actool-partial-Info.plist" \
    --app-icon "$ICON_NAME" --include-all-app-icons \
    --enable-on-demand-resources NO \
    --development-region en \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --platform macosx >>"$BUILD_LOG" 2>&1

  cp "$actool_out/Assets.car" "$APP_BUNDLE/Contents/Resources/Assets.car"
  cp "$actool_out/$ICON_NAME.icns" "$APP_BUNDLE/Contents/Resources/$ICON_NAME.icns"
}

validate_binary_arches() {
  local binary_path="$1"
  shift
  local actual_arches
  actual_arches="$(xcrun lipo -archs "$binary_path" 2>/dev/null || true)"
  if [[ -z "$actual_arches" ]]; then
    log_error "Failed to inspect architectures for $binary_path"
    exit 1
  fi

  local arch
  for arch in "$@"; do
    if [[ " $actual_arches " != *" $arch "* ]]; then
      log_error "Built app is missing required architecture: $arch"
      log_item "Binary: $binary_path"
      log_item "Found: $actual_arches"
      exit 1
    fi
  done

  log_item "Architectures: $actual_arches"
}

if [[ ! -f "$INFO_PLIST" ]]; then
  log_error "Info.plist not found at $INFO_PLIST"
  exit 1
fi

if [[ ! -d "$ICON_BUNDLE" ]]; then
  log_error "Icon bundle not found at $ICON_BUNDLE"
  exit 1
fi

: >"$BUILD_LOG"

log_header "Launchy build"
log_step "Building Swift package"

declare -a built_binaries=()
for arch in "${ARCHES[@]}"; do
  log_item "Architecture: $arch"
  build_arch "$arch"
  bin_dir="$(show_bin_path "$(triple_for_arch "$arch")" "$(build_path_for_arch "$arch")")"
  binary_path="$bin_dir/$PRODUCT_NAME"
  if [[ ! -f "$binary_path" ]]; then
    log_error "Expected built binary at $binary_path"
    exit 1
  fi
  built_binaries+=("$binary_path")

  if [[ -z "$SPARKLE_FRAMEWORK_SRC" ]]; then
    SPARKLE_FRAMEWORK_SRC="$(build_path_for_arch "$arch")/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
  fi
done

if [[ ! -d "$SPARKLE_FRAMEWORK_SRC" ]]; then
  log_error "Sparkle.framework not found at $SPARKLE_FRAMEWORK_SRC"
  exit 1
fi

log_step "Assembling app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Frameworks" "$APP_BUNDLE/Contents/Resources"

if (( ${#built_binaries[@]} == 1 )); then
  cp "${built_binaries[0]}" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
else
  xcrun lipo -create "${built_binaries[@]}" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
ditto "$SPARKLE_FRAMEWORK_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

while IFS= read -r -d '' lproj_dir; do
  ditto "$lproj_dir" "$APP_BUNDLE/Contents/Resources/$(basename "$lproj_dir")"
done < <(find "$PROJECT_ROOT/Resources" -maxdepth 1 -type d -name '*.lproj' -print0)

create_app_icon

log_step "Verifying output"
validate_binary_arches "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "${ARCHES[@]}"
if [[ ! -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
  log_error "Sparkle.framework was not embedded"
  exit 1
fi
log_item "Sparkle: embedded"

ELAPSED="$(( $(date +%s) - START_TIME ))"
log_success "${APP_NAME}.app created"
log_item "Path: $APP_BUNDLE"
log_item "Elapsed: ${ELAPSED}s"
