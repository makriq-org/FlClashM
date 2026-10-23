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
  adb exec-out run-as com.makriq.flclash.dev cat files/backend/backend-v1.json | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); a=d.get("applied") or {}; print(json.dumps({"desiredRunning":d["desired"]["running"],"appliedRunning":a.get("running"),"generation":a.get("plan",{}).get("generation"),"pending":d.get("pending"),"receipts":d.get("receipts",[])}))' \
    > "$artifacts/journal-summary.json" 2>&1 || true
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
adb shell dumpsys deviceidle whitelist +com.makriq.flclash.dev
adb logcat -c
adb shell am instrument -w -r \
  com.makriq.flclash.dev.test/androidx.test.runner.AndroidJUnitRunner \
  | tee "$artifacts/instrumentation.txt"
grep -Eq '^OK \([1-9][0-9]* tests?\)$' "$artifacts/instrumentation.txt"
if grep -Eq 'FAILURES!!!|INSTRUMENTATION_ABORTED|Process crashed|shortMsg=' \
  "$artifacts/instrumentation.txt"; then
  echo "Instrumentation reported failures or a crash" >&2
  exit 1
fi

# Run a real Flutter activity. --no-restart avoids instrumentation's package
# force-stop both on entry and on finish; that would also kill the VPN service.
# Only this test owns the seed/observe/recovered protocol. Running the whole
# suite here would execute independent fixtures against its live REJECT VPN.
lifecycle_test='com.follow.clashx.AndroidRuntimeE2eTest#packagedBackendLifecycle'
launch_ui() {
  # Clear stale task/activity records after SIGKILL without force-stopping the
  # package (and its independent :remote service). Wait for the actual process;
  # --no-restart instrumentation requires it to exist.
  adb shell am start -W -f 0x10008000 -n com.makriq.flclash.dev/com.follow.clashx.MainActivity
  for attempt in $(seq 1 30); do
    if adb shell pidof com.makriq.flclash.dev > /dev/null; then return; fi
    sleep 1
  done
  return 1
}
launch_ui
adb shell am instrument --no-restart -w -r -e scenario seed \
  -e class "$lifecycle_test" \
  com.makriq.flclash.dev.test/androidx.test.runner.AndroidJUnitRunner \
  | tee "$artifacts/headless-seed.txt"
grep -Eq '^OK \(1 test\)$' "$artifacts/headless-seed.txt"
remote_before=$(adb shell pidof com.makriq.flclash.dev:remote | tr -d '\r')
main_pid=$(adb shell pidof com.makriq.flclash.dev | tr -d '\r' || true)
test -n "$remote_before"
if [ -n "$main_pid" ]; then adb shell run-as com.makriq.flclash.dev kill -9 "$main_pid"; fi
sleep 3
remote_after=$(adb shell pidof com.makriq.flclash.dev:remote | tr -d '\r')
test "$remote_before" = "$remote_after"
launch_ui
adb shell am instrument --no-restart -w -r -e scenario observe \
  -e class "$lifecycle_test" \
  com.makriq.flclash.dev.test/androidx.test.runner.AndroidJUnitRunner \
  | tee "$artifacts/headless-observe.txt"
grep -Eq '^OK \(1 test\)$' "$artifacts/headless-observe.txt"
# Remove Flutter again before killing :remote. Recovery must commit a new
# applied generation while no UI exists, before observation instrumentation.
main_pid=$(adb shell pidof com.makriq.flclash.dev | tr -d '\r' || true)
if [ -n "$main_pid" ]; then adb shell run-as com.makriq.flclash.dev kill -9 "$main_pid"; fi
generation_before=$(adb exec-out run-as com.makriq.flclash.dev cat files/backend/backend-v1.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["applied"]["plan"]["generation"])')
adb shell run-as com.makriq.flclash.dev kill -9 "$remote_after"
headless_ready=false
for attempt in $(seq 1 60); do
  if adb exec-out run-as com.makriq.flclash.dev cat files/backend/backend-v1.json | \
    python3 -c 'import json,sys; d=json.load(sys.stdin); a=d.get("applied") or {}; sys.exit(0 if a.get("running") and d["desired"]["running"] and a.get("plan",{}).get("generation",0)>int(sys.argv[1]) and d.get("pending") is None else 1)' "$generation_before"; then
    headless_ready=true
    break
  fi
  sleep 1
done
test "$headless_ready" = true
launch_ui
adb shell am instrument --no-restart -w -r -e scenario recovered \
  -e class "$lifecycle_test" \
  com.makriq.flclash.dev.test/androidx.test.runner.AndroidJUnitRunner \
  | tee "$artifacts/recovered.txt"
grep -Eq '^OK \(1 test\)$' "$artifacts/recovered.txt"
adb logcat -d -v threadtime > "$artifacts/logcat.txt"
if grep -Eq 'flutter.*Unhandled Exception:' "$artifacts/logcat.txt"; then
  echo "Flutter reported an unhandled exception" >&2
  exit 1
fi
