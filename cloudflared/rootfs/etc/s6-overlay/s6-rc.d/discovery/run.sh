#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant App: Cloudflared
#
# Announces this app's metrics endpoint via Supervisor Discovery, so
# companion integrations (e.g. Cloudflare Tunnel Monitor) can find and
# configure it automatically, without the user typing in a URL by hand.
# ==============================================================================

# ------------------------------------------------------------------------------
# Builds the discovery config payload announcing this app's metrics endpoint
# ------------------------------------------------------------------------------
buildDiscoveryConfig() {
    local hostname="$1"
    bashio::var.json metrics_url "http://${hostname}:36500/metrics"
}

# ==============================================================================
# RUN LOGIC
# ------------------------------------------------------------------------------
main() {
    bashio::log.trace "${FUNCNAME[0]}"

    local hostname
    hostname=$(bashio::app.hostname)

    bashio::log.info "Announcing metrics endpoint via Supervisor Discovery"
    bashio::discovery "cloudflare_tunnel_monitor" "$(buildDiscoveryConfig "${hostname}")" ||
        bashio::log.warning "Failed to announce metrics endpoint via Supervisor Discovery"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
