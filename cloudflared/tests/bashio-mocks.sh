# Bashio helper mocks used for local shell unit tests.
# This file is intended to be sourced by shell test harnesses.

declare -Ag TEST_CONFIG
TEST_CONFIG=()

bashio::log.trace() { :; }
bashio::log.info() { :; }
bashio::log.debug() { :; }
bashio::log.notice() { :; }
bashio::log.warning() { :; }
bashio::log.error() { :; }

bashio::config.has_value() {
    local key="$1"
    [[ -n "${TEST_CONFIG[$key]:-}" ]]
}

bashio::config.is_empty() {
    local key="$1"
    [[ -z "${TEST_CONFIG[$key]:-}" ]]
}

bashio::config.exists() {
    local key="$1"
    [[ -v TEST_CONFIG[$key] ]]
}

bashio::config.true() {
    local key="$1"
    local value="${TEST_CONFIG[$key]:-}"
    case "${value}" in
        true|1|TRUE|yes|YES) return 0;;
        *) return 1;;
    esac
}

bashio::config() {
    local key="$1"
    printf '%s' "${TEST_CONFIG[$key]:-}"
}

bashio::app.config() {
    printf '%s' "${TEST_APP_CONFIG:-{}}"
}

bashio::var.is_empty() {
    [[ -z "${1:-}" ]]
}

bashio::var.has_value() {
    [[ -n "${1:-}" ]]
}

bashio::var.true() {
    case "${1:-}" in
        true|1|TRUE|yes|YES) return 0;;
        *) return 1;;
    esac
}

# Faithful re-implementation of bashio's JSON helpers (they only depend on jq,
# not on the Supervisor API, so there is no need to stub them out).
bashio::var.json_string() {
    printf '%s' "${1}" | jq -Rs .
}

bashio::var.json() {
    local data=("$@")
    local json=''
    local separator
    local counter=0
    local item

    for i in "${data[@]}"; do
        separator=","
        if [ $((++counter % 2)) -eq 0 ]; then
            separator=":"
            if [[ "${i:0:1}" == "^" ]]; then
                item="${i:1}"
            else
                item=$(bashio::var.json_string "${i}")
            fi
        else
            item=$(bashio::var.json_string "${i}")
        fi
        json="$json$separator$item"
    done

    echo "{${json:1}}"
}

bashio::exit.nok() {
    echo "ERROR: $*" >&2
    exit 1
}

bashio::exit.ok() {
    exit 0
}

bashio::fs.file_exists() {
    [[ -f "$1" ]]
}

bashio::jq() {
    if [[ $# -gt 0 ]]; then
        printf '%s' "${1}"
    fi
}
