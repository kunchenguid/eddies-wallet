#!/usr/bin/env bash
#
# test/check-sim-usage.sh - exercise the sanctioned simulator command interface end to end.
set -euo pipefail
trap - DEBUG

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eddies-wallet-sim-usage.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

BIN_DIR="$TEST_DIR/bin"
RUNS_DIR="$TEST_DIR/runs"
XCTEST_DIR="$TEST_DIR/xctest-devices"
XCRUN_LOG="$TEST_DIR/xcrun.log"
COMMAND_LOG="$TEST_DIR/command.log"
mkdir -p "$BIN_DIR" "$RUNS_DIR"
: > "$XCRUN_LOG"
: > "$COMMAND_LOG"

cat > "$BIN_DIR/xcrun" <<'EOF'
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
EOF

cat > "$BIN_DIR/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$EW_SIM_TEST_COMMAND_LOG"
printf '%s\n' "${EW_SIM_TEST_WRAPPED:-}" >> "$EW_SIM_TEST_COMMAND_LOG"
EOF
cat > "$BIN_DIR/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$EW_SIM_TEST_COMMAND_LOG"
EOF
chmod +x "$BIN_DIR/xcrun" "$BIN_DIR/xcodebuild" "$BIN_DIR/open"

POLICY_BIN="$ROOT_DIR/test/sim-policy-bin"
policy_env=(
    "PATH=$POLICY_BIN:$PATH"
    "EW_SIM_POLICY_REAL_XCRUN=$BIN_DIR/xcrun"
    "EW_SIM_POLICY_REAL_XCODEBUILD=$BIN_DIR/xcodebuild"
    "EW_SIM_POLICY_REAL_OPEN=$BIN_DIR/open"
    "EW_SIM_TEST_XCRUN_LOG=$XCRUN_LOG"
    "EW_SIM_TEST_COMMAND_LOG=$COMMAND_LOG"
)
if env "${policy_env[@]}" xcrun simctl boot UNWRAPPED-UDID >/dev/null 2>&1; then
    echo "sim-usage: command policy accepted an unwrapped simulator boot" >&2
    exit 1
fi
if env "${policy_env[@]}" xcodebuild test -destination 'platform=iOS Simulator,id=UNWRAPPED-UDID' >/dev/null 2>&1; then
    echo "sim-usage: command policy accepted unwrapped simulator xcodebuild" >&2
    exit 1
fi
if env "${policy_env[@]}" open -a Simulator >/dev/null 2>&1; then
    echo "sim-usage: command policy accepted a Simulator.app launch" >&2
    exit 1
fi
env "${policy_env[@]}" EW_SIM_POLICY_WRAPPED=1 xcrun simctl boot WRAPPED-UDID
env "${policy_env[@]}" EW_SIM_POLICY_WRAPPED=1 xcodebuild test \
    -destination 'platform=iOS Simulator,id=WRAPPED-UDID'
env "${policy_env[@]}" xcodebuild build -destination 'generic/platform=iOS'

BASH_POLICY="$ROOT_DIR/test/sim-policy.sh"
assert_policy_probe() {
    local entrypoint="$1" probe="$2" status=0
    env BASH_ENV="$BASH_POLICY" EW_SIM_POLICY_PROBE="$probe" \
        bash "$entrypoint" >"$TEST_DIR/probe.stdout" 2>"$TEST_DIR/probe.stderr" || status=$?
    if [[ "$status" != "92" ]]; then
        echo "sim-usage: policy probe '$probe' escaped $entrypoint (status $status)" >&2
        exit 1
    fi
}

for probe in absolute-xcrun command-p-xcrun function-absolute-xcrun \
    subshell-command-p-xcrun absolute-xcodebuild absolute-open; do
    assert_policy_probe "$ROOT_DIR/test/sim.sh" "$probe"
done

while IFS= read -r -d '' script; do
    assert_policy_probe "$ROOT_DIR/$script" function-absolute-xcrun
done < <(git -C "$ROOT_DIR" ls-files -z '*.sh')

WORKFLOW_ENTRYPOINTS="$TEST_DIR/workflow-entrypoints"
mkdir -p "$WORKFLOW_ENTRYPOINTS"
ruby - "$ROOT_DIR" "$WORKFLOW_ENTRYPOINTS" > "$TEST_DIR/workflow-entrypoints.log" <<'RUBY'
require "fileutils"
require "psych"

root, output_dir = ARGV
index = 0
Dir.glob(File.join(root, ".github/workflows/*.{yml,yaml}")).sort.each do |workflow_path|
  workflow = Psych.safe_load(File.read(workflow_path), aliases: true) || {}
  (workflow["jobs"] || {}).each do |job_name, job|
    run_steps = (job["steps"] || []).each_with_index.select do |step, _step_index|
      step.is_a?(Hash) && step["run"].is_a?(String)
    end
    next if run_steps.empty?

    effective_env = (workflow["env"] || {}).merge(job["env"] || {})
    unless effective_env["BASH_ENV"] == "${{ github.workspace }}/test/sim-policy.sh"
      abort "#{workflow_path}: job #{job_name} has run entrypoints outside the simulator policy boundary"
    end

    run_steps.each do |step, step_index|
      index += 1
      path = File.join(output_dir, format("%03d.sh", index))
      File.write(path, step["run"])
      puts [path, File.basename(workflow_path), job_name, step_index].join("\t")
    end
  end
end
abort "no workflow run entrypoints found" if index.zero?
RUBY

while IFS=$'\t' read -r entrypoint _workflow _job _step; do
    assert_policy_probe "$entrypoint" subshell-command-p-xcrun
done < "$TEST_DIR/workflow-entrypoints.log"

: > "$XCRUN_LOG"
: > "$COMMAND_LOG"

common_env=(
    "PATH=$BIN_DIR:$PATH"
    "EW_SIM_RUNS_DIR=$RUNS_DIR"
    "EW_XCTEST_DEVICE_SET=$XCTEST_DIR"
    "EW_SIM_TEST_XCRUN_LOG=$XCRUN_LOG"
    "EW_SIM_TEST_COMMAND_LOG=$COMMAND_LOG"
    "EW_SIM_COMMAND_TIMEOUT_SECS=10"
)

if env "${common_env[@]}" "$ROOT_DIR/test/sim.sh" -- env EW_SIM_TEST_WRAPPED=yes open -a Simulator \
    >"$TEST_DIR/gui.stdout" 2>"$TEST_DIR/gui.stderr"; then
    echo "sim-usage: wrapper accepted a Simulator.app launch" >&2
    exit 1
fi
if [[ -s "$XCRUN_LOG" ]]; then
    echo "sim-usage: rejected GUI command still touched CoreSimulator" >&2
    exit 1
fi

env "${common_env[@]}" "$ROOT_DIR/test/sim.sh" -- \
    env EW_SIM_TEST_WRAPPED=yes xcodebuild test \
    -destination 'platform=iOS Simulator,id={{UDID}}'

command_line="$(head -n 1 "$COMMAND_LOG")"
wrapped_value="$(tail -n 1 "$COMMAND_LOG")"
[[ "$command_line" == *"platform=iOS Simulator,id=11111111-2222-3333-4444-555555555555"* ]] || {
    echo "sim-usage: wrapper did not substitute its run-scoped UDID" >&2
    exit 1
}
[[ "$command_line" == *"-parallel-testing-enabled NO"* \
    && "$command_line" == *"-maximum-parallel-testing-workers 1"* ]] || {
    echo "sim-usage: wrapped xcodebuild test did not enforce one worker" >&2
    exit 1
}
[[ "$wrapped_value" == "yes" ]] || {
    echo "sim-usage: command wrapper environment was not preserved" >&2
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

echo "sim-usage: ok (sanctioned wrapper stayed headless and tore down its run)"
