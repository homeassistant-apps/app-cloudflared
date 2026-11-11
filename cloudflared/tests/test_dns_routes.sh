#!/usr/bin/env bash
# SC1091: the app script is sourced relative to this file.
# shellcheck disable=SC1091
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../rootfs/etc/s6-overlay/s6-rc.d/prepare/run.sh"

assert_route_status() {
    local expected="$1"
    local name="$2"
    local output="$3"
    local status=0

    printf '%s\n' "${output}" | validateDNSRoute "ha.example.com" || status=$?
    if [[ "${status}" != "${expected}" ]]; then
        printf 'FAIL: %s: expected status %s, got %s\n' "${name}" "${expected}" "${status}"
        exit 1
    fi
    printf 'PASS: %s\n' "${name}"
}

# Messages returned by cfapi.DNSRouteResult.SuccessSummary in cloudflared.
assert_route_status 0 "new record" \
    '{"level":"info","message":"Added CNAME ha.example.com which will route to this tunnel"}'
assert_route_status 0 "updated record" \
    '{"level":"info","message":"ha.example.com updated to route to your tunnel"}'
assert_route_status 0 "existing record" \
    '{"level":"info","message":"ha.example.com is already configured to route to your tunnel"}'
assert_route_status 1 "old zone appended to new hostname" \
    '{"level":"info","message":"ha.example.com.old-domain.com is already configured to route to your tunnel"}'
assert_route_status 1 "new record in wrong zone" \
    '{"level":"info","message":"Added CNAME ha.example.com.old-domain.com which will route to this tunnel"}'
assert_route_status 1 "different hostname in same zone" \
    '{"level":"info","message":"other.example.com updated to route to your tunnel"}'
assert_route_status 0 "unrelated log messages and retry warnings" \
    $'Retrying DNS setup...\n{"level":"warn","message":"Version is outdated"}\n{"level":"info","message":"Added CNAME ha.example.com which will route to this tunnel"}'
assert_route_status 1 "missing result" '{"level":"info","message":"Starting tunnel"}'
assert_route_status 1 "empty output" ''
assert_route_status 1 "invalid JSON" 'not JSON'
assert_route_status 1 "duplicate results" \
    $'{"message":"ha.example.com is already configured to route to your tunnel"}\n{"message":"ha.example.com.old-domain.com is already configured to route to your tunnel"}'

echo "All DNS route tests passed."
