#!/usr/bin/env bash
# SC1091: sourced test helpers are loaded dynamically and ShellCheck cannot resolve them here.
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./bashio-mocks.sh
source "${ROOT_DIR}/tests/bashio-mocks.sh"
# shellcheck source=../rootfs/etc/s6-overlay/s6-rc.d/mqtt-status/run
source "${ROOT_DIR}/rootfs/etc/s6-overlay/s6-rc.d/mqtt-status/run"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local name="$3"

    if [[ "${actual}" != "${expected}" ]]; then
        echo "FAIL: ${name}: expected '${expected}', got '${actual}'"
        exit 1
    fi
}

TEST_FAILURES=0

run_test() {
    local test_name="$1"

    set +e
    "${test_name}"
    local rc=$?
    set -e

    if [[ ${rc} -ne 0 ]]; then
        echo "FAIL: ${test_name}"
        TEST_FAILURES=$((TEST_FAILURES + 1))
    else
        echo "PASS: ${test_name}"
    fi
}

test_http_code_to_state_connected() {
    assert_eq "ON" "$(httpCodeToState "200")" "200 maps to ON"
}

test_http_code_to_state_disconnected() {
    assert_eq "OFF" "$(httpCodeToState "503")" "503 maps to OFF"
}

test_http_code_to_state_unreachable() {
    assert_eq "OFF" "$(httpCodeToState "")" "unreachable metrics endpoint maps to OFF"
}

test_discovery_payload_is_valid_json() {
    local payload
    payload=$(buildDiscoveryPayload)

    echo "${payload}" | jq -e . >/dev/null
}

test_discovery_payload_fields() {
    local payload
    payload=$(buildDiscoveryPayload)

    assert_eq "Tunnel Connected" "$(echo "${payload}" | jq -r '.name')" "discovery name"
    assert_eq "cloudflared_tunnel_connected" "$(echo "${payload}" | jq -r '.unique_id')" "discovery unique_id"
    assert_eq "cloudflared/tunnel_connected/state" "$(echo "${payload}" | jq -r '.state_topic')" "discovery state_topic"
    assert_eq "connectivity" "$(echo "${payload}" | jq -r '.device_class')" "discovery device_class"
    assert_eq "cloudflared" "$(echo "${payload}" | jq -r '.device.identifiers[0]')" "discovery device identifier"
    assert_eq "cloudflared/tunnel_connected/availability" "$(echo "${payload}" | jq -r '.availability_topic')" "discovery availability_topic"
    assert_eq "online" "$(echo "${payload}" | jq -r '.payload_available')" "discovery payload_available"
    assert_eq "offline" "$(echo "${payload}" | jq -r '.payload_not_available')" "discovery payload_not_available"
}

main() {
    run_test test_http_code_to_state_connected
    run_test test_http_code_to_state_disconnected
    run_test test_http_code_to_state_unreachable
    run_test test_discovery_payload_is_valid_json
    run_test test_discovery_payload_fields

    if [[ ${TEST_FAILURES} -ne 0 ]]; then
        echo "${TEST_FAILURES} test(s) failed."
        exit 1
    fi

    echo "All tests passed."
}

main
