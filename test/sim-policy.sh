#!/usr/bin/env bash
# shellcheck shell=bash

_sim_policy_command_basename() {
    local command_text="$1" token variable suffix value
    token="${command_text#"${command_text%%[![:space:]]*}"}"
    token="${token%%[[:space:]]*}"
    token="${token//\"/}"
    token="${token//\'/}"
    if [[ "$token" =~ ^\$\{([a-zA-Z_][a-zA-Z0-9_]*)\}(.*)$ ]]; then
        variable="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]}"
        value="${!variable:-}$suffix"
    elif [[ "$token" =~ ^\$([a-zA-Z_][a-zA-Z0-9_]*)(/.*)?$ ]]; then
        variable="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]:-}"
        value="${!variable:-}$suffix"
    else
        value="$token"
    fi
    printf '%s\n' "${value##*/}"
}

_sim_policy_check_command() {
    local command_text="$BASH_COMMAND" command_basename
    trap - DEBUG
    command_basename="$(_sim_policy_command_basename "$command_text")"

    if [[ "$command_text" =~ ^[[:space:]]*([^[:space:]]*/)?test/sim\.sh([[:space:]]|$) ]]; then
        trap _sim_policy_check_command DEBUG
        return 0
    fi

    if [[ "${EW_SIM_POLICY_WRAPPED:-0}" != "1" \
        && ( "$command_text" =~ (^|[\;\&\|\(\)[:space:]])([^[:space:]]*/)?xcrun[[:space:]]+simctl[[:space:]]+boot([[:space:]]|$) \
            || ( "$command_basename" == "xcrun" \
                && "$command_text" =~ simctl[[:space:]]+boot([[:space:]]|$) ) ) ]]; then
        echo "sim-policy: simctl boot must run through test/sim.sh" >&2
        exit 92
    fi
    if [[ "${EW_SIM_POLICY_WRAPPED:-0}" != "1" \
        && ( "$command_basename" == "xcodebuild" \
            || "$command_text" =~ (^|[\;\&\|\(\)[:space:]])([^[:space:]]*/)?xcodebuild([[:space:]]|$) ) \
        && ( "$command_text" == *"iOS Simulator"* \
            || "$command_text" =~ -destination(=|[[:space:]]+)[\"\']?id= ) ]]; then
        echo "sim-policy: simulator xcodebuild must run through test/sim.sh" >&2
        exit 92
    fi
    if [[ ( "$command_basename" == "open" \
            || "$command_text" =~ (^|[\;\&\|\(\)[:space:]])([^[:space:]]*/)?open([[:space:]]|$) ) \
        && ( "$command_text" == *"Simulator"* || "$command_text" == *"com.apple.iphonesimulator"* ) ]]; then
        echo "sim-policy: Simulator.app launches are not allowed in automated workflows" >&2
        exit 92
    fi

    trap _sim_policy_check_command DEBUG
}

set -T
trap _sim_policy_check_command DEBUG
