# macOS package

`package.sh` creates an unsigned update ZIP and a drag-to-Applications DMG. The
release intentionally does not use Developer ID, notarization, `xattr`, or any
Gatekeeper bypass. Opening the downloaded app for the first time remains a
manual release gate.

The privileged helper is installed from the app with one administrator prompt.
It uses a root-owned LaunchDaemon because `SMJobBless`/team-identity APIs are not
available to this unsigned release. Uninstall it from the app before deleting
the bundle, or run:

```sh
sudo /Applications/FlClashM.app/Contents/Resources/helper/install-helper.sh uninstall
```
