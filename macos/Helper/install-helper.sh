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
    helper_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")
    case "$helper_build" in ''|*[!A-Za-z0-9._+-]*) echo "Invalid helper build identity." >&2; exit 1;; esac
    /bin/launchctl bootout system/$identity.helper >/dev/null 2>&1 || true
    if [ -x "$helper" ]; then "$helper" --rollback-all; fi
    /usr/bin/install -o root -g wheel -m 0755 "$source_helper" "$helper"
    /usr/bin/sed "s/__HELPER_BUILD__/$helper_build/g" "$source_plist" > "$daemon.new"
    /usr/bin/install -o root -g wheel -m 0644 "$daemon.new" "$daemon"
    /bin/rm -f "$daemon.new"
    /bin/launchctl bootstrap system "$daemon"
    /bin/launchctl kickstart -k system/$identity.helper
    ;;
  uninstall)
    if [ -x "$helper" ] && ! "$helper" --rollback-all; then
      echo "Helper network rollback failed; helper was retained for recovery." >&2
      exit 1
    fi
    /bin/launchctl bootout system/$identity.helper >/dev/null 2>&1 || true
    /bin/rm -f "$helper" "$daemon" "$socket" "$state"
    ;;
  *)
    echo "Usage: install-helper.sh install|uninstall" >&2
    exit 64
    ;;
esac
