#!/usr/bin/env bash
#
# test/check-sim-usage.sh - exercise the public simulator wrapper end to end with a
# synthetic CoreSimulator command boundary. No simulator is created by this test.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eddies-wallet-sim-usage.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

BIN_DIR="$TEST_DIR/bin"
RUNS_DIR="$TEST_DIR/runs"
XCRUN_LOG="$TEST_DIR/xcrun.log"
COMMAND_LOG="$TEST_DIR/command.log"
mkdir -p "$BIN_DIR" "$RUNS_DIR"
: > "$XCRUN_LOG"
: > "$COMMAND_LOG"

cat > "$BIN_DIR/xcrun" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$EW_SIM_TEST_XCRUN_LOG"
case "$*" in
    "simctl list runtimes available")
        printf '%s\n' 'iOS 26.4 (26.4 - test) - com.apple.CoreSimulator.SimRuntime.iOS-26-4'
        ;;
    "simctl list devicetypes")
        printf '%s\n' 'iPhone 17 Pro (com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)'
        ;;
    simctl\ create\ *)
        printf '%s\n' '11111111-2222-3333-4444-555555555555'
        ;;
    "simctl list devices")
        ;;
    *)
        ;;
esac
STUB

cat > "$BIN_DIR/xcodebuild" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$EW_SIM_TEST_COMMAND_LOG"
STUB
chmod +x "$BIN_DIR/xcrun" "$BIN_DIR/xcodebuild"

common_env=(
    "PATH=$BIN_DIR:$PATH"
    "EW_SIM_RUNS_DIR=$RUNS_DIR"
    "EW_XCTEST_DEVICE_SET=$TEST_DIR/xctest-devices"
    "EW_SIM_TEST_XCRUN_LOG=$XCRUN_LOG"
    "EW_SIM_TEST_COMMAND_LOG=$COMMAND_LOG"
    "EW_SIM_COMMAND_TIMEOUT_SECS=10"
    "EW_SIM_CLONE_SETTLE_DELAY_SECS=0"
)

# A GUI command must be rejected before setup, without even querying CoreSimulator.
if env "${common_env[@]}" "$ROOT_DIR/test/sim.sh" -- open -a Simulator \
    >"$TEST_DIR/gui.stdout" 2>"$TEST_DIR/gui.stderr"; then
    echo "sim-usage: wrapper accepted a Simulator.app launch" >&2
    exit 1
fi
if [[ -s "$XCRUN_LOG" ]]; then
    echo "sim-usage: rejected GUI command still touched CoreSimulator" >&2
    exit 1
fi
printf '%s\n' "PASS headless boundary rejects Simulator.app before device setup"

# A child may mutate only the source UDID allocated to this invocation.
if env "${common_env[@]}" "$ROOT_DIR/test/sim.sh" -- /usr/bin/xcrun simctl boot OTHER-UDID \
    >"$TEST_DIR/foreign.stdout" 2>"$TEST_DIR/foreign.stderr"; then
    echo "sim-usage: wrapper accepted a foreign simulator boot" >&2
    exit 1
fi
if grep -qF 'simctl boot OTHER-UDID' "$XCRUN_LOG"; then
    echo "sim-usage: wrapper executed a foreign simulator boot" >&2
    exit 1
fi
grep -qF 'simctl delete 11111111-2222-3333-4444-555555555555' "$XCRUN_LOG" || {
    echo "sim-usage: rejected child command did not tear down its source device" >&2
    exit 1
}
if find "$RUNS_DIR" -mindepth 1 -print -quit | grep -q .; then
    echo "sim-usage: rejected child command left a run marker behind" >&2
    exit 1
fi
printf '%s\n' "PASS managed boundary rejects a foreign simulator UDID and tears down its own device"

: > "$XCRUN_LOG"
: > "$COMMAND_LOG"
env "${common_env[@]}" "$ROOT_DIR/test/sim.sh" -- xcodebuild test \
    -destination 'platform=iOS Simulator,id={{UDID}}'

command_line="$(head -n 1 "$COMMAND_LOG")"
[[ "$command_line" == *"platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555"* ]] || {
    echo "sim-usage: wrapper did not substitute its run-scoped UDID" >&2
    exit 1
}
[[ "$command_line" == *"-parallel-testing-enabled NO"* \
    && "$command_line" == *"-maximum-parallel-testing-workers 1"* ]] || {
    echo "sim-usage: wrapped test did not enforce one worker" >&2
    exit 1
}
grep -qF 'simctl boot 11111111-2222-3333-4444-555555555555' "$XCRUN_LOG" || {
    echo "sim-usage: wrapper did not boot its exact run device" >&2
    exit 1
}
grep -qF 'simctl delete 11111111-2222-3333-4444-555555555555' "$XCRUN_LOG" || {
    echo "sim-usage: wrapper did not delete its exact run device" >&2
    exit 1
}
if grep -Eq 'simctl (shutdown|delete|erase) all' "$XCRUN_LOG"; then
    echo "sim-usage: wrapper targeted all simulators" >&2
    exit 1
fi
if find "$RUNS_DIR" -mindepth 1 -print -quit | grep -q .; then
    echo "sim-usage: wrapper left a run marker behind" >&2
    exit 1
fi

printf '%s\n' "PASS wrapper substituted its unique UDID and forced one test worker"
printf '%s\n' "PASS wrapper booted and deleted only its exact run-scoped device"
echo "sim-usage: ALL PASS"
