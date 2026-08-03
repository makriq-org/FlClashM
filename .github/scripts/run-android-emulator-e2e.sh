#!/usr/bin/env bash
set -euo pipefail

artifacts="$RUNNER_TEMP/android-e2e-artifacts"
mkdir -p "$artifacts"

capture_diagnostics() {
  adb logcat -d -v threadtime > "$artifacts/logcat.txt" 2>&1 || true
  adb shell dumpsys activity services com.makriq.flclash.dev > "$artifacts/services.txt" 2>&1 || true
  adb shell dumpsys connectivity > "$artifacts/connectivity.txt" 2>&1 || true
  adb shell dumpsys notification --noredact > "$artifacts/notifications.txt" 2>&1 || true
  adb shell ps -A > "$artifacts/processes.txt" 2>&1 || true
  adb shell cmd appops get com.makriq.flclash.dev > "$artifacts/appops.txt" 2>&1 || true
}
trap capture_diagnostics EXIT

app_apk=build/app/outputs/flutter-apk/app-debug.apk
test_apk=build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
test -f "$app_apk"
test -f "$test_apk"

adb install -r -t "$app_apk"
adb install -r -t "$test_apk"
adb shell cmd appops set com.makriq.flclash.dev ACTIVATE_VPN allow
adb shell pm grant com.makriq.flclash.dev android.permission.POST_NOTIFICATIONS
adb logcat -c
adb shell am instrument -w -r \
  com.makriq.flclash.dev.test/androidx.test.runner.AndroidJUnitRunner \
  | tee "$artifacts/instrumentation.txt"
grep -q '^OK (1 test)$' "$artifacts/instrumentation.txt"
! grep -Eq 'FAILURES!!!|INSTRUMENTATION_ABORTED|Process crashed|shortMsg=' \
  "$artifacts/instrumentation.txt"
