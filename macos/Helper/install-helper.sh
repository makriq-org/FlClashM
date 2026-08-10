#!/bin/sh
set -eu

identity=app.flclashm.client
helper=/Library/PrivilegedHelperTools/$identity.helper
daemon=/Library/LaunchDaemons/$identity.helper.plist
socket=/var/run/$identity.helper.sock
state=/var/db/$identity.helper-state.json

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer must run as root." >&2
  exit 1
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
bundle=$(CDPATH='' cd -- "$script_dir/../../.." && pwd -P)
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")
if [ "$bundle_id" != "$identity" ]; then
  echo "Unexpected app bundle identity: $bundle_id" >&2
  exit 1
fi

case "${1:-}" in
  install)
    source_helper="$bundle/Contents/runtimes/macos/$(uname -m)/$identity.helper"
    source_plist="$script_dir/$identity.helper.plist"
    [ -f "$source_helper" ] && [ -x "$source_helper" ] && [ -f "$source_plist" ]
    /bin/launchctl bootout system/$identity.helper >/dev/null 2>&1 || true
    if [ -x "$helper" ]; then "$helper" --rollback-all || true; fi
    /usr/bin/install -o root -g wheel -m 0755 "$source_helper" "$helper"
    /usr/bin/install -o root -g wheel -m 0644 "$source_plist" "$daemon"
    /bin/launchctl bootstrap system "$daemon"
    /bin/launchctl kickstart -k system/$identity.helper
    ;;
  uninstall)
    /bin/launchctl bootout system/$identity.helper >/dev/null 2>&1 || true
    if [ -x "$helper" ]; then "$helper" --rollback-all || true; fi
    /bin/rm -f "$helper" "$daemon" "$socket" "$state"
    ;;
  *)
    echo "Usage: install-helper.sh install|uninstall" >&2
    exit 64
    ;;
esac
