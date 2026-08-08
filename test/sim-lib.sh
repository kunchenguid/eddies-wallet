# shellcheck shell=bash
#
# test/sim-lib.sh - Eddie's Wallet iOS simulator lifecycle library (source this, do not run it).
#
# The problem this solves: every simulator build/test of this project boots an iPhone
# simulator. Nothing in the repository ever shut those devices down, so hand-made devices
# orphaned on clean exit, on Ctrl-C, and - worst of all - on SIGKILL (which no in-process
# trap can ever catch). Each `xcodebuild test` also strands the app container inside the
# device it ran on. Leaked devices stay Booted for days, burn CPU, and grow the disk.
#
# Important CoreSimulator fact this design is built around: xcodebuild's device manager
# (DVTDeviceManager) only enumerates the DEFAULT CoreSimulator device set. A device created
# in a custom `--set` is invisible to xcodebuild - it is not listed by `-showdestinations`
# AND `-destination 'platform=iOS Simulator,id=<udid>'` fails to resolve it ("Unable to
# find a device matching the provided destination specifier"). So the device MUST live in
# the default set for `xcodebuild` to target it. Isolation therefore cannot come from a
# private device set; it comes from a unique, run-scoped device NAME instead.
#
# The model that fixes the leak, end to end and entirely inside this repository:
#
#   * Run-scoped device NAMING in the DEFAULT set. Each run creates ONE device in the
#     default set with a distinctive, greppable name "<prefix>-<pid>-<rand>" (see
#     SIM_DEVICE_NAME_PREFIX). xcodebuild resolves it by explicit UDID. A tiny per-user
#     marker dir ($HOME/Library/Developer/EddiesWalletSimRuns by default) records the
#     device's UDID plus a liveness marker (owner.pid + owner.lstart) naming the process
#     that owns it. We act ONLY on devices whose name carries our prefix, so the user's own
#     devices and Xcode's defaults are NEVER touched.
#
#   * A pre-run reaper. Before creating anything, delete every run-scoped device whose
#     owning process is no longer alive (dead, SIGKILLed, or PID reused) - found via the
#     marker dirs and, as a belt-and-suspenders backstop, via any prefixed default-set
#     device whose embedded pid is dead even if its marker was lost. This is the ONLY thing
#     that closes the SIGKILL hole, and the run-scoped naming + owner liveness check is what
#     makes it safe under concurrency: a live concurrent run's device has a live owner and
#     is always spared.
#
#   * A hard cap of one source device and one non-parallel XCTest clone per run. Clone
#     cleanup waits through a quiet window because Xcode may publish a clone just after
#     xcodebuild exits. Exceeding the cap fails rather than accumulating more devices.
#
#   * One cleanup path for success, failure, timeout, EXIT, INT, and TERM that shuts down
#     and deletes ONLY this run's source and exact clone UDIDs - never `shutdown all` or
#     `delete all`. Deleting the device takes its app containers with it. SIGKILL still
#     cannot be trapped; the next run's reaper covers it.

# ---------------------------------------------------------------------------
# Configuration (override via environment)
# ---------------------------------------------------------------------------

# Per-user dir that holds one marker dir per run (owner.pid + owner.lstart + the created
# device's UDID). It MUST be a single per-user location shared across all worktrees so the
# reaper can see orphans left by a dead run in a different checkout.
SIM_RUNS_BASE="${EW_SIM_RUNS_DIR:-$HOME/Library/Developer/EddiesWalletSimRuns}"

# Distinctive, greppable prefix for every wrapper-created device in the DEFAULT set. The
# reaper only ever shuts down or deletes devices whose name starts with this prefix, so a
# user's own simulators and Xcode's default devices are never affected. A user is extremely
# unlikely to name a device "<prefix>-<digits>-<digits>" by hand.
SIM_DEVICE_NAME_PREFIX="${EW_SIM_DEVICE_PREFIX:-EddiesWallet-simrun}"

# Default device type and runtime. iOS 26.4 is what the READMEs verify against; fall back to
# the newest installed iOS runtime if 26.4 is absent so the wrapper still works elsewhere.
# SIM_DEFAULT_DEVICES is an ordered preference list: the first installed device type wins.
SIM_DEFAULT_DEVICES=("${EW_SIM_DEVICE:-iPhone 17 Pro}" "iPhone 17")
SIM_DEFAULT_RUNTIME="${EW_SIM_RUNTIME:-26.4}"

# A markerless run dir younger than this many seconds is spared (it may be a sibling run
# mid-init that has not written its marker yet). Dirs WITH a marker are judged purely by
# owner liveness, so this grace only guards the create-then-mark race.
SIM_REAP_GRACE_SECS="${EW_SIM_REAP_GRACE_SECS:-120}"

# Hard lifecycle ceilings. A wrapper invocation may create one source simulator and Xcode
# may create at most one derived XCTest clone. Parallel testing is disabled by the callers,
# and crossing either ceiling fails the run even when cleanup succeeds.
SIM_MAX_SOURCE_DEVICES=1
SIM_MAX_XCTEST_CLONES=1

# XCTest can publish its final clone shortly after xcodebuild exits. Cleanup therefore
# waits for a short quiet window instead of treating the first empty listing as final.
SIM_CLONE_SETTLE_ATTEMPTS="${EW_SIM_CLONE_SETTLE_ATTEMPTS:-10}"
SIM_CLONE_SETTLE_EMPTY_PASSES="${EW_SIM_CLONE_SETTLE_EMPTY_PASSES:-3}"
SIM_CLONE_SETTLE_DELAY_SECS="${EW_SIM_CLONE_SETTLE_DELAY_SECS:-1}"

# Populated by sim_set_up:
SIM_RUN_DIR=""        # this run's marker dir under SIM_RUNS_BASE
SIM_UDID=""           # the created+booted device (in the DEFAULT set)
SIM_DEVICE_NAME=""    # the created device's run-scoped name
SIM_OWNS_TEARDOWN=0   # 1 once we have created a device we are responsible for
_SIM_TORN_DOWN=0      # idempotency guard for sim_teardown
_SIM_SOURCE_CREATE_ATTEMPTS=0
_SIM_XCTEST_CLONE_CAP_EXCEEDED=0
_SIM_XCTEST_SEEN_CLONE_UDIDS=" "
_SIM_XCTEST_SEEN_CLONE_COUNT=0
_SIM_OWNED_SIMULATOR_APP_IDENTITIES=""

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

sim_log() {
    printf 'sim: %s\n' "$*" >&2
}

_sim_reset_xctest_clone_tracking() {
    _SIM_XCTEST_CLONE_CAP_EXCEEDED=0
    _SIM_XCTEST_SEEN_CLONE_UDIDS=" "
    _SIM_XCTEST_SEEN_CLONE_COUNT=0
}

_sim_require_nonnegative_integer() {
    local name="$1" value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        sim_log "$name must be a non-negative integer, got '$value'"
        return 1
    fi
}

_SIM_COMMAND_INDEX=-1
_sim_find_command_index() {
    local -a arguments=("$@")
    local index=0 argument executable
    _SIM_COMMAND_INDEX=-1

    while (( index < ${#arguments[@]} )); do
        argument="${arguments[index]}"
        [[ "$argument" =~ ^[[:alpha:]_][[:alnum:]_]*= ]] && { (( index += 1 )); continue; }
        executable="${argument##*/}"
        case "$executable" in
            command|exec)
                (( index += 1 ))
                while (( index < ${#arguments[@]} )); do
                    argument="${arguments[index]}"
                    [[ "$argument" == "--" ]] && { (( index += 1 )); break; }
                    [[ "$argument" == -* ]] || break
                    (( index += 1 ))
                done
                ;;
            env)
                (( index += 1 ))
                while (( index < ${#arguments[@]} )); do
                    argument="${arguments[index]}"
                    case "$argument" in
                        --) (( index += 1 )); break ;;
                        -u|-C|-P|--unset|--chdir) (( index += 2 )) ;;
                        -S*|--split-string|--split-string=*) return 2 ;;
                        -P*) (( index += 1 )) ;;
                        -*) (( index += 1 )) ;;
                        *)
                            if [[ "$argument" =~ ^[[:alpha:]_][[:alnum:]_]*= ]]; then
                                index=$(( index + 1 ))
                            else
                                break
                            fi
                            ;;
                    esac
                done
                ;;
            time)
                (( index += 1 ))
                while (( index < ${#arguments[@]} )); do
                    argument="${arguments[index]}"
                    [[ "$argument" == "--" ]] && { (( index += 1 )); break; }
                    case "$argument" in
                        -o|--output|-f|--format) (( index += 2 )) ;;
                        -*) (( index += 1 )) ;;
                        *) break ;;
                    esac
                done
                ;;
            nice)
                (( index += 1 ))
                while (( index < ${#arguments[@]} )); do
                    argument="${arguments[index]}"
                    [[ "$argument" == "--" ]] && { (( index += 1 )); break; }
                    case "$argument" in
                        -n|--adjustment) (( index += 2 )) ;;
                        -*) (( index += 1 )) ;;
                        *) break ;;
                    esac
                done
                ;;
            *)
                _SIM_COMMAND_INDEX="$index"
                return 0
                ;;
        esac
    done
    return 1
}

# Build, test, and screenshot capture are headless. Simulator wrappers reject commands that
# try to launch the visible Simulator GUI.
sim_require_headless_command() {
    local -a arguments=("$@")
    local index argument application

    local find_status=0
    _sim_find_command_index "${arguments[@]}" || find_status=$?
    if [[ "$find_status" != "0" ]]; then
        if [[ "$find_status" == "2" ]]; then
            sim_log "refusing command-string wrappers; simulator build/test requires direct argv"
            return 1
        fi
        return 0
    fi
    index="$_SIM_COMMAND_INDEX"
    argument="${arguments[index]}"
    if [[ "$argument" == "Simulator.app" || "$argument" == */Simulator.app || "$argument" == */Simulator.app/* ]]; then
        sim_log "refusing to launch Simulator.app; simulator build/test is headless by default"
        return 1
    fi
    case "${argument##*/}" in
        sh|bash|dash|zsh)
            for (( index += 1; index < ${#arguments[@]}; index += 1 )); do
                case "${arguments[index]}" in
                    -c|--command)
                        sim_log "refusing shell command payloads; simulator build/test is headless by default"
                        return 1
                        ;;
                esac
            done
            ;;
    esac
    [[ "${argument##*/}" == "open" ]] || return 0

    for (( index += 1; index < ${#arguments[@]}; index += 1 )); do
        argument="${arguments[index]}"
        case "$argument" in
            -a)
                (( index += 1 ))
                application="${arguments[index]:-}"
                ;;
            -a*)
                application="${argument#-a}"
                ;;
            -b)
                (( index += 1 ))
                application="${arguments[index]:-}"
                ;;
            -b*)
                application="${argument#-b}"
                ;;
            *)
                application="$argument"
                ;;
        esac
        if [[ "$application" == "Simulator" || "$application" == "com.apple.iphonesimulator" \
            || "$application" == "Simulator.app" || "$application" == */Simulator.app || "$application" == */Simulator.app/* ]]; then
            sim_log "refusing to launch Simulator.app; simulator build/test is headless by default"
            return 1
        fi
    done
}

# List visible Simulator.app processes, not CoreSimulator's headless service processes.
# Kept as a function boundary so the boot-free unit test can supply a synthetic snapshot.
_sim_visible_simulator_app_processes() {
    local pid
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        ps -p "$pid" -o pid=,command= 2>/dev/null || true
    done < <(pgrep -x Simulator 2>/dev/null || true)
}

_sim_owned_simulator_app_identity_matches() {
    local wanted_pid="$1" recorded_pid recorded_lstart current_lstart
    current_lstart="$(_sim_proc_lstart "$wanted_pid")"
    [[ -n "$current_lstart" ]] || return 1
    while IFS=$'\t' read -r recorded_pid recorded_lstart; do
        [[ "$recorded_pid" == "$wanted_pid" && "$recorded_lstart" == "$current_lstart" ]] && return 0
    done <<< "$_SIM_OWNED_SIMULATOR_APP_IDENTITIES"
    return 1
}

_sim_record_owned_simulator_apps() {
    local command_pgid="$1" pid command process_pgid process_lstart
    [[ "$command_pgid" =~ ^[0-9]+$ && -n "${SIM_UDID:-}" ]] || return 0
    while read -r pid command; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ "$command" == *"-CurrentDeviceUDID $SIM_UDID"* ]] || continue
        process_pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [[ "$process_pgid" == "$command_pgid" ]] || continue
        process_lstart="$(_sim_proc_lstart "$pid")"
        [[ -n "$process_lstart" ]] || continue
        _sim_owned_simulator_app_identity_matches "$pid" \
            || _SIM_OWNED_SIMULATOR_APP_IDENTITIES+="$pid"$'\t'"$process_lstart"$'\n'
    done < <(_sim_visible_simulator_app_processes)
}

_sim_reject_run_simulator_app() {
    [[ -n "${SIM_UDID:-}" ]] || return 0
    local processes pid command matched=0 attempt
    processes="$(_sim_visible_simulator_app_processes)"
    while read -r pid command; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        _sim_owned_simulator_app_identity_matches "$pid" || continue
        [[ "$command" == *"-CurrentDeviceUDID $SIM_UDID"* ]] || continue
        sim_log "HEADLESS VIOLATION: terminating Simulator.app process $pid launched for run device $SIM_UDID"
        kill -TERM "$pid" 2>/dev/null || true
        matched=1
    done <<< "$processes"
    [[ "$matched" == "1" ]] || return 0

    for attempt in 1 2 3 4 5; do
        local still_running=0
        while read -r pid command; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            _sim_owned_simulator_app_identity_matches "$pid" || continue
            [[ "$command" == *"-CurrentDeviceUDID $SIM_UDID"* ]] || continue
            kill -0 "$pid" 2>/dev/null && still_running=1
        done < <(_sim_visible_simulator_app_processes)
        [[ "$still_running" == "0" ]] && break
        sleep 1
    done

    while read -r pid command; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        _sim_owned_simulator_app_identity_matches "$pid" || continue
        [[ "$command" == *"-CurrentDeviceUDID $SIM_UDID"* ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done < <(_sim_visible_simulator_app_processes)
    return 1
}

# Returns success when an argv array resolves to xcodebuild and invokes a test action.
# Callers use this to force a single non-parallel worker, preventing Xcode from creating an
# unbounded fan-out of test clones.
sim_is_xcodebuild_test_command() {
    local -a arguments=("$@")
    _sim_find_command_index "${arguments[@]}" || return 1
    local index="$_SIM_COMMAND_INDEX" argument
    [[ "${arguments[index]##*/}" == "xcodebuild" ]] || return 1
    for (( index += 1; index < ${#arguments[@]}; index += 1 )); do
        argument="${arguments[index]}"
        case "$argument" in
            test|test-without-building) return 0 ;;
        esac
    done
    return 1
}

_sim_claim_source_device_slot() {
    _sim_require_nonnegative_integer "SIM_MAX_SOURCE_DEVICES" "$SIM_MAX_SOURCE_DEVICES" || return 1
    if (( _SIM_SOURCE_CREATE_ATTEMPTS >= SIM_MAX_SOURCE_DEVICES )); then
        sim_log "HARD CAP: refusing source simulator creation attempt $(( _SIM_SOURCE_CREATE_ATTEMPTS + 1 )); per-run maximum is $SIM_MAX_SOURCE_DEVICES"
        return 1
    fi
    _SIM_SOURCE_CREATE_ATTEMPTS=$(( _SIM_SOURCE_CREATE_ATTEMPTS + 1 ))
}

_sim_ensure_base() {
    mkdir -p "$SIM_RUNS_BASE"
}

# Normalized process start-time string for a pid, or empty if the pid is gone.
# lstart is stable for the life of a pid, so (pid alive AND lstart unchanged) reliably
# distinguishes "still our owner" from "pid was recycled for someone else".
_sim_proc_lstart() {
    local pid="$1"
    ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//' | tr -s ' '
}

_sim_recorded_process_alive() {
    local run_dir="$1" role="$2"
    local pid_file="$run_dir/$role.pid"
    local lstart_file="$run_dir/$role.lstart"
    [[ -f "$pid_file" ]] || return 1

    local pid
    pid="$(cat "$pid_file" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    if [[ -f "$lstart_file" ]]; then
        local want have
        want="$(cat "$lstart_file" 2>/dev/null)"
        have="$(_sim_proc_lstart "$pid")"
        [[ -n "$have" && "$have" == "$want" ]] || return 1
    fi
    return 0
}

# 0 if the owner recorded in $1 (a run dir) is still alive, 1 otherwise.
_sim_owner_alive() {
    _sim_recorded_process_alive "$1" owner
}

# Age in seconds of a path's mtime (large number if it cannot be determined).
_sim_path_age_secs() {
    local path="$1" mtime now
    mtime="$(stat -f %m "$path" 2>/dev/null)" || { echo 999999; return; }
    now="$(date +%s)"
    echo $(( now - mtime ))
}

sim_command_group_running() {
    local pgid="$1"
    ps -axo pgid=,stat= 2>/dev/null | awk -v pgid="$pgid" '$1 == pgid && $2 !~ /^Z/ { found = 1 } END { exit !found }' && return 0
    local stat
    stat="$(ps -o stat= -p "$pgid" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    [[ -n "$stat" && "$stat" != Z* ]]
}

sim_stop_command() {
    local pid="$1"
    local timeout="${2:-${EW_SIM_TERM_TIMEOUT_SECS:-20}}"
    local waited=0
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    while sim_command_group_running "$pid"; do
        (( waited >= timeout )) && break
        sleep 1
        waited=$(( waited + 1 ))
    done
    if sim_command_group_running "$pid"; then
        kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

# Shut down + delete ONE device by UDID from the DEFAULT device set. Always scoped to a
# single explicit UDID - NEVER `shutdown all`/`delete all` - so no other device (the user's
# own, or a concurrent run's) is ever touched. A device that is already gone counts as
# success; only a still-present device that refuses to delete is a failure.
_sim_delete_device() {
    local udid="$1"
    [[ -n "$udid" ]] || return 0
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    if ! xcrun simctl delete "$udid" >/dev/null 2>&1; then
        local devices
        devices="$(xcrun simctl list devices 2>/dev/null)" || return 1
        if grep -qF "$udid" <<< "$devices"; then
            return 1
        fi
    fi
    return 0
}

_sim_recorded_udid() {
    local udid_file="$1/device.udid"
    [[ -f "$udid_file" ]] || return 0

    local udid
    if ! udid="$(cat "$udid_file" 2>/dev/null)"; then
        [[ -e "$udid_file" ]] && return 1
        return 0
    fi
    printf '%s\n' "$udid"
}

_sim_recorded_device_name() {
    local name_file="$1/device.name"
    [[ -f "$name_file" ]] || return 0

    local name
    if ! name="$(cat "$name_file" 2>/dev/null)"; then
        [[ -e "$name_file" ]] && return 1
        return 0
    fi
    printf '%s\n' "$name"
}

_sim_default_device_udid_for_name() {
    local wanted_name="$1" devices
    [[ -n "$wanted_name" ]] || return 1
    devices="$(xcrun simctl list devices 2>/dev/null)" || return 2
    awk -v wanted_name="$wanted_name" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (!match(line, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/)) next
            udid = substr(line, RSTART, RLENGTH)
            name = line
            sub(/ \([0-9A-Fa-f-]+\).*$/, "", name)
            sub(/[[:space:]]+$/, "", name)
            if (name != wanted_name) next
            print udid
            matched = 1
            exit
        }
        END { exit matched ? 0 : 1 }
    ' <<< "$devices"
}

_sim_default_device_name_for_udid() {
    local udid="$1" devices
    [[ -n "$udid" ]] || return 1
    devices="$(xcrun simctl list devices 2>/dev/null)" || return 2
    awk -v want="$udid" '
        BEGIN { want = tolower(want) }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (!match(line, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/)) next
            found = substr(line, RSTART, RLENGTH)
            if (tolower(found) != want) next
            name = line
            sub(/ \([0-9A-Fa-f-]+\).*$/, "", name)
            sub(/[[:space:]]+$/, "", name)
            print name
            matched = 1
            exit
        }
        END { exit matched ? 0 : 1 }
    ' <<< "$devices"
}

_sim_device_name_has_run_prefix() {
    local name="$1" rest
    [[ "$name" == "$SIM_DEVICE_NAME_PREFIX"-* ]] || return 1
    rest="${name#"$SIM_DEVICE_NAME_PREFIX"-}"
    [[ "$rest" =~ ^[0-9]+-[0-9A-Za-z]+$ ]]
}

# Finalize one run: delete its device (UDID may be empty if create never succeeded) and
# remove its marker dir. Leaves the dir in place on failure so a later reaper can retry.
_sim_finalize_run() {
    local run_dir="$1" udid="$2"
    if [[ -n "$udid" ]]; then
        if ! _sim_delete_device "$udid"; then
            sim_log "failed to delete simulator $udid; leaving $(basename "$run_dir") for retry"
            return 1
        fi
    fi
    if ! rm -rf "$run_dir" 2>/dev/null; then
        sim_log "failed to remove simulator run dir $run_dir; leaving it for retry"
        return 1
    fi
    return 0
}

# Reap one run marker dir: read the recorded UDID, confirm it still names a run-scoped
# device, then finalize. A marker that points at a device somebody has since renamed (or a
# recycled UDID) is dropped without deleting anything.
_sim_reap_run() {
    local run_dir="$1"
    [[ -d "$run_dir" ]] || return 0
    local udid="" recorded_name=""
    udid="$(_sim_recorded_udid "$run_dir")" || return 1
    recorded_name="$(_sim_recorded_device_name "$run_dir")" || return 1
    if [[ -z "$udid" && -n "$recorded_name" ]]; then
        local resolve_status=0
        udid="$(_sim_default_device_udid_for_name "$recorded_name")" || resolve_status=$?
        if [[ "$resolve_status" == "2" ]]; then
            sim_log "failed to resolve simulator $recorded_name before reaping $(basename "$run_dir"); leaving marker for retry"
            return 1
        fi
        if [[ "$resolve_status" == "1" ]]; then
            local creation_state=""
            [[ -f "$run_dir/create.state" ]] \
                && creation_state="$(cat "$run_dir/create.state" 2>/dev/null || true)"
            if [[ "$creation_state" == "pending" && -s "$run_dir/create.pid" ]]; then
                if _sim_recorded_process_alive "$run_dir" create; then
                    sim_log "simulator creation for $recorded_name is still running; leaving marker for retry"
                    return 3
                fi
            elif [[ "$creation_state" != "settled" ]]; then
                local marker_age
                marker_age="$(_sim_path_age_secs "$run_dir")"
                if (( marker_age < SIM_REAP_GRACE_SECS )); then
                    sim_log "simulator creation for $recorded_name has not settled; leaving marker for retry"
                    return 3
                fi
            fi
            _sim_finalize_run "$run_dir" ""
            return
        fi
    fi
    if [[ -n "$udid" ]]; then
        local device_name lookup_status ownership_matches=0
        lookup_status=0
        device_name="$(_sim_default_device_name_for_udid "$udid")" || lookup_status=$?
        if [[ "$lookup_status" == "2" ]]; then
            sim_log "failed to verify simulator $udid before reaping $(basename "$run_dir"); leaving marker for retry"
            return 1
        fi
        if [[ "$lookup_status" == "0" ]]; then
            if [[ -n "$recorded_name" ]]; then
                [[ "$device_name" == "$recorded_name" ]] && ownership_matches=1
            elif _sim_device_name_has_run_prefix "$device_name"; then
                ownership_matches=1
            fi
            if [[ "$ownership_matches" == "0" ]]; then
                sim_log "skipping simulator $udid from stale marker $(basename "$run_dir"); device name does not match recorded ownership: $device_name"
                if ! rm -rf "$run_dir" 2>/dev/null; then
                    sim_log "failed to remove stale simulator run dir $run_dir; leaving it for retry"
                    return 1
                fi
                return 0
            fi
        fi
    fi
    _sim_finalize_run "$run_dir" "$udid"
}

# Echo "udid<TAB>name<TAB>pid" for every DEFAULT-set device whose name matches the
# run-scoped prefix "<prefix>-<pid>-<rand>". Parsing the human-readable list keeps this
# dependency-free (no jq/plutil). Devices NOT matching the prefix are never emitted, which
# is what makes operating in the shared default set safe.
_sim_prefixed_devices() {
    local devices
    devices="$(xcrun simctl list devices 2>/dev/null)" || return 0
    awk -v prefix="$SIM_DEVICE_NAME_PREFIX" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (!match(line, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/)) next
            udid = substr(line, RSTART, RLENGTH)
            name = line
            sub(/ \([0-9A-Fa-f-]+\).*$/, "", name)
            sub(/[[:space:]]+$/, "", name)
            if (substr(name, 1, length(prefix) + 1) != prefix "-") next
            rest = substr(name, length(prefix) + 2)
            if (rest !~ /^[0-9]+-[0-9A-Za-z]+$/) next
            split(rest, parts, "-")
            printf "%s\t%s\t%s\n", udid, name, parts[1]
        }
    ' <<< "$devices"
}

# ---------------------------------------------------------------------------
# Pre-run reaper (the SIGKILL belt-and-suspenders)
# ---------------------------------------------------------------------------

# Reap every run-scoped device whose owner is dead. Never touches a device this run created,
# never touches a live run's device (live owner => spared), and never touches a device whose
# name lacks our prefix (the user's own devices, Xcode defaults). Safe to call before any
# create. Two passes:
#   1. By marker dir: a dead-owner run's recorded device is deleted by UDID.
#   2. By name: a prefixed default-set device whose marker was lost is judged by the pid
#      embedded in its name; if that pid is dead, the device is an orphan and is deleted.
sim_reap_stale() {
    _sim_ensure_base

    local reaped=0 run_dir

    # Pass 1: marker dirs.
    for run_dir in "$SIM_RUNS_BASE"/run.*; do
        [[ -d "$run_dir" ]] || continue
        # Never reap our own run; sim_teardown owns that.
        [[ -n "$SIM_RUN_DIR" && "$run_dir" == "$SIM_RUN_DIR" ]] && continue

        if _sim_owner_alive "$run_dir"; then
            continue  # an active run (possibly a concurrent worktree) - leave it alone
        fi

        # Owner not provably alive. If there is no marker yet, this may be a sibling that
        # just made its dir but has not written owner.pid; spare it until the grace passes.
        if [[ ! -f "$run_dir/owner.pid" ]]; then
            local age
            age="$(_sim_path_age_secs "$run_dir")"
            (( age < SIM_REAP_GRACE_SECS )) && continue
        fi

        sim_log "reaping orphaned simulator run $(basename "$run_dir") (owner dead)"
        local reap_status=0
        _sim_reap_run "$run_dir" || reap_status=$?
        if [[ "$reap_status" == "0" ]]; then
            reaped=$(( reaped + 1 ))
        elif [[ "$reap_status" != "3" ]]; then
            return 1
        fi
    done

    # Collect UDIDs still covered by a (now necessarily live, or our own) marker dir, so
    # pass 2 does not touch a device a live run still owns.
    local covered=" "
    for run_dir in "$SIM_RUNS_BASE"/run.*; do
        [[ -d "$run_dir" && -f "$run_dir/device.udid" ]] || continue
        local covered_udid
        covered_udid="$(_sim_recorded_udid "$run_dir")" || return 1
        [[ -n "$covered_udid" ]] && covered+="$covered_udid "
    done

    # Pass 2: prefixed default-set devices whose marker was lost.
    local udid name pid
    while IFS=$'\t' read -r udid name pid; do
        [[ -n "$udid" ]] || continue
        [[ -n "$SIM_UDID" && "$udid" == "$SIM_UDID" ]] && continue   # spare our own device
        [[ "$covered" == *" $udid "* ]] && continue                  # a live marker owns it
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            continue  # the owning process named in the device is still alive
        fi
        sim_log "reaping orphaned simulator device $name ($udid) (no marker, owner dead)"
        if _sim_delete_device "$udid"; then
            reaped=$(( reaped + 1 ))
        else
            return 1
        fi
    done < <(_sim_prefixed_devices)

    (( reaped > 0 )) && sim_log "reaped $reaped orphaned simulator(s)"
    return 0
}

# ---------------------------------------------------------------------------
# Per-run XCTest clone cleanup
# ---------------------------------------------------------------------------

# `xcodebuild test` may clone the target into ~/Library/Developer/XCTestDevices as
# "Clone N of <device>". Delete only clones derived from THIS run's exact source name or
# UDID. Poll through a quiet window because Xcode can publish its final clone after the
# xcodebuild process exits. There is intentionally no keep-clones escape hatch: every exit
# path must clean its per-run devices.
sim_cleanup_xctest_clones() {
    [[ -n "${SIM_DEVICE_NAME:-}" || -n "${SIM_UDID:-}" ]] || return 0

    _sim_require_nonnegative_integer "SIM_MAX_XCTEST_CLONES" "$SIM_MAX_XCTEST_CLONES" || return 1
    _sim_require_nonnegative_integer "EW_SIM_CLONE_SETTLE_ATTEMPTS" "$SIM_CLONE_SETTLE_ATTEMPTS" || return 1
    _sim_require_nonnegative_integer "EW_SIM_CLONE_SETTLE_EMPTY_PASSES" "$SIM_CLONE_SETTLE_EMPTY_PASSES" || return 1
    _sim_require_nonnegative_integer "EW_SIM_CLONE_SETTLE_DELAY_SECS" "$SIM_CLONE_SETTLE_DELAY_SECS" || return 1
    (( SIM_CLONE_SETTLE_ATTEMPTS > 0 && SIM_CLONE_SETTLE_EMPTY_PASSES > 0 )) || {
        sim_log "clone settle attempts and empty passes must both be greater than zero"
        return 1
    }

    local xctest_device_set="${EW_XCTEST_DEVICE_SET:-${XCTEST_DEVICE_SET:-$HOME/Library/Developer/XCTestDevices}}"
    [[ -d "$xctest_device_set" ]] || return 0

    local attempt clone_udid clone_output failed=0 empty_passes=0
    for (( attempt = 1; attempt <= SIM_CLONE_SETTLE_ATTEMPTS; attempt++ )); do
        if ! clone_output="$(_sim_xctest_clone_udids "$xctest_device_set")"; then
            sim_log "failed to list XCTest clone simulators in $xctest_device_set"
            failed=1
            empty_passes=0
        else
            local clone_udids=()
            while IFS= read -r clone_udid; do
                [[ -n "$clone_udid" ]] && clone_udids+=( "$clone_udid" )
            done <<< "$clone_output"

            for clone_udid in "${clone_udids[@]}"; do
                if [[ "$_SIM_XCTEST_SEEN_CLONE_UDIDS" != *" $clone_udid "* ]]; then
                    _SIM_XCTEST_SEEN_CLONE_UDIDS+="$clone_udid "
                    _SIM_XCTEST_SEEN_CLONE_COUNT=$(( _SIM_XCTEST_SEEN_CLONE_COUNT + 1 ))
                    if (( _SIM_XCTEST_SEEN_CLONE_COUNT > SIM_MAX_XCTEST_CLONES )); then
                        if [[ "$_SIM_XCTEST_CLONE_CAP_EXCEEDED" == "0" ]]; then
                            sim_log "HARD CAP: Xcode created $_SIM_XCTEST_SEEN_CLONE_COUNT XCTest clones for $SIM_DEVICE_NAME; per-run maximum is $SIM_MAX_XCTEST_CLONES"
                        fi
                        _SIM_XCTEST_CLONE_CAP_EXCEEDED=1
                    fi
                fi
            done

            if [[ "${#clone_udids[@]}" == "0" ]]; then
                empty_passes=$(( empty_passes + 1 ))
                if (( empty_passes >= SIM_CLONE_SETTLE_EMPTY_PASSES )); then
                    [[ "$_SIM_XCTEST_CLONE_CAP_EXCEEDED" == "0" && "$failed" == "0" ]]
                    return
                fi
            else
                empty_passes=0
                for clone_udid in "${clone_udids[@]}"; do
                    xcrun simctl --set "$xctest_device_set" shutdown "$clone_udid" >/dev/null 2>&1 || true
                    xcrun simctl --set "$xctest_device_set" delete "$clone_udid" >/dev/null 2>&1 || true
                done
            fi
        fi
        (( attempt < SIM_CLONE_SETTLE_ATTEMPTS )) && sleep "$SIM_CLONE_SETTLE_DELAY_SECS"
    done

    clone_output="$(_sim_xctest_clone_udids "$xctest_device_set")" || clone_output="__LIST_FAILED__"
    if [[ -n "$clone_output" ]]; then
        sim_log "failed to delete XCTest clone simulators for $SIM_DEVICE_NAME from $xctest_device_set"
        return 1
    fi
    [[ "$_SIM_XCTEST_CLONE_CAP_EXCEEDED" == "0" && "$failed" == "0" ]]
}

_sim_xctest_clone_udids() {
    local xctest_device_set="$1"
    local devices
    devices="$(xcrun simctl --set "$xctest_device_set" list devices 2>/dev/null)" || return 1
    awk -v source_name="$SIM_DEVICE_NAME" -v source_udid="${SIM_UDID:-}" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line !~ /^Clone [0-9]+ of /) next

            owned = 0
            if (source_name != "" && index(line, " of " source_name " (") > 0) owned = 1
            if (!owned && source_udid != "" && index(line, source_udid) > 0) owned = 1
            if (!owned) next

            if (match(line, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/)) {
                print substr(line, RSTART, RLENGTH)
            }
        }
    ' <<< "$devices"
}

# ---------------------------------------------------------------------------
# Runtime / device-type resolution
# ---------------------------------------------------------------------------

# Echo a runtime identifier present on the system. Accepts "", a version like "26.4", or a
# full com.apple...SimRuntime.iOS-26-4 identifier. Prefers an exact match, else newest iOS.
_sim_resolve_runtime() {
    local want="${1:-$SIM_DEFAULT_RUNTIME}"
    xcrun simctl list runtimes available 2>/dev/null | awk -v want="$want" '
        /iOS/ {
            id = $NF
            ver = ""
            for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+$/) { ver = $i; break }
            if (want != "" && (id == want || ver == want)) { exact = 1; print id; exit }
            # Track newest iOS runtime as a fallback.
            n = split(ver, p, ".")
            key = (n >= 1 ? p[1] * 1000 + (n >= 2 ? p[2] : 0) : 0)
            if (key > best) { best = key; bestid = id }
        }
        END { if (!exact && bestid != "") print bestid }
    '
}

# Echo a device type identifier. Accepts a display name ("iPhone 17 Pro") or a full
# com.apple...SimDeviceType identifier. Exact-name match wins.
_sim_resolve_device_type() {
    local want="${1:-${SIM_DEFAULT_DEVICES[0]}}"
    xcrun simctl list devicetypes 2>/dev/null | awk -v want="$want" '
        {
            line = $0
            # Identifier is the parenthesized com.apple... token.
            id = ""
            if (match(line, /com\.apple\.CoreSimulator\.SimDeviceType\.[^)]*/)) {
                id = substr(line, RSTART, RLENGTH)
            }
            name = line
            sub(/ *\(com\.apple.*$/, "", name)
            sub(/^ +/, "", name); sub(/ +$/, "", name)
            if (id == want) { print id; exit }
            if (name == want) { print id; exit }
        }
    '
}

# Echo the first installed device type from an ordered preference list, so the same policy
# ("prefer the device family the READMEs verify on") holds on a machine that provisions a
# different set of device types. Warns whenever anything but the first choice is used.
_sim_resolve_preferred_device_type() {
    local want device_type
    for want in "$@"; do
        [[ -n "$want" ]] || continue
        device_type="$(_sim_resolve_device_type "$want")"
        if [[ -n "$device_type" ]]; then
            [[ "$want" == "$1" ]] || sim_log "preferred device '$1' is not installed; using '$want'"
            printf '%s\n' "$device_type"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Per-run device creation + boot
# ---------------------------------------------------------------------------

# sim_set_up <runtime> [device-type...]
# Creates this run's run-scoped device in the DEFAULT set, boots it, and waits for boot to
# complete. Sets SIM_UDID / SIM_DEVICE_NAME / SIM_RUN_DIR and marks us as owning teardown.
# The caller is responsible for tearing down via `sim_cleanup_run` on every exit path.
sim_set_up() {
    local runtime_arg="${1:-$SIM_DEFAULT_RUNTIME}"
    shift || true
    local -a device_args=("$@")
    (( ${#device_args[@]} > 0 )) || device_args=("${SIM_DEFAULT_DEVICES[@]}")

    _sim_ensure_base

    local device_type runtime
    device_type="$(_sim_resolve_preferred_device_type "${device_args[@]}")" \
        || { sim_log "no simulator device type matching: ${device_args[*]}"; return 1; }
    runtime="$(_sim_resolve_runtime "$runtime_arg")"
    [[ -n "$runtime" ]] || { sim_log "no installed iOS runtime matching '$runtime_arg'"; return 1; }
    _sim_claim_source_device_slot || return 1

    # Write the liveness marker FIRST, before any device exists, so a run always has an owner
    # the reaper can evaluate. Claim teardown ownership at the same moment, so even a failed
    # `create` leaves a dir our own teardown removes.
    local rand="$RANDOM$RANDOM"
    SIM_RUN_DIR="$SIM_RUNS_BASE/run.$$.$rand"
    SIM_DEVICE_NAME="$SIM_DEVICE_NAME_PREFIX-$$-$rand"
    mkdir -p "$SIM_RUN_DIR"
    printf '%s\n' "$SIM_DEVICE_NAME" > "$SIM_RUN_DIR/device.name"
    printf '%s\n' "$$" > "$SIM_RUN_DIR/owner.pid"
    _sim_proc_lstart "$$" > "$SIM_RUN_DIR/owner.lstart"
    SIM_OWNS_TEARDOWN=1
    _SIM_TORN_DOWN=0
    export SIM_RUN_DIR SIM_DEVICE_NAME SIM_DEVICE_NAME_PREFIX

    sim_log "creating run-scoped simulator $SIM_DEVICE_NAME ($device_type / $runtime) in the default device set"
    local create_output="$SIM_RUN_DIR/create.output"
    local create_gate="$SIM_RUN_DIR/create.start"
    local create_status=0 create_pid owner_pid="$$"
    printf '%s\n' pending > "$SIM_RUN_DIR/create.state"
    (
        while [[ ! -f "$create_gate" ]]; do
            kill -0 "$owner_pid" 2>/dev/null || exit 1
            sleep 0.01
        done
        exec xcrun simctl create "$SIM_DEVICE_NAME" "$device_type" "$runtime"
    ) > "$create_output" &
    create_pid=$!
    printf '%s\n' "$create_pid" > "$SIM_RUN_DIR/create.pid"
    _sim_proc_lstart "$create_pid" > "$SIM_RUN_DIR/create.lstart"
    : > "$create_gate"
    wait "$create_pid" || create_status=$?
    printf '%s\n' settled > "$SIM_RUN_DIR/create.state"
    rm -f "$create_gate" "$SIM_RUN_DIR/create.pid" "$SIM_RUN_DIR/create.lstart"
    SIM_UDID="$(cat "$create_output" 2>/dev/null || true)"
    rm -f "$create_output"
    if [[ "$create_status" != "0" || -z "$SIM_UDID" ]]; then
        sim_log "failed to create simulator"
        return 1
    fi
    printf '%s\n' "$SIM_UDID" > "$SIM_RUN_DIR/device.udid"
    export SIM_UDID

    # Boot now (and wait): the test command typically needs a booted device, and booting
    # here lets us assert a clean teardown afterwards.
    xcrun simctl boot "$SIM_UDID"
    xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
    sim_log "booted $SIM_UDID"
    export SIM_UDID SIM_DEVICE_NAME SIM_RUN_DIR SIM_DEVICE_NAME_PREFIX
}

# ---------------------------------------------------------------------------
# Teardown (the caller wires this into its EXIT/INT/TERM traps)
# ---------------------------------------------------------------------------

# Shut down and delete ONLY the one device THIS run created, by its UDID, then remove the
# marker dir. Never touches any other device.
sim_teardown() {
    [[ "$SIM_OWNS_TEARDOWN" == "1" ]] || return 0
    [[ "$_SIM_TORN_DOWN" == "1" ]] && return 0
    [[ -n "$SIM_RUN_DIR" ]] || return 0
    [[ -d "$SIM_RUN_DIR" ]] || { _SIM_TORN_DOWN=1; return 0; }
    sim_log "tearing down run-scoped simulator $SIM_DEVICE_NAME ($SIM_UDID)"
    _sim_finalize_run "$SIM_RUN_DIR" "$SIM_UDID" || return 1
    _SIM_TORN_DOWN=1
}

# Post-run assertion: this run must leave nothing of its own behind. After teardown the
# marker, source device, and every derived XCTest clone are gone. Returns non-zero and logs
# loudly on any leak so a caller fails instead of silently accumulating simulators.
sim_assert_clean() {
    local leaked=0
    if [[ "$SIM_OWNS_TEARDOWN" == "1" && -d "$SIM_RUN_DIR" ]]; then
        sim_log "LEAK: run marker still present after teardown: $SIM_RUN_DIR"
        leaked=1
    fi
    if [[ "$SIM_OWNS_TEARDOWN" == "1" && -n "$SIM_UDID" ]] \
        && xcrun simctl list devices 2>/dev/null | grep -qF "$SIM_UDID"; then
        sim_log "LEAK: device still present after teardown: $SIM_DEVICE_NAME ($SIM_UDID)"
        leaked=1
    fi

    local xctest_device_set="${EW_XCTEST_DEVICE_SET:-${XCTEST_DEVICE_SET:-$HOME/Library/Developer/XCTestDevices}}"
    if [[ -d "$xctest_device_set" && ( -n "${SIM_DEVICE_NAME:-}" || -n "${SIM_UDID:-}" ) ]]; then
        local clone_output
        if ! clone_output="$(_sim_xctest_clone_udids "$xctest_device_set")"; then
            sim_log "LEAK CHECK FAILED: could not list XCTest devices in $xctest_device_set"
            leaked=1
        elif [[ -n "$clone_output" ]]; then
            sim_log "LEAK: XCTest clone still present for $SIM_DEVICE_NAME: $(tr '\n' ' ' <<< "$clone_output")"
            leaked=1
        fi
    fi
    return "$leaked"
}

# One cleanup owner for every caller and every exit path. Clean clones both before and
# after deleting the source: the first pass catches active test workers, while the second
# settle-window pass catches a clone published late during xcodebuild shutdown. Every step
# runs even if an earlier one fails. A run-scoped Simulator.app process is terminated and
# makes cleanup fail so a visible-GUI regression can never pass silently.
sim_cleanup_run() {
    local cleanup_status=0 step_status=0

    _sim_reject_run_simulator_app || { step_status=$?; cleanup_status="$step_status"; }
    _sim_reset_xctest_clone_tracking
    sim_cleanup_xctest_clones || { step_status=$?; cleanup_status="$step_status"; }
    sim_teardown || { step_status=$?; cleanup_status="$step_status"; }
    sim_cleanup_xctest_clones || { step_status=$?; cleanup_status="$step_status"; }
    sim_assert_clean || { step_status=$?; cleanup_status="$step_status"; }

    return "$cleanup_status"
}
