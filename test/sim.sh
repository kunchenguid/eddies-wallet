#!/usr/bin/env bash
#
# test/sim.sh - run a command against a headless iOS simulator that is ALWAYS torn down.
#
# This is the canonical, headless-only path for Eddie's Wallet iOS build/test work. It owns
# the full simulator lifecycle (see test/sim-lib.sh): it reaps devices orphaned by
# previously-dead runs, creates one device in the DEFAULT CoreSimulator set under a unique
# run-scoped NAME, boots it, runs your command headlessly with a bounded timeout, and shuts
# down + deletes that source and its exact XCTest clone on success, failure, timeout, EXIT,
# INT, and TERM. It only ever acts on devices whose name carries the run-scoped prefix, so
# it never touches your own simulators and never shuts down a concurrent run's devices.
# Deleting the device takes the app containers installed on it with it, so no build or test
# run can strand a container in a simulator's cache either.
#
# The device lives in the DEFAULT set on purpose: xcodebuild's device manager only
# enumerates the default set, so a device created in a custom `--set` cannot be targeted by
# `-destination 'platform=iOS Simulator,id=<udid>'` at all. Isolation comes from the unique
# device name, not a private device set.
#
# Do NOT call `xcrun simctl boot` or `xcodebuild test`/`build` against a simulator by hand,
# and do NOT `open -a Simulator` for build/test - hand-made devices are what left booted
# Eddie's Wallet simulators running for days. Use this wrapper instead. CI routes simulator
# work through it, and lifecycle tests plus code review enforce that boundary. Running the
# app manually from Xcode for the sequences in EddysWallet/README.md is unaffected: this
# wrapper never touches a device it did not create.
#
# Usage:
#   test/sim.sh [--device <name|id>]... [--runtime <ver|id>] -- <command...>
#
# `--device` may be repeated to give an ordered preference list; the first installed device
# type wins. Inside <command...>, the literal token {{UDID}} is replaced with the booted
# device's UDID, and the environment variables SIM_UDID and SIM_DEVICE_NAME are exported.
#
# Examples:
#   # Headless unit and UI tests on the run-scoped device:
#   test/sim.sh -- xcodebuild test -project EddysWallet.xcodeproj -scheme EddysWallet \
#       -destination "platform=iOS Simulator,id={{UDID}}"
#
#   # A quick compile check on a specific device family:
#   test/sim.sh --device "iPhone 17" -- \
#     xcodebuild build -project EddysWallet.xcodeproj -scheme EddysWallet \
#       -destination "platform=iOS Simulator,id={{UDID}}"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test/sim-lib.sh
source "$SCRIPT_DIR/sim-lib.sh"

usage() {
    sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

DEVICES=()
RUNTIME="$SIM_DEFAULT_RUNTIME"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)  DEVICES+=( "$2" ); shift 2 ;;
        --runtime) RUNTIME="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --)        shift; break ;;
        *)         echo "sim.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "sim.sh: no command given after --" >&2
    usage >&2
    exit 2
fi

(( ${#DEVICES[@]} > 0 )) || DEVICES=("${SIM_DEFAULT_DEVICES[@]}")

# Refuse GUI launch commands before creating anything. Screenshot capture uses `simctl io`
# against this wrapper's headless device instead.
sim_require_headless_command "$@"

# On a trapped signal or command timeout, stop the full process group then let the EXIT trap
# tear down the source device and all XCTest clones.
CMD_PID=""
CMD_LSTART=""
WATCHDOG_PID=""
WATCHDOG_LSTART=""
TIMEOUT_MARKER="${TMPDIR:-/tmp}/eddies-wallet-sim-timeout.$$.$RANDOM"
COMMAND_TIMEOUT_SECS="${EW_SIM_COMMAND_TIMEOUT_SECS:-1800}"
CLEANED=0
_sim_require_nonnegative_integer "EW_SIM_COMMAND_TIMEOUT_SECS" "$COMMAND_TIMEOUT_SECS"

finish_cleanup() {
    [[ "$CLEANED" == "1" ]] && return 0
    trap '' INT TERM
    if [[ -n "$WATCHDOG_PID" && -n "$WATCHDOG_LSTART" ]]; then
        sim_stop_command "$WATCHDOG_PID" 1 "$WATCHDOG_LSTART"
        WATCHDOG_PID=""
        WATCHDOG_LSTART=""
    fi
    local cleanup_status=0
    sim_cleanup_run || cleanup_status=$?
    rm -f "$TIMEOUT_MARKER"
    [[ "$cleanup_status" == "0" ]] && CLEANED=1
    return "$cleanup_status"
}

# shellcheck disable=SC2329  # invoked indirectly from the INT/TERM traps below
on_signal() {
    local signum="$1"
    trap - INT TERM  # avoid re-entry while we shut down
    if [[ -n "$WATCHDOG_PID" && -n "$WATCHDOG_LSTART" ]]; then
        sim_stop_command "$WATCHDOG_PID" 1 "$WATCHDOG_LSTART"
        WATCHDOG_PID=""
        WATCHDOG_LSTART=""
    fi
    [[ -n "$CMD_PID" && -n "$CMD_LSTART" ]] && sim_stop_command "$CMD_PID" "${EW_SIM_TERM_TIMEOUT_SECS:-20}" "$CMD_LSTART"
    CMD_PID=""
    CMD_LSTART=""
    exit $(( 128 + signum ))
}
trap 'status=$?; cleanup_status=0; finish_cleanup || cleanup_status=$?; if [[ "$status" == "0" && "$cleanup_status" != "0" ]]; then status="$cleanup_status"; fi; exit "$status"' EXIT
trap 'on_signal 2' INT
trap 'on_signal 15' TERM

# Reap orphans from previously-dead runs before we create anything new.
sim_reap_stale

set -m
sim_set_up "$RUNTIME" "${DEVICES[@]}"

# Substitute the {{UDID}} token in each argument so callers can place it inside an already
# composed -destination string.
cmd=()
for arg in "$@"; do
    cmd+=( "${arg//\{\{UDID\}\}/$SIM_UDID}" )
done
sim_require_managed_simulator_command "${cmd[@]}"

# The shared scheme marks unit tests parallelizable. Override that for managed simulator
# runs: one worker is enough here and prevents an unbounded fan-out of cloned devices.
if sim_is_xcodebuild_test_command "${cmd[@]}"; then
    cmd+=( -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 )
fi
# Run the command in its own process group. The watchdog turns a hard timeout into the same
# cleanup path as an interrupt; zero disables the timeout for an explicitly managed caller.
# The watchdog is killed as a process group: killing only the subshell leaves its sleep
# child alive holding the inherited stdout, which blocks any caller that piped our output.
status=0
command_pgid=""
_sim_defer_owned_spawn_signals
"${cmd[@]}" &
CMD_PID=$!
CMD_LSTART="$(_sim_proc_lstart "$CMD_PID")"
command_pgid="$CMD_PID"
_sim_resume_owned_spawn_signals
if (( COMMAND_TIMEOUT_SECS > 0 )); then
    watchdog_command_pid="$CMD_PID"
    watchdog_command_lstart="$CMD_LSTART"
    _sim_defer_owned_spawn_signals
    (
        sleep "$COMMAND_TIMEOUT_SECS"
        if _sim_command_identity_matches "$watchdog_command_pid" "$watchdog_command_lstart"; then
            printf '%s\n' "timed out after ${COMMAND_TIMEOUT_SECS}s" > "$TIMEOUT_MARKER"
            sim_stop_command "$watchdog_command_pid" "${EW_SIM_TERM_TIMEOUT_SECS:-20}" "$watchdog_command_lstart"
        fi
    ) &
    WATCHDOG_PID=$!
    WATCHDOG_LSTART="$(_sim_proc_lstart "$WATCHDOG_PID")"
    _sim_resume_owned_spawn_signals
fi
wait "$command_pgid" || status=$?
CMD_PID=""
CMD_LSTART=""
_sim_record_owned_simulator_apps "$command_pgid"
if [[ -n "$WATCHDOG_PID" && -n "$WATCHDOG_LSTART" ]]; then
    sim_stop_command "$WATCHDOG_PID" 1 "$WATCHDOG_LSTART"
    WATCHDOG_PID=""
    WATCHDOG_LSTART=""
fi
if [[ -f "$TIMEOUT_MARKER" ]]; then
    sim_log "command $(cat "$TIMEOUT_MARKER")"
    status=124
fi

# Tear down now; the EXIT trap remains a backstop for every earlier failure.
cleanup_status=0
finish_cleanup || cleanup_status=$?
if [[ "$cleanup_status" == "0" ]]; then
    trap - EXIT INT TERM
fi
if [[ "$status" == "0" && "$cleanup_status" != "0" ]]; then
    status="$cleanup_status"
fi

exit "$status"
