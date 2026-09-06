#!/usr/bin/env bash
# SC1091: sourced test helpers are loaded dynamically and ShellCheck cannot resolve them here.
# SC2034: TEST_CONFIG is used via indirect associative-array access in the Bashio mock layer.
# SC2154: TEST_CONFIG keys like mqtt_extra_stats look like undefined variable references to
# ShellCheck, but are just associative-array literal keys.
# shellcheck disable=SC1091,SC2034,SC2154
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

test_ready_connections_from_json_connected() {
    assert_eq "4" "$(readyConnectionsFromJson '{"status":200,"readyConnections":4,"connectorId":"x"}')" "readyConnections extracted"
}

test_ready_connections_from_json_disconnected() {
    assert_eq "0" "$(readyConnectionsFromJson '{"status":503,"readyConnections":0,"connectorId":"x"}')" "readyConnections zero when disconnected"
}

test_ready_connections_from_json_unreachable() {
    assert_eq "0" "$(readyConnectionsFromJson "")" "unreachable /ready defaults to 0"
}

test_state_from_ready_json_connected() {
    assert_eq "ON" "$(stateFromReadyJson '{"status":200,"readyConnections":4,"connectorId":"x"}')" "connected maps to ON"
}

test_state_from_ready_json_disconnected() {
    assert_eq "OFF" "$(stateFromReadyJson '{"status":503,"readyConnections":0,"connectorId":"x"}')" "disconnected maps to OFF"
}

test_state_from_ready_json_unreachable() {
    assert_eq "OFF" "$(stateFromReadyJson "")" "unreachable /ready maps to OFF"
}

test_extract_metrics_counter() {
    local metrics_text
    metrics_text=$'cloudflared_tunnel_total_requests 42\ncloudflared_tunnel_request_errors 3\n'

    assert_eq "42" "$(extractMetricsCounter "${metrics_text}" "cloudflared_tunnel_total_requests")" "total_requests extracted"
    assert_eq "3" "$(extractMetricsCounter "${metrics_text}" "cloudflared_tunnel_request_errors")" "request_errors extracted"
}

test_extract_metrics_counter_missing() {
    assert_eq "" "$(extractMetricsCounter "" "cloudflared_tunnel_total_requests")" "missing metric extracts empty"
}

test_extract_edge_locations() {
    local metrics_text
    metrics_text=$'cloudflared_tunnel_server_locations{connection_id="0",edge_location="sjc08"} 0\ncloudflared_tunnel_server_locations{connection_id="0",edge_location="lax11"} 1\ncloudflared_tunnel_server_locations{connection_id="1",edge_location="sjc07"} 1\n'

    local -a locations
    mapfile -t locations < <(extractEdgeLocations "${metrics_text}")

    assert_eq "2" "${#locations[@]}" "only current (value 1) locations extracted"
    assert_eq "lax11" "${locations[0]}" "first current location"
    assert_eq "sjc07" "${locations[1]}" "second current location"
}

test_extract_edge_locations_none() {
    local -a locations
    mapfile -t locations < <(extractEdgeLocations "")

    assert_eq "0" "${#locations[@]}" "no locations when metrics unreachable"
}

test_build_attributes_payload() {
    local payload
    payload=$(buildAttributesPayload "sjc08" "lax11")

    assert_eq "sjc08" "$(echo "${payload}" | jq -r '.edge_locations[0]')" "first edge location in attributes"
    assert_eq "lax11" "$(echo "${payload}" | jq -r '.edge_locations[1]')" "second edge location in attributes"
}

test_build_attributes_payload_empty() {
    local payload
    payload=$(buildAttributesPayload)

    assert_eq "[]" "$(echo "${payload}" | jq -c '.edge_locations')" "empty edge_locations when no connections"
}

test_discovery_payload_is_valid_json() {
    local payload
    payload=$(buildDiscoveryPayload)

    echo "${payload}" | jq -e . >/dev/null
}

test_discovery_payload_fields() {
    TEST_CONFIG=()
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

test_discovery_payload_no_attributes_when_extra_stats_disabled() {
    TEST_CONFIG=()
    local payload
    payload=$(buildDiscoveryPayload)

    assert_eq "null" "$(echo "${payload}" | jq -r '.json_attributes_topic // "null"')" "no json_attributes_topic when mqtt_extra_stats is disabled"
}

test_discovery_payload_has_attributes_when_extra_stats_enabled() {
    TEST_CONFIG=([mqtt_extra_stats]="true")
    local payload
    payload=$(buildDiscoveryPayload)
    TEST_CONFIG=()

    assert_eq "cloudflared/tunnel_connected/attributes" "$(echo "${payload}" | jq -r '.json_attributes_topic')" "json_attributes_topic present when mqtt_extra_stats is enabled"
}

test_sensor_discovery_payload_fields() {
    local payload
    payload=$(buildSensorDiscoveryPayload "Active Connections" "active_connections" "cloudflared/active_connections/state" "connections" "measurement" "mdi:connection")

    assert_eq "Active Connections" "$(echo "${payload}" | jq -r '.name')" "sensor discovery name"
    assert_eq "cloudflared_active_connections" "$(echo "${payload}" | jq -r '.unique_id')" "sensor discovery unique_id"
    assert_eq "cloudflared/active_connections/state" "$(echo "${payload}" | jq -r '.state_topic')" "sensor discovery state_topic"
    assert_eq "connections" "$(echo "${payload}" | jq -r '.unit_of_measurement')" "sensor discovery unit_of_measurement"
    assert_eq "measurement" "$(echo "${payload}" | jq -r '.state_class')" "sensor discovery state_class"
    assert_eq "mdi:connection" "$(echo "${payload}" | jq -r '.icon')" "sensor discovery icon"
    assert_eq "diagnostic" "$(echo "${payload}" | jq -r '.entity_category')" "sensor discovery entity_category"
    assert_eq "cloudflared" "$(echo "${payload}" | jq -r '.device.identifiers[0]')" "sensor discovery device identifier"
}

main() {
    run_test test_ready_connections_from_json_connected
    run_test test_ready_connections_from_json_disconnected
    run_test test_ready_connections_from_json_unreachable
    run_test test_state_from_ready_json_connected
    run_test test_state_from_ready_json_disconnected
    run_test test_state_from_ready_json_unreachable
    run_test test_extract_metrics_counter
    run_test test_extract_metrics_counter_missing
    run_test test_extract_edge_locations
    run_test test_extract_edge_locations_none
    run_test test_build_attributes_payload
    run_test test_build_attributes_payload_empty
    run_test test_discovery_payload_is_valid_json
    run_test test_discovery_payload_fields
    run_test test_discovery_payload_no_attributes_when_extra_stats_disabled
    run_test test_discovery_payload_has_attributes_when_extra_stats_enabled
    run_test test_sensor_discovery_payload_fields

    if [[ ${TEST_FAILURES} -ne 0 ]]; then
        echo "${TEST_FAILURES} test(s) failed."
        exit 1
    fi

    echo "All tests passed."
}

main
