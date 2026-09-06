#!/bin/sh
# ==============================================================================
# Home Assistant App: Cloudflared
#
# Container build of Cloudflared
# ==============================================================================

set -eux

# yq is to avoid depending on Home Assistant API on startup
# mosquitto-clients provides mosquitto_pub, used to report tunnel status via MQTT
apk add --no-cache yq-go="${YQ_VERSION}" mosquitto-clients="${MOSQUITTO_CLIENTS_VERSION}"

# Adapt the architecture to the cloudflared specific names if needed
case "${BUILD_ARCH}" in
"aarch64")
    cloudflared_arch="arm64"
    ;;
*)
    cloudflared_arch="${BUILD_ARCH}"
    ;;
esac

# Download the cloudflared bin
wget -q -O /usr/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${cloudflared_arch}"

# Make the downloaded bin executeable
chmod +x /usr/bin/cloudflared

# Remove legacy cont-init.d services
rm -rf /etc/cont-init.d

# Remove s-6 legacy/deprecated (and not needed) services
rm -f /package/admin/s6-overlay/etc/s6-rc/sources/base/contents.d/legacy-cont-init
rm -f /package/admin/s6-overlay/etc/s6-rc/sources/base/contents.d/fix-attrs
rm -f /package/admin/s6-overlay/etc/s6-rc/sources/top/contents.d/legacy-services
