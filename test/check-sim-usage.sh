#!/usr/bin/env bash
#
# test/check-sim-usage.sh - guard against scripts and workflows that leak iOS simulators.
#
# Tracked shell scripts and GitHub workflows must drive simulators THROUGH the sanctioned
# lifecycle (test/sim.sh / test/sim-lib.sh). The wrapper creates its device in the DEFAULT
# CoreSimulator set under a unique run-scoped NAME (xcodebuild can only target default-set
# devices), and only ever acts on devices carrying that prefix - so operating in the shared
# default set is safe. This guard catches the leak patterns that left booted Eddie's Wallet
# simulators running for days:
#
#   * booting a simulator by hand (`xcrun simctl boot`) outside the wrapper, with no
#     teardown, and
#   * direct simulator `xcodebuild build`/`test` commands outside the wrapper, and
#   * `open -a Simulator` (the simulator GUI is forbidden for validation and capture), and
#   * unscoped `simctl shutdown/delete/erase all` (no `--set`), which nukes EVERY device in
#     the user's DEFAULT set. The wrapper only ever deletes one explicit UDID, never `all`;
#     the `--set`-scoped `all` form is carved out here because it cannot touch the user's
#     default devices (and a regression to it is separately caught by the unit test).
#
# Non-simulator destinations (`generic/platform=iOS`, used by the Release compile-only
# regression and the release archive) are untouched: they never create a device.
#
# Run locally or in CI (ubuntu is fine - it only inspects text). Exits non-zero on a
# violation. Optional path arguments let a caller inspect specific files; with no arguments
# the guard scans every tracked shell script and workflow.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Scripts allowed to boot/own simulators directly - they ARE the lifecycle.
ALLOW_WRAPPED=(
    "test/sim.sh"
    "test/sim-lib.sh"
    "test/sim-lib-test.sh"
    "test/check-sim-usage.sh"
)

is_wrapped() {
    local f="$1" a
    f="${f#"$ROOT_DIR"/}"
    f="${f#./}"
    for a in "${ALLOW_WRAPPED[@]}"; do
        [[ "$f" == "$a" ]] && return 0
    done
    return 1
}

status=0
flag() {
    status=1
    printf 'sim-usage: %s\n' "$*" >&2
}

# Match a pattern on non-comment lines of a file; prints "file:line: text" hits.
hits() {
    local pattern="$1" file="$2"
    grep -nE "$pattern" "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

# Print shell command fragments that directly invoke xcodebuild for a simulator build or
# test. Backslash-continued commands are joined before matching, then shell separators and
# function bodies are split so prefixes such as `time` and `nice` do not hide the command.
direct_xcodebuild_hits() {
    local file="$1"
    awk '
        function inspect_fragment(fragment, line,   probe) {
            if (fragment !~ /(^|[^[:alnum:]_.-])xcodebuild([[:space:]]|$)/) return
            if (fragment !~ /(^|[[:space:]])(build|build-for-testing|test|test-without-building)([[:space:]]|$)/) return
            if (fragment !~ /-destination([[:space:]]|=)/) return
            # `generic/platform=...` resolves to an SDK, never a device, so it cannot
            # leak one. Drop it before deciding whether a real device is targeted.
            probe = fragment
            gsub(/generic\/platform[[:space:]]*=[[:space:]]*iOS([[:space:]]+Simulator)?/, "", probe)
            # A simulator destination is either spelled out, or given as a bare device id.
            if (probe !~ /platform[[:space:]]*=[[:space:]]*iOS[[:space:]]+Simulator/ \
                && probe !~ /-destination[[:space:]=]+[^[:alnum:]]?id=/) return
            if (fragment ~ /(^|[^[:alnum:]_.-])sim[.]sh[^;{}()]*[[:space:]]--[[:space:]]+.*xcodebuild/) return
            print line ":" fragment
        }
        function inspect_command() {
            count = split(command, fragments, /[;{}()]|&&|\|\|/)
            for (i = 1; i <= count; i++) inspect_fragment(fragments[i], start_line)
        }
        {
            line = $0
            if (command == "") start_line = NR
            if (command == "" && line ~ /^[[:space:]]*#/) next
            continued = line ~ /\\[[:space:]]*$/
            sub(/\\[[:space:]]*$/, "", line)
            command = command " " line
            if (!continued) {
                inspect_command()
                command = ""
            }
        }
        END {
            if (command != "") inspect_command()
        }
    ' "$file" 2>/dev/null || true
}

gui_launch_hits() {
    local file="$1" shell_quote='["'"'"']?' bundle_target
    bundle_target="${shell_quote}([^[:space:]]*/)?Simulator[.]app(/[^[:space:]]*)?${shell_quote}"
    {
        hits "(^|[^[:alnum:]_.-])open([[:space:]]+[^[:space:]]+)*[[:space:]]+(-a[[:space:]]+${shell_quote}Simulator([.]app)?${shell_quote}|-a${shell_quote}Simulator([.]app)?${shell_quote}|-b[[:space:]]+${shell_quote}com\\.apple\\.iphonesimulator${shell_quote}|-b${shell_quote}com\\.apple\\.iphonesimulator${shell_quote})([[:space:]]|$)" "$file"
        hits "(^|[^[:alnum:]_.-])open([[:space:]]+[^[:space:]]+)*[[:space:]]+${bundle_target}([[:space:]]|$)" "$file"
    } | sort -u
}

scan_files() {
    if [[ "$#" -gt 0 ]]; then
        printf '%s\n' "$@"
    else
        git ls-files '*.sh' '.github/workflows/*.yml' '.github/workflows/*.yaml'
    fi
}

while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    # Unscoped `simctl <verb> all` (no `--set`) wipes the user's DEFAULT device set - never
    # allowed in any file, including the lifecycle scripts. The wrapper acts on one explicit
    # UDID instead. A `--set`-scoped `all` is carved out (it cannot reach the default set).
    all_hits="$(hits 'simctl[^#]*\b(shutdown|delete|erase)[[:space:]]+all\b' "$f" | grep -v -- '--set' || true)"
    if [[ -n "$all_hits" ]]; then
        flag "$f: unscoped 'simctl ... all' wipes the default device set - delete one UDID instead:"
        printf '  %s\n' "$all_hits" >&2
    fi

    is_wrapped "$f" && continue

    xcodebuild_hits="$(direct_xcodebuild_hits "$f")"
    if [[ -n "$xcodebuild_hits" ]]; then
        flag "$f: direct simulator xcodebuild build/test - route it through test/sim.sh:"
        printf '  %s\n' "$xcodebuild_hits" >&2
    fi

    boot_hits="$(hits 'xcrun[[:space:]]+simctl[[:space:]]+boot' "$f")"
    if [[ -n "$boot_hits" ]]; then
        flag "$f: bare 'xcrun simctl boot' - use test/sim.sh instead:"
        printf '  %s\n' "$boot_hits" >&2
    fi

    gui_hits="$(gui_launch_hits "$f")"
    if [[ -n "$gui_hits" ]]; then
        flag "$f: 'open ... Simulator' is forbidden for build/test:"
        printf '  %s\n' "$gui_hits" >&2
    fi
done < <(scan_files "$@")

if [[ "$status" == "0" ]]; then
    echo "sim-usage: ok (no out-of-lifecycle simulator calls in tracked scripts and workflows)"
fi
exit "$status"
