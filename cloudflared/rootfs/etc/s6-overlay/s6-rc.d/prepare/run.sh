#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant App: Cloudflared
#
# Configures the Cloudflare Tunnel and creates the needed DNS entry under the
# given hostname(s)
# ==============================================================================

# ------------------------------------------------------------------------------
# Helper: Executes a command with exponential backoff retry logic
# ------------------------------------------------------------------------------
runWithRetry() {
    local max_retries="${1:-4}"
    local retry_delay="${2:-2}"
    local description="$3"
    shift 3

    local attempt=1
    while [ $attempt -le "$max_retries" ]; do
        if "$@"; then
            return 0
        fi
        bashio::log.warning "Failed to ${description} (Attempt ${attempt}/${max_retries}). Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
        attempt=$((attempt + 1))
        retry_delay=$((retry_delay * 2))
    done

    return 1
}

# ------------------------------------------------------------------------------
# Validates configuration and sets global variables used in the script
# ------------------------------------------------------------------------------
validateConfigAndSetVars() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Validating app configuration..."

    local validHostnameRegex="^(([a-z0-9äöüß]|[a-z0-9äöüß][a-z0-9äöüß\-]*[a-z0-9äöüß])\.)*([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])$"

    # Check for minimum configuration options
    if
        bashio::config.is_empty 'external_hostname' &&
            bashio::config.is_empty 'additional_hosts' &&
            bashio::config.is_empty 'catch_all_service' &&
            bashio::config.is_empty 'nginx_proxy_manager'
    then
        bashio::exit.nok "Cannot run without tunnel_token, external_hostname, additional_hosts, catch_all_service or nginx_proxy_manager. Please set at least one of these app options."
    fi

    # Set and validate 'external_hostname'
    if bashio::config.has_value 'external_hostname'; then
        external_hostname="$(bashio::config 'external_hostname')"
        if ! [[ ${external_hostname} =~ ${validHostnameRegex} ]]; then
            bashio::exit.nok "'${external_hostname}' is not a valid hostname. Please make sure not to include the protocol (e.g. 'https://') nor the port (e.g. ':8123') and only use lowercase characters in the 'external_hostname'."
        fi
    else
        external_hostname=""
    fi
    bashio::log.debug "external_hostname: ${external_hostname}"

    # Set and validate 'additional_hosts'
    if bashio::config.has_value 'additional_hosts'; then
        additional_hosts=$(bashio::jq "$(bashio::app.config)" ".additional_hosts[]")
        readarray -t additional_hosts <<<"${additional_hosts}"

        local additional_host
        local hostname
        local service
        for additional_host in "${additional_hosts[@]}"; do
            bashio::log.debug "Checking host ${additional_host}..."
            hostname=$(bashio::jq "${additional_host}" ".hostname")
            service=$(bashio::jq "${additional_host}" ".service")
            if bashio::var.is_empty "${hostname}" && bashio::var.is_empty "${service}"; then
                bashio::exit.nok "'hostname' and 'service' in 'additional_hosts' are empty, please enter a valid String"
            fi
            if bashio::var.is_empty "${hostname}"; then
                bashio::exit.nok "'hostname' in 'additional_hosts' for service ${service} is empty, please enter a valid String"
            fi
            # Check if hostname of 'additional_host' includes a valid hostname
            if ! [[ ${hostname} =~ ${validHostnameRegex} ]]; then
                bashio::exit.nok "'${hostname}' in 'additional_hosts' is not a valid hostname. Please make sure not to include the protocol (e.g. 'https://') nor the port (e.g. ':8123') and only use lowercase characters in the 'hostname'."
            fi
            if bashio::var.is_empty "${service}"; then
                bashio::exit.nok "'service' in 'additional_hosts' for hostname ${hostname} is empty, please enter a valid String"
            fi
        done
    else
        additional_hosts=()
    fi

    # Check if 'catch_all_service' is included in config with an empty String
    if bashio::config.exists 'catch_all_service' && bashio::config.is_empty 'catch_all_service'; then
        bashio::exit.nok "'catch_all_service' is defined as an empty String. Please remove 'catch_all_service' from the configuration or enter a valid String"
    fi

    # Check if 'catch_all_service' and 'nginx_proxy_manager' are both included in config.
    if bashio::config.has_value 'catch_all_service' && bashio::config.true 'nginx_proxy_manager'; then
        bashio::exit.nok "The config includes 'nginx_proxy_manager' and 'catch_all_service'. Please delete one of them since they are mutually exclusive"
    fi

    # Set other global variables
    tunnel_uuid=""
    data_path="/data"

    bashio::log.debug "Checking Home Assistant port and if SSL is used..."
    local ha_config_file="${HOMEASSISTANT_CONFIG_FILE:-/homeassistant/configuration.yaml}"
    local ha_storage_http="${HOMEASSISTANT_STORAGE_HTTP:-/homeassistant/.storage/http}"
    local ha_port="8123"
    local ha_ssl="false"

    if bashio::var.is_empty "${external_hostname}"; then
        bashio::log.debug "No external_hostname configured, skipping check of Home Assistant port and SSL"
    else
        local ha_port_from_storage=""
        local ha_ssl_from_storage=""

        if [[ -f "${ha_storage_http}" ]]; then
            local storage_base=".data"
            local storage_version=""
            storage_version=$(yq '.version' "${ha_storage_http}" 2>/dev/null || true)
            case "${storage_version}" in
                1)
                    storage_base=".data"
                    ;;
                2)
                    storage_base=".data.stable"
                    ;;
                *)
                    bashio::log.warning "Unknown Home Assistant storage version '${storage_version}' in ${ha_storage_http}, falling back to version 2 behavior"
                    storage_base=".data.stable"
                    ;;
            esac

            ha_port_from_storage=$(yq "${storage_base}.server_port" "${ha_storage_http}" 2>/dev/null || true)
            local ha_ssl_cert_from_storage=""
            local ha_ssl_key_from_storage=""
            local storage_is_map=""
            storage_is_map=$(yq "${storage_base} | select(type == \"!!map\")" "${ha_storage_http}" 2>/dev/null || true)

            if [[ -n "${storage_is_map}" ]]; then
                ha_ssl_cert_from_storage=$(yq "${storage_base}.ssl_certificate" "${ha_storage_http}" 2>/dev/null || true)
                ha_ssl_key_from_storage=$(yq "${storage_base}.ssl_key" "${ha_storage_http}" 2>/dev/null || true)

                if [[ -n "${ha_ssl_cert_from_storage}" || -n "${ha_ssl_key_from_storage}" ]]; then
                    if [[ "${ha_ssl_cert_from_storage}" != "null" && -n "${ha_ssl_cert_from_storage}" ]] && \
                        [[ "${ha_ssl_key_from_storage}" != "null" && -n "${ha_ssl_key_from_storage}" ]]; then
                        ha_ssl_from_storage="true"
                        bashio::log.debug "Read Home Assistant SSL from ${ha_storage_http}: ${ha_ssl_from_storage}"
                    else
                        ha_ssl_from_storage="false"
                        bashio::log.debug "Read Home Assistant SSL from ${ha_storage_http}: ${ha_ssl_from_storage}"
                    fi
                fi
            fi

            if [[ -n "${ha_port_from_storage}" && "${ha_port_from_storage}" != "null" ]]; then
                ha_port="${ha_port_from_storage}"
                bashio::log.debug "Read Home Assistant port from ${ha_storage_http}: ${ha_port}"
            fi

            if [[ "${ha_ssl_from_storage}" == "true" ]]; then
                ha_ssl="true"
            elif [[ "${ha_ssl_from_storage}" == "false" ]]; then
                ha_ssl="false"
            fi
        fi

        if yq . "${ha_config_file}" >/dev/null 2>&1; then
            if [[ -z "${ha_port_from_storage}" || "${ha_port_from_storage}" == "null" ]]; then
                ha_port=$(yq ".http.server_port // ${ha_port}" "${ha_config_file}")
                bashio::log.debug "Read Home Assistant port from ${ha_config_file}: ${ha_port}"
            fi

            if [[ -z "${ha_ssl_from_storage}" || "${ha_ssl_from_storage}" == "null" ]]; then
                ha_ssl=$(yq '.http | (has("ssl_certificate") and has("ssl_key"))' "${ha_config_file}")
                bashio::log.debug "Read Home Assistant SSL from ${ha_config_file}: ${ha_ssl}"
            fi
        else
            bashio::log.warning "Unable to parse Home Assistant configuration file at ${ha_config_file}, assuming port ${ha_port} and no SSL"
        fi
    fi

    bashio::log.debug "ha_port: ${ha_port}"
    bashio::log.debug "ha_ssl: ${ha_ssl}"

    local ha_protocol
    if bashio::var.true "${ha_ssl}"; then
        ha_protocol="https"
    else
        ha_protocol="http"
    fi
    bashio::log.debug "ha_protocol: ${ha_protocol}"

    ha_url="${ha_protocol}://homeassistant:${ha_port}"
    bashio::log.debug "ha_url: ${ha_url}"

    if bashio::config.has_value 'tunnel_name'; then
        tunnel_name="$(bashio::config 'tunnel_name')"
    else
        tunnel_name="homeassistant"
    fi
    bashio::log.debug "tunnel_name: ${tunnel_name}"
}

# ------------------------------------------------------------------------------
# Checks if Cloudflare services are reachable
# ------------------------------------------------------------------------------
checkConnectivity() {
    local pass_test=true

    # Check for region1 TCP
    bashio::log.debug "Checking region1.v2.argotunnel.com TCP port 7844"
    if ! nc -z -w 1 region1.v2.argotunnel.com 7844 &>/dev/null; then
        bashio::log.warning "region1.v2.argotunnel.com TCP port 7844 not reachable"
        pass_test=false
    fi

    # Check for region1 UDP
    bashio::log.debug "Checking region1.v2.argotunnel.com UDP port 7844"
    if ! nc -z -u -w 1 region1.v2.argotunnel.com 7844 &>/dev/null; then
        bashio::log.warning "region1.v2.argotunnel.com UDP port 7844 not reachable"
        pass_test=false
    fi

    # Check for region2 TCP
    bashio::log.debug "Checking region2.v2.argotunnel.com TCP port 7844"
    if ! nc -z -w 1 region2.v2.argotunnel.com 7844 &>/dev/null; then
        bashio::log.warning "region2.v2.argotunnel.com TCP port 7844 not reachable"
        pass_test=false
    fi

    # Check for region2 UDP
    bashio::log.debug "Checking region2.v2.argotunnel.com UDP port 7844"
    if ! nc -z -u -w 1 region2.v2.argotunnel.com 7844 &>/dev/null; then
        bashio::log.warning "region2.v2.argotunnel.com UDP port 7844 not reachable"
        pass_test=false
    fi

    # Check for API TCP
    bashio::log.debug "Checking api.cloudflare.com TCP port 443"
    if ! nc -z -w 1 api.cloudflare.com 443 &>/dev/null; then
        bashio::log.warning "api.cloudflare.com TCP port 443 not reachable"
        pass_test=false
    fi

    if bashio::var.false ${pass_test}; then
        bashio::log.warning "Some necessary services may not be reachable from your host."
        bashio::log.warning "Please review lines above and check your firewall/router settings."
    fi

}

# ------------------------------------------------------------------------------
# Check if Cloudflared certificate (authorization) is available
# ------------------------------------------------------------------------------
hasCertificate() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Checking for existing certificate..."
    if bashio::fs.file_exists "${data_path}/cert.pem"; then
        bashio::log.info "Existing certificate found"
        return "${__BASHIO_EXIT_OK}"
    fi

    bashio::log.notice "No certificate found"
    return "${__BASHIO_EXIT_NOK}"
}

# ------------------------------------------------------------------------------
# Create cloudflare certificate
# ------------------------------------------------------------------------------
createCertificate() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating new certificate..."
    bashio::log.notice
    bashio::log.notice "Please follow the Cloudflare Auth-Steps:"
    bashio::log.notice
    cloudflared tunnel login || bashio::exit.nok "Cloudflare authentication failed"

    bashio::log.info "Authentication successfull, moving auth file to the '${data_path}' folder"

    mv /root/.cloudflared/cert.pem "${data_path}/cert.pem" || bashio::exit.nok "Failed to move auth file"

    hasCertificate || bashio::exit.nok "Failed to create certificate"
}

# ------------------------------------------------------------------------------
# Check if Cloudflare Tunnel is existing
# ------------------------------------------------------------------------------
_get_tunnel_name() {
    set -o pipefail
    cloudflared --origincert="${data_path}/cert.pem" tunnel \
        list --output="json" --id="${tunnel_uuid}" | jq -er '.[].name'
}

hasTunnel() {
    bashio::log.trace "${FUNCNAME[0]}:"
    bashio::log.info "Checking for existing tunnel..."

    # Check if tunnel file(s) exist
    if ! bashio::fs.file_exists "${data_path}/tunnel.json"; then
        bashio::log.notice "No tunnel file found"
        return "${__BASHIO_EXIT_NOK}"
    fi

    # Get tunnel UUID from JSON
    tunnel_uuid="$(bashio::jq "${data_path}/tunnel.json" ".TunnelID")"

    bashio::log.info "Existing tunnel with ID ${tunnel_uuid} found"

    # Get tunnel name from Cloudflare API by tunnel id with exponential retry logic
    bashio::log.info "Checking if existing tunnel matches name given in config"

    local existing_tunnel_name
    if existing_tunnel_name=$(runWithRetry 4 2 "query Cloudflare API for tunnel name" _get_tunnel_name); then
        bashio::log.debug "Existing Cloudflare Tunnel name: $existing_tunnel_name"
    else
        bashio::log.error "Could not verify tunnel name due to a persistent network or API error."
        bashio::exit.nok
    fi

    if [[ $tunnel_name != "$existing_tunnel_name" ]]; then
        bashio::log.error "Existing Cloudflare Tunnel name does not match app config."
        bashio::log.error "---------------------------------------"
        bashio::log.error "App Configuration tunnel name: ${tunnel_name}"
        bashio::log.error "Tunnel credentials file tunnel name: ${existing_tunnel_name}"
        bashio::log.error "---------------------------------------"
        bashio::log.error "Align app configuration to match existing tunnel credential file"
        bashio::log.error "or re-install the app."
        bashio::exit.nok
    fi
    bashio::log.info "Existing Cloudflare Tunnel name matches config, proceeding with existing tunnel file"

    return "${__BASHIO_EXIT_OK}"
}

# ------------------------------------------------------------------------------
# Create Cloudflare Tunnel with name from HA-App-Config
# ------------------------------------------------------------------------------
createTunnel() {
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating new tunnel..."

    if ! runWithRetry 4 2 "create tunnel" cloudflared --origincert="${data_path}/cert.pem" --cred-file="${data_path}/tunnel.json" tunnel --loglevel "${CLOUDFLARED_LOG}" create "${tunnel_name}"; then
        bashio::exit.nok "Failed to create tunnel after multiple attempts.
    Please check the Cloudflare Zero Trust Dashboard for an existing tunnel with the name ${tunnel_name} and delete it:
    Visit https://one.dash.cloudflare.com, then click on Networks -> Tunnels"
    fi

    bashio::log.debug "Created new tunnel: $(cat "${data_path}"/tunnel.json)"

    hasTunnel || bashio::exit.nok "Failed to create tunnel"
}

# ------------------------------------------------------------------------------
# Create Cloudflare config with variables from HA-App-Config
# ------------------------------------------------------------------------------
createConfig() {
    local config
    bashio::log.trace "${FUNCNAME[0]}"
    bashio::log.info "Creating config file..."

    # Add tunnel information
    config=$(bashio::jq "{\"tunnel\":\"${tunnel_uuid}\"}" ".")
    config=$(bashio::jq "${config}" ".\"credentials-file\" += \"${data_path}/tunnel.json\"")

    # Add Service for Home Assistant if 'external_hostname' is set
    if bashio::config.has_value 'external_hostname'; then
        config=$(bashio::jq "${config}" ".\"ingress\" += [{\"hostname\": \"${external_hostname}\", \"service\": \"${ha_url}\"}]")
    fi

    # Check for configured additional hosts and add them if existing
    local additional_host
    local disableChunkedEncoding
    for additional_host in "${additional_hosts[@]}"; do
        # Check for originRequest configuration option: disableChunkedEncoding
        disableChunkedEncoding=$(bashio::jq "${additional_host}" ". | select(.disableChunkedEncoding != null) | .disableChunkedEncoding ")
        if ! [[ ${disableChunkedEncoding} == "" ]]; then
            additional_host=$(bashio::jq "${additional_host}" "del(.disableChunkedEncoding)")
            additional_host=$(bashio::jq "${additional_host}" ".originRequest += {\"disableChunkedEncoding\": ${disableChunkedEncoding}}")
        fi

        # Add additional_host config to ingress config
        config=$(bashio::jq "${config}" ".ingress[.ingress | length ] |= . + ${additional_host}")
    done

    # Check if NGINX Proxy Manager is used to finalize configuration
    if bashio::config.true 'nginx_proxy_manager'; then

        bashio::log.warning "Running with Nginxproxymanager support, make sure the app is installed and running."
        config=$(bashio::jq "${config}" ".\"ingress\" += [{\"service\": \"http://a0d7b954-nginxproxymanager:80\"}]")
    else

        # Check if catch all service is defined
        if bashio::config.has_value 'catch_all_service'; then

            bashio::log.info "Runing with Catch all Service"
            # Setting catch all service to defined URL
            config=$(bashio::jq "${config}" ".\"ingress\" += [{\"service\": \"$(bashio::config 'catch_all_service')\"}]")
        else
            # Finalize config without NPM support and catch all service, sending all other requests to HTTP:404
            config=$(bashio::jq "${config}" ".\"ingress\" += [{\"service\": \"http_status:404\"}]")
        fi
    fi

    # Deactivate TLS verification for all services
    config=$(bashio::jq "${config}" ".ingress[].originRequest += {\"noTLSVerify\": true}")

    # Write content of config variable to config file for cloudflared
    local default_config="/tmp/config.json"
    bashio::jq "${config}" "." >"${default_config}"

    # Validate config using cloudflared
    bashio::log.info "Validating config file..."
    bashio::log.debug "Validating created config file: $(bashio::jq "${default_config}" ".")"
    cloudflared tunnel --config="${default_config}" --loglevel "${CLOUDFLARED_LOG}" ingress validate ||
        bashio::exit.nok "Validation of Config failed, please check the logs above."

    bashio::log.debug "Sucessfully created config file: $(bashio::jq "${default_config}" ".")"
}

# ------------------------------------------------------------------------------
# Read the actual DNS hostname from cloudflared's JSON success log.
# The API may append the certificate's zone to a hostname from another domain.
# ------------------------------------------------------------------------------
validateDNSRoute() {
    local hostname="$1"
    local routed_hostname

    if ! routed_hostname=$(jq -Rers '
        [split("\n")[] | fromjson? | .message? // empty |
            capture("^(?:Added CNAME )?(?<hostname>[^ ]+) (?:which will route to this tunnel|updated to route to your tunnel|is already configured to route to your tunnel)$").hostname] |
        if length == 1 then .[0] else error("Expected one DNS route result") end
    '); then
        bashio::log.error "Could not verify the DNS entry for ${hostname}."
        return 1
    fi

    if [[ "${routed_hostname}" != "${hostname}" ]]; then
        bashio::log.warning "Cloudflare routed ${routed_hostname} instead of ${hostname}. The saved certificate authorizes a different DNS zone."
        bashio::log.warning "Remove the unintended DNS record ${routed_hostname} from Cloudflare."
        return 2
    fi
}

# ------------------------------------------------------------------------------
# Create a DNS route and verify that Cloudflare used the requested hostname.
# Return 2 for a zone mismatch so the caller can request fresh authorization.
# ------------------------------------------------------------------------------
createDNSRoute() {
    local hostname="$1"
    local output

    bashio::log.info "Creating DNS entry ${hostname}..."
    # Force info-level JSON for this command so the result is available even when
    # the user configured a higher log level for the tunnel itself.
    if ! output=$(runWithRetry 4 2 "create DNS entry for ${hostname}" \
        cloudflared --origincert="${data_path}/cert.pem" tunnel --loglevel info --logformat json \
        route dns -f "${tunnel_uuid}" "${hostname}" 2>&1); then
        printf '%s\n' "${output}"
        return 1
    fi
    printf '%s\n' "${output}"

    printf '%s\n' "${output}" | validateDNSRoute "${hostname}"
}

# ------------------------------------------------------------------------------
# Create cloudflare DNS entry for external hostname and additional hosts
# ------------------------------------------------------------------------------
createDNS() {
    bashio::log.trace "${FUNCNAME[0]}"

    local hostnames=()
    if bashio::var.has_value "${external_hostname}"; then
        hostnames+=("${external_hostname}")
    fi

    local additional_host
    for additional_host in "${additional_hosts[@]}"; do
        hostnames+=("$(bashio::jq "${additional_host}" ".hostname")")
    done

    local hostname
    local status
    local reauthenticated=false
    for hostname in "${hostnames[@]}"; do
        if createDNSRoute "${hostname}"; then
            continue
        else
            status=$?
        fi

        if [[ "${status}" != 2 ]]; then
            bashio::exit.nok "Failed to create DNS entry ${hostname}."
        fi
        if [[ "${reauthenticated}" == true ]]; then
            bashio::exit.nok "DNS zone still does not match ${hostname}. All locally managed hostnames must use the authorized zone. Use a remotely managed tunnel for multiple domains."
        fi

        bashio::log.notice "Please authorize the domain for ${hostname} using the login link below. The existing tunnel will be kept."
        createCertificate
        reauthenticated=true
        createDNSRoute "${hostname}" || bashio::exit.nok "Failed to create DNS entry ${hostname} after authentication. Select the domain matching ${hostname}, or use a remotely managed tunnel for multiple domains."
    done
}

# ------------------------------------------------------------------------------
# Set Cloudflared log level
# ------------------------------------------------------------------------------
setCloudflaredLogLevel() {

    # Set cloudflared log to "info" as default
    CLOUDFLARED_LOG="info"

    # Check if user wishes to change log severity
    if bashio::config.has_value 'run_parameters'; then
        bashio::log.trace "bashio::config.has_value 'run_parameters'"
        for run_parameter in $(bashio::config 'run_parameters'); do
            bashio::log.trace "Checking run_parameter: ${run_parameter}"
            if [[ $run_parameter == --loglevel=* ]]; then
                CLOUDFLARED_LOG=${run_parameter#*=}
                bashio::log.trace "Setting CLOUDFLARED_LOG to: ${run_parameter#*=}"
            fi
        done
    fi

    bashio::log.debug "Cloudflared log level set to \"${CLOUDFLARED_LOG}\""

}

# ==============================================================================
# RUN LOGIC
# ------------------------------------------------------------------------------
main() {
    bashio::log.trace "${FUNCNAME[0]}"

    setCloudflaredLogLevel

    # Run connectivity checks if debug mode activated
    if bashio::debug; then
        bashio::log.debug "Checking connectivity to Cloudflare"
        checkConnectivity
    fi

    # Run service with tunnel token without creating config
    if bashio::config.has_value 'tunnel_token'; then
        bashio::log.info "Using Cloudflare Remote Management Tunnel"
        bashio::log.info "All app configuration options except tunnel_token will be ignored."
        bashio::exit.ok
    fi

    validateConfigAndSetVars

    if ! hasCertificate; then
        createCertificate
    fi

    if ! hasTunnel; then
        createTunnel
    fi

    createConfig

    createDNS

    bashio::log.info "Finished setting up the Cloudflare Tunnel"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
