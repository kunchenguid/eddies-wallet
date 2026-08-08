#!/usr/bin/env bash
# shellcheck shell=bash

_sim_policy_parent_owns_run() {
    local parent_command owner_pid recorded_udid=""
    [[ -n "${SIM_RUN_DIR:-}" && -d "$SIM_RUN_DIR" ]] || return 1
    parent_command="$(ps -p "$PPID" -o command= 2>/dev/null || true)"
    [[ "$parent_command" =~ (^|[[:space:]/])test/sim\.sh([[:space:]]|$) ]] || return 1
    owner_pid="$(cat "$SIM_RUN_DIR/owner.pid" 2>/dev/null || true)"
    [[ "$owner_pid" == "$PPID" ]] || return 1
    if [[ -f "$SIM_RUN_DIR/device.udid" ]]; then
        recorded_udid="$(cat "$SIM_RUN_DIR/device.udid" 2>/dev/null || true)"
    fi
    [[ -z "${SIM_UDID:-}" || "$recorded_udid" == "$SIM_UDID" ]] || return 1
}

_sim_policy_managed_destination() {
    local argument destination="" expect_destination=0 field
    local found_platform=0 found_id=0
    local -a fields=()
    [[ -n "${SIM_UDID:-}" ]] || return 1
    for argument in "$@"; do
        if [[ "$expect_destination" == "1" ]]; then
            destination="$argument"
            break
        fi
        case "$argument" in
            -destination) expect_destination=1 ;;
            -destination=*) destination="${argument#-destination=}"; break ;;
        esac
    done
    IFS=',' read -r -a fields <<< "$destination"
    for field in "${fields[@]}"; do
        case "$field" in
            "platform=iOS Simulator") found_platform=1 ;;
            id="$SIM_UDID") found_id=1 ;;
            id=*) return 1 ;;
        esac
    done
    [[ "$found_platform" == "1" && "$found_id" == "1" ]]
}
