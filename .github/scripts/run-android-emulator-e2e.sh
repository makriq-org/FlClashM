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

# Finish the instrumentation process, then kill the real UI PID while the
# process-owned backend and transport continue running under the VPN service.
adb shell am instrument -w -r -e scenario seed \
  com.makriq.flclash.dev.test/androidx.test.runner.AndroidJUnitRunner \
  | tee "$artifacts/headless-seed.txt"
grep -q '^OK (1 test)$' "$artifacts/headless-seed.txt"
remote_before=$(adb shell pidof com.makriq.flclash.dev:remote | tr -d '\r')
main_pid=$(adb shell pidof com.makriq.flclash.dev | tr -d '\r')
test -n "$remote_before"
if [ -n "$main_pid" ]; then adb shell run-as com.makriq.flclash.dev kill -9 "$main_pid"; fi
sleep 3
remote_after=$(adb shell pidof com.makriq.flclash.dev:remote | tr -d '\r')
test "$remote_before" = "$remote_after"
adb shell am instrument -w -r -e scenario observe \
  com.makriq.flclash.dev.test/androidx.test.runner.AndroidJUnitRunner \
  | tee "$artifacts/headless-observe.txt"
grep -q '^OK (1 test)$' "$artifacts/headless-observe.txt"
# Unexpected native process death: Android's sticky service and the same Go
# recovery executor must rebuild the committed generation, without Flutter.
adb shell run-as com.makriq.flclash.dev kill -9 "$remote_after"
sleep 5
adb shell am instrument -w -r -e scenario recovered \
  com.makriq.flclash.dev.test/androidx.test.runner.AndroidJUnitRunner \
  | tee "$artifacts/recovered.txt"
grep -q '^OK (1 test)$' "$artifacts/recovered.txt"
