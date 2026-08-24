#!/usr/bin/env bash
set -euo pipefail

# PrivilegedHelperClient and the root helper both require the running bundle
# path to be exactly /Applications/Mac 游戏工具箱.app. Launching the Debug
# product from DerivedData cannot install or talk to the helper.

MODE="${1:-run}"
APP_NAME="Mac 游戏工具箱"
PROJECT_NAME="Mac游戏工具箱.xcodeproj"
SCHEME="Mac游戏工具箱"
INSTALL_APP="/Applications/${APP_NAME}.app"
HELPER_RELATIVE="Contents/Library/LaunchServices/MacGameToolboxPrivilegedHelper"
INSTALLED_HELPER="/Library/PrivilegedHelperTools/com.iven.macgametoolbox.helper.v8"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$ROOT_DIR/.codex/DerivedDataApp}"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"

xcodebuild \
  -project "$ROOT_DIR/$PROJECT_NAME" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

if [[ ! -d "$BUILT_APP" ]]; then
    echo "error: built app not found: $BUILT_APP" >&2
    exit 1
fi

HELPER="$BUILT_APP/$HELPER_RELATIVE"
if [[ ! -x "$HELPER" ]]; then
    echo "error: privileged helper missing from Debug bundle: $HELPER" >&2
    exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ -e "$INSTALL_APP" && ! -w "$INSTALL_APP" ]]; then
    echo "error: $INSTALL_APP is not writable; the Debug build must replace this path for helper access." >&2
    ls -ld "$INSTALL_APP" >&2
    exit 1
fi

echo "Installing Debug build to $INSTALL_APP (required for privileged helper)"
rm -rf "$INSTALL_APP"
ditto "$BUILT_APP" "$INSTALL_APP"

if [[ -x "$INSTALLED_HELPER" ]] && ! cmp -s "$INSTALL_APP/$HELPER_RELATIVE" "$INSTALLED_HELPER"; then
    echo "warning: bundled helper differs from $INSTALLED_HELPER" >&2
    echo "warning: trigger a privileged action in-app to reinstall, or the new helper code will not run" >&2
fi

open_app() {
    /usr/bin/open -n "$INSTALL_APP"
}

case "$MODE" in
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$INSTALL_APP/Contents/MacOS/$APP_NAME"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.iven.macgametoolbox"'
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
