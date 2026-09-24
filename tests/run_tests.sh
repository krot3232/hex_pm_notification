#!/usr/bin/env bash
# Usage: tests/run_tests.sh [test_name ...]
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../hex_pm_notification.sh"

passed=0
failed=0

setup() {
  WORK="$(mktemp -d)"
  export FAKE_HEX_DIR="$WORK/hex"
  export FAKE_TG_LOG="$WORK/tg.log"
  export FAKE_HEX_LOG="$WORK/hex.log"
  export FAKE_TG_FAIL=0
  export FAKE_TG_NETWORK_FAIL=0
  export FAKE_CURL_OLD=0
  export FAKE_KILL_ON=""
  export FAKE_BLOCK_ON=""
  export FAKE_RELEASE_FILE="$WORK/release"
  export PACKAGES_FILE="$WORK/packages.txt"
  export STATE_FILE="$WORK/state.txt"
  export CONFIG_FILE="$WORK/none.conf"
  export TELEGRAM_BOT_TOKEN="TOKEN"
  export TELEGRAM_CHAT_ID="42"
  export INCLUDE_PRERELEASE=0
  mkdir -p "$FAKE_HEX_DIR"
  : >"$FAKE_TG_LOG"
  : >"$FAKE_HEX_LOG"
}

teardown() {
  rm -rf "$WORK"
}

fixture() {
  local name="$1" stable="$2" latest="${3:-$2}"
  if [[ "$stable" == "null" ]]; then
    printf '{"name":"%s","latest_stable_version":null,"latest_version":"%s"}' "$name" "$latest" >"$FAKE_HEX_DIR/$name.json"
  else
    printf '{"name":"%s","latest_stable_version":"%s","latest_version":"%s"}' "$name" "$stable" "$latest" >"$FAKE_HEX_DIR/$name.json"
  fi
}

run() {
  PATH="$TESTS_DIR/fake_bin:$PATH" bash "$SCRIPT" >"$WORK/out" 2>"$WORK/err"
}

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf '    expected: %q\n    actual:   %q\n' "$2" "$1"
    return 1
  fi
}

test_first_run_tracks_without_notification() {
  printf 'jason\n# comment\n\nphoenix  # inline\n' >"$PACKAGES_FILE"
  fixture jason 1.4.4
  fixture phoenix 1.7.0
  run || return 1
  assert_eq "$(cat "$STATE_FILE")" $'jason 1.4.4\nphoenix 1.7.0' || return 1
  assert_eq "$(cat "$FAKE_TG_LOG")" ""
}

test_new_version_notifies_and_updates_state() {
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.4" || return 1
  grep -q 'jason: 1.4.3 → 1.4.4' "$FAKE_TG_LOG" || return 1
  grep -q 'NEW jason 1.4.3 -> 1.4.4' "$WORK/out"
}

test_same_version_is_silent() {
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.4" >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  assert_eq "$(cat "$FAKE_TG_LOG")" ""
}

test_prerelease_ignored_by_default() {
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.4" >"$STATE_FILE"
  fixture jason 1.4.4 1.5.0-rc.1
  run || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.4"
}

test_prerelease_included_when_enabled() {
  export INCLUDE_PRERELEASE=1
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.4" >"$STATE_FILE"
  fixture jason 1.4.4 1.5.0-rc.1
  run || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.5.0-rc.1"
}

test_package_without_stable_falls_back_to_latest() {
  echo newpkg >"$PACKAGES_FILE"
  fixture newpkg null 0.1.0-dev
  run || return 1
  assert_eq "$(cat "$STATE_FILE")" "newpkg 0.1.0-dev"
}

test_failed_telegram_keeps_old_state() {
  export FAKE_TG_FAIL=1
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run && return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.3"
}

test_unknown_package_fails_but_others_processed() {
  printf 'missing\njason\n' >"$PACKAGES_FILE"
  fixture jason 1.4.4
  run && return 1
  grep -q 'failed to fetch missing' "$WORK/err" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.4"
}

test_without_telegram_only_logs() {
  export TELEGRAM_BOT_TOKEN=""
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  assert_eq "$(cat "$FAKE_TG_LOG")" "" || return 1
  grep -q 'NEW jason' "$WORK/out"
}

test_missing_command_fails_early() {
  echo jason >"$PACKAGES_FILE"
  fixture jason 1.4.4
  # PATH with everything needed except jq.
  local cmd
  mkdir "$WORK/bin"
  for cmd in dirname date flock sort mktemp touch mv; do
    ln -s "$(command -v "$cmd")" "$WORK/bin/$cmd"
  done
  PATH="$TESTS_DIR/fake_bin:$WORK/bin" "$BASH" "$SCRIPT" >"$WORK/out" 2>"$WORK/err" && return 1
  grep -q 'required command not found: jq' "$WORK/err" || return 1
  [[ ! -e "$STATE_FILE" ]]
}

test_package_names_are_trimmed() {
  printf '\t jason \t\n  phoenix\t# comment\n \t \n' >"$PACKAGES_FILE"
  fixture jason 1.4.4
  fixture phoenix 1.7.0
  run || return 1
  assert_eq "$(cat "$STATE_FILE")" $'jason 1.4.4\nphoenix 1.7.0'
}

test_inner_whitespace_is_not_removed() {
  printf 'jas on\njason\n' >"$PACKAGES_FILE"
  fixture jason 1.4.4
  run && return 1
  grep -q 'failed to fetch jas on' "$WORK/err" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.4"
}

test_config_example_does_not_override_env() {
  export CONFIG_FILE="$TESTS_DIR/../hex_pm_notification.conf.example"
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  grep -q 'chat_id=42' "$FAKE_TG_LOG"
}

test_version_gt() {
  (
    set +e
    # shellcheck source=/dev/null
    source "$SCRIPT"
    local pair rc
    for pair in \
      "1.4.4 1.4.3 0" "1.10.0 1.9.0 0" "2.0.0 1.99.99 0" \
      "1.5.0 1.5.0-rc.1 0" "1.5.0-rc.10 1.5.0-rc.9 0" "1.5.0-rc.1 1.5.0-beta.2 0" \
      "1.5.0-rc.1.1 1.5.0-rc.1 0" "1.5.0-alpha 1.5.0-1 0" "1.4.4+build.2 1.4.3 0" \
      "1.4.3 1.4.4 1" "1.4.4 1.5.0-rc.1 1" "1.5.0-rc.1 1.5.0 1" "1.4.4 1.4.4 1" "1.4.4+b 1.4.4 1"; do
      read -r a b expected <<<"$pair"
      rc=0
      version_gt "$a" "$b" || rc=$?
      if [[ "$expected" == 0 && "$rc" != 0 ]] || [[ "$expected" == 1 && "$rc" != 1 ]]; then
        echo "    version_gt $a $b: rc=$rc, expected $expected"
        return 1
      fi
    done
    rc=0
    version_gt "garbage" "1.0.0" || rc=$?
    ((rc > 1)) || { echo "    garbage: rc=$rc"; return 1; }
  )
}

test_rollback_is_ignored() {
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.5" >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  assert_eq "$(cat "$FAKE_TG_LOG")" "" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.5" || return 1
  grep -q 'IGNORE jason 1.4.4 (older than 1.4.5)' "$WORK/out"
}

test_disabling_prerelease_does_not_notify_downgrade() {
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.5.0-rc.1" >"$STATE_FILE"
  fixture jason 1.4.4 1.5.0-rc.1
  run || return 1
  assert_eq "$(cat "$FAKE_TG_LOG")" "" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.5.0-rc.1" || return 1
  # A stable release after rc is an upgrade.
  fixture jason 1.5.0
  run || return 1
  grep -q 'jason: 1.5.0-rc.1 → 1.5.0' "$FAKE_TG_LOG" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.5.0"
}

test_unparsable_version_still_notifies() {
  echo jason >"$PACKAGES_FILE"
  echo "jason weird" >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  grep -q 'WARN jason: cannot compare weird and 1.4.4' "$WORK/out" || return 1
  grep -q 'jason: weird → 1.4.4' "$FAKE_TG_LOG"
}

test_only_hex_requests_are_retried() {
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  grep -qx -- '--retry' "$FAKE_HEX_LOG" || return 1
  # curl retries after a timeout too, which could deliver a message twice.
  ! grep -qx -- '--retry' "$FAKE_TG_LOG"
}

test_telegram_error_description_is_logged() {
  export FAKE_TG_FAIL=1
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run && return 1
  grep -q 'ERROR: telegram: HTTP 400: Bad Request: chat not found' "$WORK/err" || return 1
  grep -q 'failed to send notification for jason' "$WORK/err"
}

test_state_saved_before_interruption() {
  printf 'jason\nphoenix\n' >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  fixture phoenix 1.7.0
  export FAKE_KILL_ON=phoenix
  # setsid - so that kill -KILL 0 from the fake kills only the script, not the test runner.
  (PATH="$TESTS_DIR/fake_bin:$PATH" setsid --wait "$BASH" "$SCRIPT" >"$WORK/out" 2>"$WORK/err"; exit $?) 2>/dev/null && return 1
  grep -q 'jason: 1.4.3 → 1.4.4' "$FAKE_TG_LOG" || return 1
  # The notification was sent and the version saved - it must not be sent again.
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.4" || return 1
  export FAKE_KILL_ON=""
  : >"$FAKE_TG_LOG"
  run || return 1
  assert_eq "$(cat "$FAKE_TG_LOG")" ""
}

test_temp_state_file_removed_on_failure() {
  echo jason >"$PACKAGES_FILE"
  fixture jason 1.4.4
  # A failing sort - save_state aborts after mktemp.
  mkdir "$WORK/bin"
  printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$WORK/bin/sort"
  chmod +x "$WORK/bin/sort"
  PATH="$TESTS_DIR/fake_bin:$WORK/bin:$PATH" "$BASH" "$SCRIPT" >"$WORK/out" 2>"$WORK/err" && return 1
  assert_eq "$(find "$WORK" -maxdepth 1 -name 'state.txt.*' ! -name '*.lock')" ""
}

test_concurrent_run_is_rejected() {
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  # The first instance blocks inside curl while holding the lock.
  export FAKE_BLOCK_ON=jason
  PATH="$TESTS_DIR/fake_bin:$PATH" "$BASH" "$SCRIPT" >"$WORK/out1" 2>"$WORK/err1" &
  local first=$! i
  for i in {1..200}; do
    grep -q 'packages/jason' "$FAKE_HEX_LOG" && break
    sleep 0.05
  done
  grep -q 'packages/jason' "$FAKE_HEX_LOG" || { touch "$FAKE_RELEASE_FILE"; wait "$first"; return 1; }

  # The second instance must fail immediately without any requests.
  local rc=0
  run || rc=$?
  touch "$FAKE_RELEASE_FILE"
  local first_rc=0
  wait "$first" || first_rc=$?

  assert_eq "$rc" 1 || return 1
  grep -q 'another instance is running' "$WORK/err" || return 1
  assert_eq "$(grep -c 'packages/jason' "$FAKE_HEX_LOG")" 1 || return 1
  # The first instance finishes normally and notifies exactly once.
  assert_eq "$first_rc" 0 || return 1
  assert_eq "$(grep -c 'jason: 1.4.3' "$FAKE_TG_LOG")" 1 || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.4" || return 1

  # Once the lock is released, the next run works again.
  export FAKE_BLOCK_ON=""
  run
}

test_state_last_line_without_newline() {
  echo jason >"$PACKAGES_FILE"
  printf 'jason 1.4.3' >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  grep -q 'NEW jason 1.4.3 -> 1.4.4' "$WORK/out" || return 1
  grep -q 'jason: 1.4.3 → 1.4.4' "$FAKE_TG_LOG"
}

test_state_with_crlf_line_endings() {
  printf 'jason\nphoenix\n' >"$PACKAGES_FILE"
  printf 'jason 1.4.4\r\nphoenix 1.7.0\r\n' >"$STATE_FILE"
  fixture jason 1.4.4
  fixture phoenix 1.7.1
  run || return 1
  ! grep -q 'WARN' "$WORK/out" || return 1
  # Unchanged jason is silent, phoenix gets exactly one normal notification.
  ! grep -q 'jason:' "$FAKE_TG_LOG" || return 1
  grep -q 'phoenix: 1.7.0 → 1.7.1' "$FAKE_TG_LOG" || return 1
  assert_eq "$(cat "$STATE_FILE")" $'jason 1.4.4\nphoenix 1.7.1'
}

test_killed_run_does_not_leave_lock() {
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  # The first run blocks inside curl and gets killed; curl stays alive as an orphan.
  export FAKE_BLOCK_ON=jason
  PATH="$TESTS_DIR/fake_bin:$PATH" "$BASH" "$SCRIPT" >"$WORK/out1" 2>"$WORK/err1" &
  local first=$! i
  for i in {1..200}; do
    grep -q 'packages/jason' "$FAKE_HEX_LOG" && break
    sleep 0.05
  done
  kill -KILL "$first"
  wait "$first" 2>/dev/null

  # The orphaned curl must not hold the lock.
  export FAKE_BLOCK_ON=""
  local rc=0
  run || rc=$?
  touch "$FAKE_RELEASE_FILE"
  assert_eq "$rc" 0 || return 1
  ! grep -q 'another instance is running' "$WORK/err" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.4"
}

test_telegram_works_with_old_curl() {
  # curl < 7.76 (Debian 11, Ubuntu 20.04) does not know --fail-with-body.
  export FAKE_CURL_OLD=1
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run || return 1
  grep -q 'jason: 1.4.3 → 1.4.4' "$FAKE_TG_LOG" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.4"
}

test_telegram_error_description_is_logged_with_old_curl() {
  export FAKE_CURL_OLD=1
  export FAKE_TG_FAIL=1
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run && return 1
  grep -q 'ERROR: telegram: HTTP 400: Bad Request: chat not found' "$WORK/err" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.3"
}

test_telegram_network_failure_keeps_old_state() {
  export FAKE_TG_NETWORK_FAIL=1
  echo jason >"$PACKAGES_FILE"
  echo "jason 1.4.3" >"$STATE_FILE"
  fixture jason 1.4.4
  run && return 1
  grep -q 'failed to send notification for jason' "$WORK/err" || return 1
  assert_eq "$(cat "$STATE_FILE")" "jason 1.4.3"
}

if (($# > 0)); then
  tests=("$@")
else
  mapfile -t tests < <(declare -F | awk '{print $3}' | grep '^test_')
fi

for t in "${tests[@]}"; do
  setup
  if ( "$t" ); then
    echo "ok   $t"
    ((passed++))
  else
    echo "FAIL $t"
    sed 's/^/    stderr: /' "$WORK/err" 2>/dev/null
    ((failed++))
  fi
  teardown
done

echo "passed: $passed, failed: $failed"
((failed == 0))
