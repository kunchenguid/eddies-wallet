#!/usr/bin/env bash
#
# test/sim-lib-test.sh - headless unit tests for the simulator lifecycle decision logic.
#
# This is the safety-critical proof: the pre-run reaper must delete the run-scoped devices
# owned by dead/SIGKILLed runs and spare those owned by a live concurrent run, while never
# touching a device whose name lacks our prefix (the user's own devices, Xcode defaults). It
# runs in milliseconds against SYNTHETIC marker dirs (fake pidfiles + recorded UDIDs) and a
# STUBBED `xcrun` that fakes the default-set device listing and records simctl calls, so it
# boots nothing and is safe to run anywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sandbox the shared base so the real one is never touched.
TEST_BASE="$(mktemp -d "${TMPDIR:-/tmp}/eddies-wallet-sim-test.XXXXXX")"
export EW_SIM_RUNS_DIR="$TEST_BASE"
export EW_SIM_REAP_GRACE_SECS=120
trap 'rm -rf "$TEST_BASE"' EXIT

# shellcheck source=test/sim-lib.sh
source "$SCRIPT_DIR/sim-lib.sh"

fail=0
ok()  { printf 'PASS %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*" >&2; fail=1; }
assert_exists()  { if [[ -e "$TEST_BASE/$1" ]]; then ok "$2"; else bad "$2 (dir missing)"; fi; }
assert_absent()  { if [[ -e "$TEST_BASE/$1" ]]; then bad "$2 (dir still present)"; else ok "$2"; fi; }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', expected '$2')"; fi; }

# ---- xcrun stub -----------------------------------------------------------
# Records every simctl call (except the noisy runtimes/devicetypes probes) to a log, and
# fakes the two device listings (default set, and a custom --set for XCTest clones) plus
# optional delete failures.
xcrun_calls="$TEST_BASE/.xcrun"
xcrun_successful_deletes="$TEST_BASE/.xcrun-successful-deletes"
xctest_list_count="$TEST_BASE/.xctest-list-count"
: > "$xcrun_calls"
: > "$xcrun_successful_deletes"
printf '0\n' > "$xctest_list_count"
XCRUN_DELETE_FAIL=0
XCRUN_LIST_FAIL=0
XCRUN_AUTO_REMOVE_DELETED=0
XCTEST_LIST_DELAY_UNTIL=0
SIMCTL_DEFAULT_DEVICE_LIST=""   # what `simctl list devices` (default set) returns
SIMCTL_DEVICE_TYPE_LIST="== Device Types ==
iPhone 17 (com.apple.CoreSimulator.SimDeviceType.iPhone-17)
iPhone 17 Pro (com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
iPad (A16) (com.apple.CoreSimulator.SimDeviceType.iPad-A16)"
XCTEST_DEVICE_LIST=""           # what `simctl --set <set> list devices` returns
XCTEST_DEVICE_LIST_AFTER_SOURCE_DELETE=""
filter_successfully_deleted() {
    local contents="$1" deleted_udid
    while IFS= read -r deleted_udid; do
        [[ -n "$deleted_udid" ]] || continue
        contents="$(grep -vF "$deleted_udid" <<< "$contents" || true)"
    done < "$xcrun_successful_deletes"
    printf '%s\n' "$contents"
}
xcrun() {
    if [[ "$1" == "simctl" && "$2" == "list" && "$3" == "runtimes" && "$4" == "available" ]]; then
        cat <<'EOF'
== Runtimes ==
iOS 26.1 (26.1 - 23B5064e) - com.apple.CoreSimulator.SimRuntime.iOS-26-1
iOS 26.4 (26.4 - 23E5226g) - com.apple.CoreSimulator.SimRuntime.iOS-26-4
EOF
        return 0
    fi
    if [[ "$1" == "simctl" && "$2" == "list" && "$3" == "devicetypes" ]]; then
        printf '%s\n' "$SIMCTL_DEVICE_TYPE_LIST"
        return 0
    fi
    printf '%s\n' "$*" >> "$xcrun_calls"
    # Default-set device listing (no --set).
    if [[ "$1" == "simctl" && "$2" == "list" && "$3" == "devices" ]]; then
        [[ "${XCRUN_LIST_FAIL:-0}" == "1" ]] && return 1
        if [[ "$XCRUN_AUTO_REMOVE_DELETED" == "1" ]]; then
            filter_successfully_deleted "$SIMCTL_DEFAULT_DEVICE_LIST"
        else
            printf '%s\n' "$SIMCTL_DEFAULT_DEVICE_LIST"
        fi
        return 0
    fi
    # Custom-set (XCTest) device listing, optionally delayed to reproduce Xcode publishing
    # a clone after the first post-xcodebuild cleanup probe.
    if [[ "$1" == "simctl" && "$2" == "--set" && "$4" == "list" && "$5" == "devices" ]]; then
        local list_count
        list_count="$(cat "$xctest_list_count")"
        list_count=$(( list_count + 1 ))
        printf '%s\n' "$list_count" > "$xctest_list_count"
        if (( list_count < XCTEST_LIST_DELAY_UNTIL )); then
            return 0
        fi
        if [[ "$XCRUN_AUTO_REMOVE_DELETED" == "1" ]]; then
            filter_successfully_deleted "$XCTEST_DEVICE_LIST"
        else
            printf '%s\n' "$XCTEST_DEVICE_LIST"
        fi
        return 0
    fi
    if [[ "${XCRUN_DELETE_FAIL:-0}" == "1" ]]; then
        [[ "$1" == "simctl" && "$2" == "delete" ]] && return 1
        [[ "$1" == "simctl" && "$2" == "--set" && "$4" == "delete" ]] && return 1
    fi
    if [[ "$XCRUN_AUTO_REMOVE_DELETED" == "1" ]]; then
        if [[ "$1" == "simctl" && "$2" == "delete" ]]; then
            printf '%s\n' "$3" >> "$xcrun_successful_deletes"
            if [[ "$3" == "${SIM_UDID:-}" && -n "$XCTEST_DEVICE_LIST_AFTER_SOURCE_DELETE" ]]; then
                XCTEST_DEVICE_LIST="$XCTEST_DEVICE_LIST_AFTER_SOURCE_DELETE"
                XCTEST_DEVICE_LIST_AFTER_SOURCE_DELETE=""
            fi
        elif [[ "$1" == "simctl" && "$2" == "--set" && "$4" == "delete" ]]; then
            printf '%s\n' "$5" >> "$xcrun_successful_deletes"
        fi
    fi
    return 0
}
CAT_RACE_PATH=""
cat() {
    if [[ -n "$CAT_RACE_PATH" && "${1:-}" == "$CAT_RACE_PATH" ]]; then
        rm -f "$1"
        return 1
    fi
    command cat "$@"
}

logged()           { grep -qF "$1" "$xcrun_calls"; }
assert_logged()     { if logged "$1"; then ok "$2"; else bad "$2 (expected in xcrun log: '$1')"; fi; }
assert_not_logged() { if logged "$1"; then bad "$2 (unexpected in xcrun log: '$1')"; else ok "$2"; fi; }

# A definitely-dead pid: a child we start and reap, so the OS has freed it.
( exit 0 ) & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
LIVE_PID=$$
LIVE_LSTART="$(_sim_proc_lstart "$LIVE_PID")"
LIVE_IDENTITY="$(_sim_process_identity_token "$LIVE_PID")"
DEAD_IDENTITY="00"
STALE_IDENTITY="ff"

# ===========================================================================
# _sim_delete_device: deletes one UDID, treats already-gone as success, real failure as fail
# ===========================================================================
: > "$xcrun_calls"
XCRUN_DELETE_FAIL=0
if _sim_delete_device "DEAD-BEEF-0001"; then ok "_sim_delete_device succeeds on a normal delete"; else bad "_sim_delete_device failed on a normal delete"; fi
assert_logged "simctl shutdown DEAD-BEEF-0001" "_sim_delete_device shuts the device down first"
assert_logged "simctl delete DEAD-BEEF-0001"   "_sim_delete_device deletes by explicit UDID"
assert_not_logged "delete all"                 "_sim_delete_device never deletes all"

: > "$xcrun_calls"
XCRUN_DELETE_FAIL=1
SIMCTL_DEFAULT_DEVICE_LIST=""   # delete 'fails' but the device is not present -> already gone -> success
if _sim_delete_device "DEAD-BEEF-0002"; then ok "_sim_delete_device treats an already-gone device as success"; else bad "_sim_delete_device failed on an already-gone device"; fi

XCRUN_DELETE_FAIL=1
SIMCTL_DEFAULT_DEVICE_LIST="    Phantom (DEAD-BEEF-0003) (Shutdown)"   # delete fails AND it is still listed -> real failure
if _sim_delete_device "DEAD-BEEF-0003"; then bad "_sim_delete_device reported success on a real delete failure"; else ok "_sim_delete_device reports a real delete failure"; fi

XCRUN_LIST_FAIL=1
if _sim_delete_device "DEAD-BEEF-0004"; then bad "_sim_delete_device reported success when delete and list both fail"; else ok "_sim_delete_device reports failure when delete cannot be verified"; fi
XCRUN_LIST_FAIL=0
XCRUN_DELETE_FAIL=0
SIMCTL_DEFAULT_DEVICE_LIST=""

# ===========================================================================
# _sim_finalize_run / _sim_reap_run: delete recorded UDID + remove the marker dir
# ===========================================================================
mkdir -p "$TEST_BASE/run.fin_ok"
printf '%s\n' "FIN-0001" > "$TEST_BASE/run.fin_ok/device.udid"
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_ok"; then ok "_sim_reap_run succeeds after delete"; else bad "_sim_reap_run failed after delete"; fi
assert_logged "simctl delete FIN-0001" "_sim_reap_run deletes the recorded UDID"
assert_absent "run.fin_ok" "_sim_reap_run removes a cleaned marker dir"

mkdir -p "$TEST_BASE/run.fin_fail"
printf '%s\n' "FIN-0002" > "$TEST_BASE/run.fin_fail/device.udid"
XCRUN_DELETE_FAIL=1
SIMCTL_DEFAULT_DEVICE_LIST="    Phantom (FIN-0002) (Shutdown)"
if _sim_reap_run "$TEST_BASE/run.fin_fail"; then bad "_sim_reap_run succeeded after delete failure"; else ok "_sim_reap_run reports delete failure"; fi
assert_exists "run.fin_fail" "_sim_reap_run keeps a failed marker dir for retry"
XCRUN_DELETE_FAIL=0
SIMCTL_DEFAULT_DEVICE_LIST=""
rm -rf "$TEST_BASE/run.fin_fail"

UD_MARKER_USER="33330000-0000-0000-0000-000000000001"
UD_MARKER_PREFIXED="33330000-0000-0000-0000-000000000002"
UD_MARKER_VERIFY="33330000-0000-0000-0000-000000000003"
UD_MARKER_CASE="33330000-0000-0000-0000-00000000000A"

mkdir -p "$TEST_BASE/run.fin_user"
printf '%s\n' "$UD_MARKER_USER" > "$TEST_BASE/run.fin_user/device.udid"
SIMCTL_DEFAULT_DEVICE_LIST="    iPhone 17 Pro ($UD_MARKER_USER) (Shutdown)"
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_user"; then ok "_sim_reap_run tolerates a stale marker pointing at a non-run-scoped device"; else bad "_sim_reap_run failed on a non-run-scoped recorded UDID"; fi
assert_not_logged "simctl delete $UD_MARKER_USER" "_sim_reap_run does not delete a non-run-scoped recorded UDID"
assert_absent "run.fin_user" "_sim_reap_run removes a stale non-run-scoped marker dir"

mkdir -p "$TEST_BASE/run.fin_user_case"
printf '%s\n' "33330000-0000-0000-0000-00000000000a" > "$TEST_BASE/run.fin_user_case/device.udid"
SIMCTL_DEFAULT_DEVICE_LIST="    iPad Pro ($UD_MARKER_CASE) (Shutdown)"
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_user_case"; then ok "_sim_reap_run verifies recorded UDIDs case-insensitively"; else bad "_sim_reap_run failed on a differently-cased recorded UDID"; fi
assert_not_logged "simctl delete 33330000-0000-0000-0000-00000000000a" "_sim_reap_run does not delete a non-run-scoped recorded UDID with different casing"
assert_absent "run.fin_user_case" "_sim_reap_run removes a differently-cased stale non-run-scoped marker dir"

mkdir -p "$TEST_BASE/run.fin_prefixed"
printf '%s\n' "$UD_MARKER_PREFIXED" > "$TEST_BASE/run.fin_prefixed/device.udid"
SIMCTL_DEFAULT_DEVICE_LIST="    ${SIM_DEVICE_NAME_PREFIX}-${DEAD_PID}-777 ($UD_MARKER_PREFIXED) (Shutdown)"
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_prefixed"; then ok "_sim_reap_run allows a recorded UDID with a run-scoped device name"; else bad "_sim_reap_run rejected a run-scoped recorded UDID"; fi
assert_logged "simctl delete $UD_MARKER_PREFIXED" "_sim_reap_run deletes a run-scoped recorded UDID"
assert_absent "run.fin_prefixed" "_sim_reap_run removes a run-scoped marker dir"

UD_MARKER_CUSTOM="33330000-0000-0000-0000-000000000004"
CUSTOM_DEVICE_NAME="Custom-simrun-${DEAD_PID}-888"
mkdir -p "$TEST_BASE/run.fin_custom_prefix"
printf '%s\n' "$UD_MARKER_CUSTOM" > "$TEST_BASE/run.fin_custom_prefix/device.udid"
printf '%s\n' "$CUSTOM_DEVICE_NAME" > "$TEST_BASE/run.fin_custom_prefix/device.name"
SIMCTL_DEFAULT_DEVICE_LIST="    $CUSTOM_DEVICE_NAME ($UD_MARKER_CUSTOM) (Shutdown)"
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_custom_prefix"; then ok "_sim_reap_run honors the creating run's recorded device name"; else bad "_sim_reap_run rejected a recorded custom-prefix device name"; fi
assert_logged "simctl delete $UD_MARKER_CUSTOM" "_sim_reap_run deletes an orphan created with a different prefix"
assert_absent "run.fin_custom_prefix" "_sim_reap_run removes a custom-prefix marker dir"

UD_MARKER_CUSTOM_NAME_ONLY="33330000-0000-0000-0000-000000000005"
CUSTOM_NAME_ONLY="Custom-simrun-${DEAD_PID}-889"
mkdir -p "$TEST_BASE/run.fin_custom_name_only"
printf '%s\n' "$CUSTOM_NAME_ONLY" > "$TEST_BASE/run.fin_custom_name_only/device.name"
SIMCTL_DEFAULT_DEVICE_LIST="    $CUSTOM_NAME_ONLY ($UD_MARKER_CUSTOM_NAME_ONLY) (Shutdown)"
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_custom_name_only"; then ok "_sim_reap_run resolves a custom-prefix device created before its UDID marker"; else bad "_sim_reap_run failed to resolve a custom-prefix name-only marker"; fi
assert_logged "simctl delete $UD_MARKER_CUSTOM_NAME_ONLY" "_sim_reap_run deletes the exact device resolved from a name-only marker"
assert_absent "run.fin_custom_name_only" "_sim_reap_run removes a resolved name-only marker dir"

mkdir -p "$TEST_BASE/run.fin_custom_name_list_fail"
printf '%s\n' "$CUSTOM_NAME_ONLY" > "$TEST_BASE/run.fin_custom_name_list_fail/device.name"
XCRUN_LIST_FAIL=1
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_custom_name_list_fail"; then bad "_sim_reap_run discarded a name-only marker when device lookup failed"; else ok "_sim_reap_run fails closed when a name-only marker cannot be resolved"; fi
assert_exists "run.fin_custom_name_list_fail" "_sim_reap_run keeps an unresolved name-only marker for retry"
XCRUN_LIST_FAIL=0
rm -rf "$TEST_BASE/run.fin_custom_name_list_fail"

mkdir -p "$TEST_BASE/run.fin_custom_name_pending"
printf '%s\n' "$CUSTOM_NAME_ONLY" > "$TEST_BASE/run.fin_custom_name_pending/device.name"
printf '%s\n' pending > "$TEST_BASE/run.fin_custom_name_pending/create.state"
printf '%s\n' "$LIVE_PID" > "$TEST_BASE/run.fin_custom_name_pending/create.pid"
printf '%s\n' "$LIVE_LSTART" > "$TEST_BASE/run.fin_custom_name_pending/create.lstart"
SIMCTL_DEFAULT_DEVICE_LIST=""
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_custom_name_pending"; then bad "_sim_reap_run finalized a name-only marker before creation settled"; else ok "_sim_reap_run defers a live name-only creation"; fi
assert_exists "run.fin_custom_name_pending" "_sim_reap_run preserves a marker while custom-prefix creation runs"
assert_not_logged "simctl delete $UD_MARKER_CUSTOM_NAME_ONLY" "_sim_reap_run does not invent a deletion before the device appears"
SIMCTL_DEFAULT_DEVICE_LIST="    $CUSTOM_NAME_ONLY ($UD_MARKER_CUSTOM_NAME_ONLY) (Shutdown)"
if _sim_reap_run "$TEST_BASE/run.fin_custom_name_pending"; then ok "_sim_reap_run retries a settled custom-prefix creation"; else bad "_sim_reap_run did not retry a settled custom-prefix creation"; fi
assert_logged "simctl delete $UD_MARKER_CUSTOM_NAME_ONLY" "_sim_reap_run deletes a custom-prefix device after delayed publication"
assert_absent "run.fin_custom_name_pending" "_sim_reap_run removes the marker after delayed creation settles"

mkdir -p "$TEST_BASE/run.fin_custom_name_failed"
printf '%s\n' "$CUSTOM_NAME_ONLY" > "$TEST_BASE/run.fin_custom_name_failed/device.name"
printf '%s\n' settled > "$TEST_BASE/run.fin_custom_name_failed/create.state"
SIMCTL_DEFAULT_DEVICE_LIST=""
if _sim_reap_run "$TEST_BASE/run.fin_custom_name_failed"; then ok "_sim_reap_run finalizes a settled failed creation"; else bad "_sim_reap_run retained a settled failed creation"; fi
assert_absent "run.fin_custom_name_failed" "_sim_reap_run removes a settled failed-creation marker"

mkdir -p "$TEST_BASE/run.fin_custom_name_dead_create"
printf '%s\n' "$CUSTOM_NAME_ONLY" > "$TEST_BASE/run.fin_custom_name_dead_create/device.name"
printf '%s\n' pending > "$TEST_BASE/run.fin_custom_name_dead_create/create.state"
printf '%s\n' "$DEAD_PID" > "$TEST_BASE/run.fin_custom_name_dead_create/create.pid"
printf '%s\n' whenever > "$TEST_BASE/run.fin_custom_name_dead_create/create.lstart"
if _sim_reap_run "$TEST_BASE/run.fin_custom_name_dead_create"; then ok "_sim_reap_run finalizes a dead failed creation"; else bad "_sim_reap_run retained a dead failed creation"; fi
assert_absent "run.fin_custom_name_dead_create" "_sim_reap_run removes a dead failed-creation marker"

mkdir -p "$TEST_BASE/run.fin_custom_name_publish_race"
printf '%s\n' "$CUSTOM_NAME_ONLY" > "$TEST_BASE/run.fin_custom_name_publish_race/device.name"
printf '%s\n' pending > "$TEST_BASE/run.fin_custom_name_publish_race/create.state"
printf '%s\n' "$DEAD_PID" > "$TEST_BASE/run.fin_custom_name_publish_race/create.pid"
printf '%s\n' whenever > "$TEST_BASE/run.fin_custom_name_publish_race/create.lstart"
resolve_count_file="$TEST_BASE/.resolve-count"
printf '%s\n' 0 > "$resolve_count_file"
original_name_resolver="$(declare -f _sim_default_device_udid_for_name)"
_sim_default_device_udid_for_name() {
    local count
    count="$(cat "$resolve_count_file")"
    count=$(( count + 1 ))
    printf '%s\n' "$count" > "$resolve_count_file"
    [[ "$count" == "1" ]] && return 1
    printf '%s\n' "$UD_MARKER_CUSTOM_NAME_ONLY"
}
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_custom_name_publish_race"; then ok "_sim_reap_run resolves a device published as its creator exits"; else bad "_sim_reap_run lost a device published after creator liveness changed"; fi
assert_logged "simctl delete $UD_MARKER_CUSTOM_NAME_ONLY" "_sim_reap_run deletes a device published during creator exit"
assert_absent "run.fin_custom_name_publish_race" "_sim_reap_run removes the marker after the creator publication race"
eval "$original_name_resolver"

mkdir -p "$TEST_BASE/run.fin_verify_fail"
printf '%s\n' "$UD_MARKER_VERIFY" > "$TEST_BASE/run.fin_verify_fail/device.udid"
XCRUN_LIST_FAIL=1
: > "$xcrun_calls"
if _sim_reap_run "$TEST_BASE/run.fin_verify_fail"; then bad "_sim_reap_run succeeded when recorded UDID ownership could not be verified"; else ok "_sim_reap_run fails closed when recorded UDID ownership cannot be verified"; fi
assert_not_logged "simctl delete $UD_MARKER_VERIFY" "_sim_reap_run does not delete before ownership verification"
assert_exists "run.fin_verify_fail" "_sim_reap_run keeps an unverified marker dir for retry"
XCRUN_LIST_FAIL=0
SIMCTL_DEFAULT_DEVICE_LIST=""
rm -rf "$TEST_BASE/run.fin_verify_fail"

# ===========================================================================
# sim_reap_stale: the heart of the SIGKILL coverage
# ===========================================================================
mk_set() { # name pid lstart udid  -> a marker dir with a liveness marker + recorded UDID
    local d="$TEST_BASE/$1"
    mkdir -p "$d"
    printf '%s\n' "$2" > "$d/owner.pid"
    printf '%s\n' "$3" > "$d/owner.lstart"
    if [[ -n "${4:-}" ]]; then printf '%s\n' "$4" > "$d/device.udid"; fi
    return 0
}

# Distinct UDIDs so deletions can be asserted precisely.
UD_DEAD="11110000-0000-0000-0000-000000000001"
UD_LIVE="11110000-0000-0000-0000-000000000002"
UD_REUSED="11110000-0000-0000-0000-000000000003"
UD_OLD="11110000-0000-0000-0000-000000000004"
UD_OWN="11110000-0000-0000-0000-000000000005"
UD_COVERED="11110000-0000-0000-0000-000000000006"
# Pass-2 (name-based, marker lost) UDIDs.
UD_P2_DEAD="22220000-0000-0000-0000-000000000001"
UD_P2_LIVE="22220000-0000-0000-0000-000000000002"
UD_P2_USER="22220000-0000-0000-0000-000000000003"
UD_P2_REUSED="22220000-0000-0000-0000-000000000004"

# ---- pass-1 marker-dir fixtures -------------------------------------------
# 1. owner dead -> reap (clean/SIGKILLed run that never tore down)
mk_set "run.dead" "$DEAD_PID" "whenever" "$UD_DEAD"
# 2. owner live + matching start time -> spare (a live concurrent run)
mk_set "run.live" "$LIVE_PID" "$LIVE_LSTART" "$UD_LIVE"
# 3. owner pid alive but start time differs -> PID recycled -> owner dead -> reap
mk_set "run.reused" "$LIVE_PID" "Mon Jan  1 00:00:00 2000" "$UD_REUSED"
# 4. no marker yet, fresh dir -> spare (sibling mid-init inside the grace window)
mkdir -p "$TEST_BASE/run.nomarker_fresh"
# 5. no marker, dir older than the grace window -> reap (stale partial)
mkdir -p "$TEST_BASE/run.nomarker_old"
printf '%s\n' "$UD_OLD" > "$TEST_BASE/run.nomarker_old/device.udid"
touch -t 202001010000 "$TEST_BASE/run.nomarker_old"
# 6. not a run.* dir -> ignored entirely
mkdir -p "$TEST_BASE/notrun_dir"
# 7. a live run that owns UD_COVERED, even though the device's NAME embeds a dead pid
mk_set "run.covered" "$LIVE_PID" "$LIVE_LSTART" "$UD_COVERED"
# 8. our OWN run dir, even with a dead-looking owner -> never reaped (teardown owns it)
mk_set "run.self" "$DEAD_PID" "whenever" "$UD_OWN"
SIM_RUN_DIR="$TEST_BASE/run.self"
SIM_UDID="$UD_OWN"

# ---- pass-2 default-set device fixtures (no live marker unless noted) ------
SIMCTL_DEFAULT_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    ${SIM_DEVICE_NAME_PREFIX}-${DEAD_PID}-${DEAD_IDENTITY}-111 ($UD_P2_DEAD) (Shutdown)
    ${SIM_DEVICE_NAME_PREFIX}-${LIVE_PID}-${LIVE_IDENTITY}-222 ($UD_P2_LIVE) (Booted)
    iPhone 17 Pro ($UD_P2_USER) (Shutdown)
    ${SIM_DEVICE_NAME_PREFIX}-${LIVE_PID}-${STALE_IDENTITY}-333 ($UD_P2_REUSED) (Booted)
    ${SIM_DEVICE_NAME_PREFIX}-${DEAD_PID}-${DEAD_IDENTITY}-444 ($UD_COVERED) (Shutdown)
    ${SIM_DEVICE_NAME_PREFIX}-${DEAD_PID}-${DEAD_IDENTITY}-555 ($UD_OWN) (Booted)"

: > "$xcrun_calls"
sim_reap_stale

# pass 1
assert_logged "simctl delete $UD_DEAD"       "reaps a dead-owner run's device"
assert_absent "run.dead"                      "removes a dead-owner marker dir"
assert_not_logged "simctl delete $UD_LIVE"    "spares a live concurrent run's device"
assert_exists "run.live"                      "keeps a live concurrent run's marker dir"
assert_logged "simctl delete $UD_REUSED"      "reaps a recycled-PID (lstart mismatch) run"
assert_absent "run.reused"                    "removes a recycled-PID marker dir"
assert_exists "run.nomarker_fresh"            "spares a fresh markerless dir (grace window)"
assert_logged "simctl delete $UD_OLD"         "reaps a stale markerless dir past grace"
assert_absent "run.nomarker_old"              "removes a stale markerless dir"
assert_exists "run.self"                      "never reaps the current run's own marker"
assert_not_logged "simctl delete $UD_OWN"     "never deletes the current run's own device"
assert_exists "notrun_dir"                    "ignores non-run.* directories"

# pass 2 (name-based fallback for devices whose marker was lost)
assert_logged "simctl delete $UD_P2_DEAD"     "reaps a prefixed device whose name pid is dead and marker is gone"
assert_not_logged "simctl delete $UD_P2_LIVE" "spares a prefixed device whose embedded owner identity is alive"
assert_not_logged "simctl delete $UD_P2_USER" "never touches a non-prefixed (user) device"
assert_logged "simctl delete $UD_P2_REUSED" "reaps a markerless device after its embedded owner PID is reused"
assert_not_logged "simctl delete $UD_COVERED" "spares a device a live marker still owns despite a dead-pid name"

tool_word="simctl"
assert_not_logged "$tool_word delete all"     "reaper never deletes all in the default set"
assert_not_logged "$tool_word shutdown all"   "reaper never shuts down all in the default set"

RACE_DIR="$TEST_BASE/run.covered_race"
mk_set "run.covered_race" "$LIVE_PID" "$LIVE_LSTART" "RACE-0001"
SIMCTL_DEFAULT_DEVICE_LIST=""
: > "$xcrun_calls"
CAT_RACE_PATH="$RACE_DIR/device.udid"
if sim_reap_stale; then ok "sim_reap_stale tolerates a raced-away covered UDID file"; else bad "sim_reap_stale failed on a raced-away covered UDID file"; fi
CAT_RACE_PATH=""
assert_exists "run.covered_race"              "keeps a live marker after a covered UDID race"
assert_not_logged "simctl delete RACE-0001"   "does not delete a raced-away covered UDID"

# ===========================================================================
# _sim_owner_alive direct checks
# ===========================================================================
SIM_RUN_DIR=""  # clear so the current-run guard does not interfere with the probes below
SIM_UDID=""
mk_set "probe.live" "$LIVE_PID" "$LIVE_LSTART"
mk_set "probe.dead" "$DEAD_PID" "whenever"
if _sim_owner_alive "$TEST_BASE/probe.live"; then ok "_sim_owner_alive true for live pid+lstart"; else bad "_sim_owner_alive false for live pid+lstart"; fi
if _sim_owner_alive "$TEST_BASE/probe.dead"; then bad "_sim_owner_alive true for dead pid"; else ok "_sim_owner_alive false for dead pid"; fi

# ===========================================================================
# runtime and device-type resolution
# ===========================================================================
assert_eq "$(_sim_resolve_runtime "26.4")" "com.apple.CoreSimulator.SimRuntime.iOS-26-4" "runtime resolver returns one exact match"
assert_eq "$(_sim_resolve_runtime "25.0")" "com.apple.CoreSimulator.SimRuntime.iOS-26-4" "runtime resolver falls back to newest iOS"

assert_eq "$(_sim_resolve_preferred_device_type "iPhone 17 Pro" "iPhone 17" 2>/dev/null)" \
    "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" "device resolver takes the first installed preference"
assert_eq "$(_sim_resolve_preferred_device_type "iPhone 99 Ultra" "iPhone 17" 2>/dev/null)" \
    "com.apple.CoreSimulator.SimDeviceType.iPhone-17" "device resolver falls back to the next installed preference"
if _sim_resolve_preferred_device_type "iPhone 99 Ultra" "iPhone 98" >/dev/null 2>&1; then
    bad "device resolver accepted a fully uninstalled preference list"
else
    ok "device resolver fails when no preference is installed"
fi

# ===========================================================================
# Headless command guard and hard source-device cap
# ===========================================================================
if sim_require_headless_command xcodebuild test; then ok "headless guard accepts CLI xcodebuild"; else bad "headless guard rejected CLI xcodebuild"; fi
policy_debug_active=0
if [[ "$(trap -p DEBUG)" == *"_sim_policy_check_command"* ]]; then
    policy_debug_active=1
    trap - DEBUG
fi
if sim_require_headless_command open -a Simulator; then bad "headless guard accepted Simulator.app launch"; else ok "headless guard rejects Simulator.app launch"; fi
if sim_require_headless_command /usr/bin/open -a Simulator; then bad "headless guard accepted Simulator.app launch through an absolute open path"; else ok "headless guard rejects Simulator.app launch through an absolute open path"; fi
if sim_require_headless_command open -W -a Simulator; then bad "headless guard accepted Simulator.app launch with open options"; else ok "headless guard rejects Simulator.app launch with open options"; fi
if sim_require_headless_command sh -c 'open -a Simulator'; then bad "headless guard accepted a shell command payload"; else ok "headless guard rejects a shell command payload"; fi
if sim_require_headless_command env EW_CAPTURE=1 open -a Simulator; then bad "headless guard accepted a wrapped Simulator.app launch"; else ok "headless guard rejects a wrapped Simulator.app launch"; fi
if sim_require_headless_command env '-Sopen -a Simulator'; then bad "headless guard accepted an attached env split-string payload"; else ok "headless guard rejects attached env split-string payloads"; fi
if sim_require_headless_command env -P /usr/bin open -a Simulator; then bad "headless guard accepted a Simulator.app launch after env -P"; else ok "headless guard consumes env -P and rejects the wrapped launch"; fi
if sim_require_headless_command env -P/usr/bin open -a Simulator; then bad "headless guard accepted a Simulator.app launch after attached env -P"; else ok "headless guard consumes attached env -P and rejects the wrapped launch"; fi
if [[ "$policy_debug_active" == "1" ]]; then
    trap _sim_policy_check_command DEBUG
fi

original_visible_process_probe="$(declare -f _sim_visible_simulator_app_processes)"
visible_process_snapshot=""
_sim_visible_simulator_app_processes() { printf '%s' "$visible_process_snapshot"; }
kill_calls="$TEST_BASE/.kill"
: > "$kill_calls"
kill() {
    printf '%s\n' "$*" >> "$kill_calls"
    [[ "${1:-}" == "-0" ]] && return 1
    return 0
}
visible_process_snapshot="49771 /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator -CurrentDeviceUDID 64AC0F39-22F2-428E-BD90-335AC1D0BB26"
visible_process_snapshot+=$'\n49772 /Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator -CurrentDeviceUDID 64AC0F39-22F2-428E-BD90-335AC1D0BB26'
SIM_UDID="64AC0F39-22F2-428E-BD90-335AC1D0BB26"
_SIM_OWNED_SIMULATOR_APP_IDENTITIES=""
simulator_process_lstart="Mon Mar 16 10:11:12 2026"
ps() {
    case "$*" in
        "-o pgid= -p 49771") printf ' 70001\n' ;;
        "-o pgid= -p 49772") printf ' 70002\n' ;;
        "-o lstart= -p 49771"|"-o lstart= -p 49772") printf '%s\n' "$simulator_process_lstart" ;;
    esac
}
_sim_record_owned_simulator_apps 70001
if _sim_reject_run_simulator_app; then bad "cleanup accepted an owned Simulator.app process for its run UDID"; else ok "cleanup rejects an owned Simulator.app process for its run UDID"; fi
if grep -qF -- "-TERM 49771" "$kill_calls" && ! grep -qF -- "49772" "$kill_calls"; then ok "cleanup terminates only the Simulator.app PID positively owned by the command group"; else bad "cleanup signaled a Simulator.app PID it did not own"; fi
: > "$kill_calls"
simulator_process_lstart="Tue Mar 17 10:11:12 2026"
if _sim_reject_run_simulator_app; then ok "cleanup ignores a reused PID for a user-launched Simulator.app"; else bad "cleanup claimed a reused Simulator.app PID"; fi
assert_eq "$(wc -l < "$kill_calls" | tr -d ' ')" "0" "cleanup never signals a Simulator.app process after its owned PID is reused"
_SIM_OWNED_SIMULATOR_APP_IDENTITIES=""
if _sim_reject_run_simulator_app; then ok "cleanup ignores a user-launched Simulator.app targeting the run device"; else bad "cleanup claimed an unowned Simulator.app targeting the run device"; fi
assert_eq "$(wc -l < "$kill_calls" | tr -d ' ')" "0" "cleanup never signals a Simulator.app process without positive launch ownership"
unset -f ps
unset -f kill
SIM_UDID=""
eval "$original_visible_process_probe"

policy_debug_active=0
if [[ "$(trap -p DEBUG)" == *"_sim_policy_check_command"* ]]; then
    policy_debug_active=1
    trap - DEBUG
fi
SIM_UDID="64AC0F39-22F2-428E-BD90-335AC1D0BB26"
if sim_require_managed_simulator_command /usr/bin/xcrun simctl boot OTHER-UDID; then bad "managed command guard accepted a foreign absolute simulator boot"; else ok "managed command guard rejects foreign absolute simulator boot"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun --run simctl boot OTHER-UDID; then bad "managed command guard accepted an option-dispatched simulator boot"; else ok "managed command guard normalizes xcrun lifecycle dispatch"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl boot "$SIM_UDID"; then ok "managed command guard accepts its run-scoped simulator boot"; else bad "managed command guard rejected its run-scoped simulator boot"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl rename OTHER-UDID Renamed; then bad "managed command guard accepted a foreign simulator rename"; else ok "managed command guard rejects foreign simulator rename"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl rename "$SIM_UDID" Renamed; then ok "managed command guard accepts its run-scoped simulator rename"; else bad "managed command guard rejected its run-scoped simulator rename"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl delete "$SIM_UDID" OTHER-UDID; then bad "managed command guard accepted deletion containing a foreign simulator"; else ok "managed command guard validates every simulator deletion target"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl --set /tmp/devices create Leaked Device Runtime; then bad "managed command guard accepted simulator creation after a global option"; else ok "managed command guard normalizes simctl global options before lifecycle rejection"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl clone "$SIM_UDID" Leaked; then bad "managed command guard accepted simulator cloning"; else ok "managed command guard rejects simulator cloning"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl list devices; then ok "managed command guard accepts global read-only simulator listing"; else bad "managed command guard rejected global read-only simulator listing"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl addmedia OTHER-UDID photo.jpg; then bad "managed command guard accepted addmedia for a foreign simulator"; else ok "managed command guard rejects addmedia for a foreign simulator"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl addmedia "$SIM_UDID" photo.jpg; then ok "managed command guard accepts addmedia for its run simulator"; else bad "managed command guard rejected run-scoped addmedia"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl privacy OTHER-UDID grant photos; then bad "managed command guard accepted privacy mutation for a foreign simulator"; else ok "managed command guard rejects privacy mutation for a foreign simulator"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl privacy "$SIM_UDID" grant photos; then ok "managed command guard accepts privacy mutation for its run simulator"; else bad "managed command guard rejected run-scoped privacy mutation"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun simctl future-action OTHER-UDID; then bad "managed command guard accepted an unknown simulator action"; else ok "managed command guard fails closed for unknown simulator actions"; fi
if sim_require_managed_simulator_command xcodebuild test; then bad "managed command guard accepted xcodebuild test without a destination"; else ok "managed command guard requires an explicit test destination"; fi
if sim_require_managed_simulator_command xcodebuild test -destination "platform=iOS Simulator,id=$SIM_UDID"; then ok "managed command guard accepts the run-scoped xcodebuild destination"; else bad "managed command guard rejected the run-scoped xcodebuild destination"; fi
if sim_require_managed_simulator_command xcodebuild test -destination "id=$SIM_UDID"; then ok "managed command guard accepts the run-scoped UDID-only destination"; else bad "managed command guard rejected the run-scoped UDID-only destination"; fi
if sim_require_managed_simulator_command xcodebuild test -destination "id=$SIM_UDID" -destination id=OTHER-UDID; then bad "managed command guard accepted a foreign repeated simulator destination"; else ok "managed command guard validates every simulator destination"; fi
if sim_require_managed_simulator_command /usr/bin/xcrun xcodebuild test -destination id=OTHER-UDID; then bad "managed command guard accepted xcrun xcodebuild for a foreign destination"; else ok "managed command guard normalizes xcrun xcodebuild dispatch"; fi
if sim_require_managed_simulator_command xcodebuild test -destination id=OTHER-UDID; then bad "managed command guard accepted a foreign simulator destination"; else ok "managed command guard rejects a foreign simulator destination"; fi
SIM_UDID=""
if [[ "$policy_debug_active" == "1" ]]; then
    trap _sim_policy_check_command DEBUG
fi

if sim_is_xcodebuild_test_command /usr/bin/xcodebuild -scheme EddysWallet test; then ok "detects xcodebuild test for single-worker enforcement"; else bad "did not detect xcodebuild test"; fi
if sim_is_xcodebuild_test_command /usr/bin/xcrun xcodebuild -scheme EddysWallet test; then ok "detects xcrun-dispatched xcodebuild test"; else bad "did not normalize xcrun-dispatched xcodebuild test"; fi
if sim_is_xcodebuild_test_command /usr/bin/xcrun --sdk iphonesimulator xcodebuild test; then ok "detects option-dispatched xcodebuild test"; else bad "did not normalize xcrun options before xcodebuild"; fi
if sim_is_xcodebuild_test_command env EW_CAPTURE=1 /usr/bin/xcodebuild -scheme EddysWallet test; then ok "detects env-wrapped xcodebuild test"; else bad "did not detect env-wrapped xcodebuild test"; fi
if sim_is_xcodebuild_test_command env -P /usr/bin xcodebuild test; then ok "detects xcodebuild test after env -P"; else bad "did not consume env -P before xcodebuild"; fi
if sim_is_xcodebuild_test_command env -P/usr/bin xcodebuild test; then ok "detects xcodebuild test after attached env -P"; else bad "did not consume attached env -P before xcodebuild"; fi
if sim_is_xcodebuild_test_command nice -n 5 time -p /usr/bin/xcodebuild test-without-building; then ok "detects multiply wrapped xcodebuild test"; else bad "did not detect multiply wrapped xcodebuild test"; fi
if sim_is_xcodebuild_test_command /usr/bin/xcodebuild build; then bad "classified xcodebuild build as test"; else ok "does not classify xcodebuild build as test"; fi

owned_signal_pid_file="$TEST_BASE/.owned-signal-pid"
owned_signal_status=0
(
    CMD_PID=""
    trap '[[ -n "$CMD_PID" ]] || exit 99; printf "%s\n" "$CMD_PID" > "$owned_signal_pid_file"; sim_stop_command "$CMD_PID" 1; exit 143' TERM
    _sim_defer_owned_spawn_signals
    bash -c 'kill -TERM "$PPID"; exec sleep 30' &
    sleep 0.1
    CMD_PID=$!
    _sim_resume_owned_spawn_signals
    exit 98
) || owned_signal_status=$?
assert_eq "$owned_signal_status" "143" "deferred TERM reaches the owner after child PID publication"
if [[ -s "$owned_signal_pid_file" ]] && ! kill -0 "$(cat "$owned_signal_pid_file")" 2>/dev/null; then
    ok "deferred TERM stops the published owned child"
else
    bad "deferred TERM left the published owned child running"
fi

original_proc_lstart="$(declare -f _sim_proc_lstart)"
stale_signal_calls="$TEST_BASE/.stale-signal-calls"
: > "$stale_signal_calls"
_sim_proc_lstart() { printf '%s\n' "Tue Mar 17 10:11:12 2026"; }
kill() { printf '%s\n' "$*" >> "$stale_signal_calls"; }
sim_stop_command 49771 0 "Mon Mar 16 10:11:12 2026"
assert_eq "$(wc -l < "$stale_signal_calls" | tr -d ' ')" "0" "command teardown never signals a reused PID or process group"
unset -f kill
eval "$original_proc_lstart"

SIM_MAX_SOURCE_DEVICES=1
_SIM_SOURCE_CREATE_ATTEMPTS=0
if _sim_claim_source_device_slot; then ok "first source-device creation claim is allowed"; else bad "first source-device creation claim was rejected"; fi
if _sim_claim_source_device_slot; then bad "source-device hard cap allowed a second creation"; else ok "source-device hard cap refuses a second creation"; fi

# ===========================================================================
# XCTest clone cleanup (settles late clones, caps creation, never targets `all`)
# ===========================================================================
sleep() { :; }
XCTEST_DEVICE_SET="$TEST_BASE/xctest-devices"
mkdir -p "$XCTEST_DEVICE_SET"
SIM_OWNS_TEARDOWN=1
SIM_DEVICE_NAME="EddiesWallet-test"
SIM_UDID="11111111-1111-1111-1111-111111111111"
OWN_CLONE="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
OTHER_CLONE="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
UDID_CLONE="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
UNOWNED_CLONE="DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"
reset_clone_stub() {
    : > "$xcrun_calls"
    : > "$xcrun_successful_deletes"
    printf '0\n' > "$xctest_list_count"
    XCRUN_AUTO_REMOVE_DELETED=1
    XCRUN_DELETE_FAIL=0
    XCTEST_LIST_DELAY_UNTIL=0
    XCTEST_DEVICE_LIST_AFTER_SOURCE_DELETE=""
    _sim_reset_xctest_clone_tracking
}

SIM_MAX_XCTEST_CLONES=2
XCTEST_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    Clone 1 of EddiesWallet-test ($OWN_CLONE) (Shutdown)
    Clone 1 of Other-EddiesWallet ($OTHER_CLONE) (Shutdown)
    Clone 2 of Unknown Source ($UDID_CLONE) (Shutdown) source=$SIM_UDID
    EddiesWallet-test (EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE) (Shutdown)"
reset_clone_stub
sim_cleanup_xctest_clones
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET shutdown $OWN_CLONE" "$xcrun_calls" || true)" "1" "xctest cleanup shuts down this run's named clone"
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET delete $OWN_CLONE" "$xcrun_calls" || true)" "1" "xctest cleanup deletes this run's named clone"
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET shutdown $UDID_CLONE" "$xcrun_calls" || true)" "1" "xctest cleanup shuts down this run's source-UDID clone"
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET delete $UDID_CLONE" "$xcrun_calls" || true)" "1" "xctest cleanup deletes this run's source-UDID clone"
assert_eq "$(grep -cF "$OTHER_CLONE" "$xcrun_calls" || true)" "0" "xctest cleanup ignores another run's clone"
assert_eq "$(grep -cE 'simctl --set .* (shutdown|delete) all' "$xcrun_calls" || true)" "0" "xctest cleanup never targets all clones"

# A caller-owned source is never deleted, but its exact per-test clone is still ephemeral
# and must be removed.
SIM_OWNS_TEARDOWN=0
XCTEST_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    Clone 1 of EddiesWallet-test ($OWN_CLONE) (Shutdown)"
reset_clone_stub
sim_cleanup_xctest_clones
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET delete $OWN_CLONE" "$xcrun_calls" || true)" "1" "xctest cleanup removes a caller-owned source's test clone"
assert_not_logged "simctl delete $SIM_UDID" "xctest cleanup never deletes the caller-owned source"
SIM_OWNS_TEARDOWN=1

# Reproduce the real leak: the first listing is empty, then Xcode publishes a clone after
# xcodebuild exits. The settle window must notice and delete it.
SIM_MAX_XCTEST_CLONES=1
XCTEST_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    Clone 1 of EddiesWallet-test ($OWN_CLONE) (Shutdown)"
reset_clone_stub
XCTEST_LIST_DELAY_UNTIL=2
sim_cleanup_xctest_clones
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET delete $OWN_CLONE" "$xcrun_calls" || true)" "1" "settle window deletes a clone published after the first empty probe"

# More than one unique clone is a hard-cap violation. Cleanup still deletes every owned
# clone before returning failure, and an unowned clone remains untouched.
XCTEST_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    Clone 1 of EddiesWallet-test ($OWN_CLONE) (Shutdown)
    Clone 2 of Unknown Source ($UDID_CLONE) (Shutdown) source=$SIM_UDID
    Clone 1 of Somebody Elses Device ($UNOWNED_CLONE) (Shutdown)"
reset_clone_stub
if sim_cleanup_xctest_clones; then bad "xctest clone hard cap accepted two created clones"; else ok "xctest clone hard cap fails the run after cleanup"; fi
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET delete $OWN_CLONE" "$xcrun_calls" || true)" "1" "hard-cap cleanup deletes the first owned clone"
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET delete $UDID_CLONE" "$xcrun_calls" || true)" "1" "hard-cap cleanup deletes the excess owned clone"
assert_eq "$(grep -cF "$UNOWNED_CLONE" "$xcrun_calls" || true)" "0" "hard-cap cleanup leaves an unowned clone alone"

LATE_SOURCE="77770000-0000-0000-0000-000000000001"
FIRST_PASS_CLONE="77770000-0000-0000-0000-000000000002"
SECOND_PASS_CLONE="77770000-0000-0000-0000-000000000003"
SIM_OWNS_TEARDOWN=1
_SIM_TORN_DOWN=0
SIM_DEVICE_NAME="${SIM_DEVICE_NAME_PREFIX}-${DEAD_PID}-lateclone"
SIM_UDID="$LATE_SOURCE"
SIM_RUN_DIR="$TEST_BASE/run.late_clone"
mkdir -p "$SIM_RUN_DIR"
printf '%s\n' "$SIM_UDID" > "$SIM_RUN_DIR/device.udid"
SIMCTL_DEFAULT_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    $SIM_DEVICE_NAME ($LATE_SOURCE) (Shutdown)"
XCTEST_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    Clone 1 of $SIM_DEVICE_NAME ($FIRST_PASS_CLONE) (Shutdown)"
SIM_MAX_XCTEST_CLONES=1
reset_clone_stub
XCTEST_DEVICE_LIST_AFTER_SOURCE_DELETE="== Devices ==
-- iOS 26.4 --
    Clone 2 of $SIM_DEVICE_NAME ($SECOND_PASS_CLONE) (Shutdown)"
if sim_cleanup_run; then bad "xctest clone hard cap accepted late second clone"; else ok "xctest clone hard cap persists across cleanup passes"; fi
assert_logged "simctl --set $XCTEST_DEVICE_SET delete $FIRST_PASS_CLONE" "late-clone cleanup deletes the first pass clone"
assert_logged "simctl --set $XCTEST_DEVICE_SET delete $SECOND_PASS_CLONE" "late-clone cleanup deletes the second pass clone"
assert_logged "simctl delete $LATE_SOURCE" "late-clone cleanup deletes the run source"
assert_absent "run.late_clone" "late-clone cleanup removes the run marker"
if sim_assert_clean; then ok "late-clone cap failure still leaves zero source or clone devices"; else bad "late-clone cap failure leaked a source or clone device"; fi

# Persistent deletion failures are retried through the bounded settle loop and surfaced.
SIM_DEVICE_NAME="EddiesWallet-test"
SIM_UDID="11111111-1111-1111-1111-111111111111"
XCTEST_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    Clone 1 of EddiesWallet-test ($OWN_CLONE) (Shutdown)"
reset_clone_stub
XCRUN_DELETE_FAIL=1
if sim_cleanup_xctest_clones; then bad "xctest cleanup succeeded after repeated delete failures"; else ok "xctest cleanup reports repeated delete failures"; fi
assert_eq "$(grep -cF "simctl --set $XCTEST_DEVICE_SET delete $OWN_CLONE" "$xcrun_calls" || true)" "$SIM_CLONE_SETTLE_ATTEMPTS" "xctest cleanup retries delete failures through the bounded settle loop"
assert_eq "$(grep -cE 'simctl --set .* delete all' "$xcrun_calls" || true)" "0" "xctest cleanup never retries delete all"
XCRUN_DELETE_FAIL=0

# ===========================================================================
# Partial-failure regression: the shared exit cleanup leaves zero run devices
# ===========================================================================
PARTIAL_SOURCE="99990000-0000-0000-0000-000000000001"
PARTIAL_CLONE="99990000-0000-0000-0000-000000000002"
USER_DEVICE="99990000-0000-0000-0000-000000000003"
SIM_OWNS_TEARDOWN=1
_SIM_TORN_DOWN=0
SIM_DEVICE_NAME="${SIM_DEVICE_NAME_PREFIX}-${DEAD_PID}-partial"
SIM_UDID="$PARTIAL_SOURCE"
SIM_RUN_DIR="$TEST_BASE/run.partial_fail"
mkdir -p "$SIM_RUN_DIR"
printf '%s\n' "$SIM_UDID" > "$SIM_RUN_DIR/device.udid"
SIMCTL_DEFAULT_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    $SIM_DEVICE_NAME ($PARTIAL_SOURCE) (Booted)
    iPhone 17 Pro ($USER_DEVICE) (Shutdown)"
XCTEST_DEVICE_LIST="== Devices ==
-- iOS 26.4 --
    Clone 1 of $SIM_DEVICE_NAME ($PARTIAL_CLONE) (Booted)"
SIM_MAX_XCTEST_CLONES=1
reset_clone_stub
if sim_cleanup_run; then ok "partial-failure exit cleanup succeeds"; else bad "partial-failure exit cleanup reported failure"; fi
assert_logged "simctl shutdown $PARTIAL_SOURCE" "partial-failure cleanup shuts down the run source"
assert_logged "simctl delete $PARTIAL_SOURCE" "partial-failure cleanup deletes the run source"
assert_logged "simctl --set $XCTEST_DEVICE_SET shutdown $PARTIAL_CLONE" "partial-failure cleanup shuts down the run clone"
assert_logged "simctl --set $XCTEST_DEVICE_SET delete $PARTIAL_CLONE" "partial-failure cleanup deletes the run clone"
assert_not_logged "simctl delete $USER_DEVICE" "partial-failure cleanup leaves the user's own device alone"
assert_absent "run.partial_fail" "partial-failure cleanup removes the run marker"
if sim_assert_clean; then ok "partial-failure run leaves zero source or clone devices"; else bad "partial-failure run leaked a source or clone device"; fi

# ===========================================================================
# teardown: deletes only this run's device, idempotent, retries on failure
# ===========================================================================
SIM_OWNS_TEARDOWN=1
_SIM_TORN_DOWN=0
SIM_RUN_DIR="$TEST_BASE/run.teardown"
SIM_UDID="TEARDOWN-0001"
mkdir -p "$SIM_RUN_DIR"
printf '%s\n' "$SIM_UDID" > "$SIM_RUN_DIR/device.udid"
: > "$xcrun_calls"
SIMCTL_DEFAULT_DEVICE_LIST=""
sim_teardown
assert_logged "simctl delete $SIM_UDID" "teardown deletes this run's device by UDID"
assert_absent "run.teardown" "teardown removes the run's own marker dir"
if sim_assert_clean; then ok "assert_clean passes after teardown"; else bad "assert_clean failed after teardown"; fi
sim_teardown  # second call must be a no-op, not an error
ok "teardown is idempotent (second call did not error)"

# teardown failure then retry
_sim_delete_device() { return 1; }   # simulate a persistent device-delete failure
SIM_OWNS_TEARDOWN=1
_SIM_TORN_DOWN=0
SIM_RUN_DIR="$TEST_BASE/run.teardown_fail"
SIM_UDID="TEARDOWN-0002"
mkdir -p "$SIM_RUN_DIR"
printf '%s\n' "$SIM_UDID" > "$SIM_RUN_DIR/device.udid"
if sim_teardown; then bad "teardown succeeded after delete failure"; else ok "teardown reports delete failure"; fi
assert_exists "run.teardown_fail" "teardown keeps a failed run dir for retry"
_sim_delete_device() { return 0; }   # delete now succeeds
sim_teardown
assert_absent "run.teardown_fail" "teardown retries after a failed delete"

# teardown is a no-op when we do not own the device
SIM_OWNS_TEARDOWN=0
_SIM_TORN_DOWN=0
SIM_RUN_DIR="$TEST_BASE/run.notowned"
mkdir -p "$SIM_RUN_DIR"
sim_teardown
assert_exists "run.notowned" "teardown leaves a non-owned device untouched"

# ===========================================================================
# sim_assert_clean: a surviving marker dir OR a surviving device is a leak
# ===========================================================================
SIM_OWNS_TEARDOWN=1
SIM_RUN_DIR="$TEST_BASE/run.leakcheck"
SIM_UDID="LEAK-0001"
rm -rf "$SIM_RUN_DIR"
SIMCTL_DEFAULT_DEVICE_LIST=""
if sim_assert_clean; then ok "assert_clean passes when nothing of this run remains"; else bad "assert_clean failed on a clean run"; fi

mkdir -p "$SIM_RUN_DIR"
if sim_assert_clean; then bad "assert_clean passed with a surviving marker dir"; else ok "assert_clean fails on a surviving marker dir"; fi
rm -rf "$SIM_RUN_DIR"

SIMCTL_DEFAULT_DEVICE_LIST="    ${SIM_DEVICE_NAME_PREFIX}-1-1 (LEAK-0001) (Booted)"
if sim_assert_clean; then bad "assert_clean passed with the device still present"; else ok "assert_clean fails when the device still exists"; fi
SIMCTL_DEFAULT_DEVICE_LIST=""

if [[ "$fail" == "0" ]]; then
    echo "sim-lib-test: ALL PASS"
else
    echo "sim-lib-test: FAILURES" >&2
fi
exit "$fail"
