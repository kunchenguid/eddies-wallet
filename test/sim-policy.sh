#!/usr/bin/env bash
# shellcheck shell=bash

_sim_policy_check_command() {
    local command_text="$BASH_COMMAND"
    trap - DEBUG

    if [[ "${EW_SIM_POLICY_WRAPPED:-0}" != "1" \
        && "$command_text" =~ (^|[\;\&\|\(\)[:space:]])([^[:space:]]*/)?xcrun[[:space:]]+simctl[[:space:]]+boot([[:space:]]|$) ]]; then
        echo "sim-policy: simctl boot must run through test/sim.sh" >&2
        exit 92
    fi
    if [[ "${EW_SIM_POLICY_WRAPPED:-0}" != "1" \
        && "$command_text" =~ (^|[\;\&\|\(\)[:space:]])([^[:space:]]*/)?xcodebuild([[:space:]]|$) \
        && "$command_text" == *"iOS Simulator"* ]]; then
        echo "sim-policy: simulator xcodebuild must run through test/sim.sh" >&2
        exit 92
    fi
    if [[ "$command_text" =~ (^|[\;\&\|\(\)[:space:]])([^[:space:]]*/)?open([[:space:]]|$) \
        && ( "$command_text" == *"Simulator"* || "$command_text" == *"com.apple.iphonesimulator"* ) ]]; then
        echo "sim-policy: Simulator.app launches are not allowed in automated workflows" >&2
        exit 92
    fi

    trap _sim_policy_check_command DEBUG
}

trap _sim_policy_check_command DEBUG

case "${EW_SIM_POLICY_PROBE:-}" in
    absolute-xcrun)
        /usr/bin/xcrun simctl boot POLICY-PROBE
        ;;
    command-p-xcrun)
        command -p xcrun simctl boot POLICY-PROBE
        ;;
    absolute-xcodebuild)
        /usr/bin/xcodebuild test -destination 'platform=iOS Simulator,id=POLICY-PROBE'
        ;;
    absolute-open)
        /usr/bin/open -a Simulator
        ;;
esac
