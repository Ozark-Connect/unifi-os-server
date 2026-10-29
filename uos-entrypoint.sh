#!/bin/bash

# Persist UOS_UUID env var
if [ ! -f /data/uos_uuid ]; then
    if [ -n "${UOS_UUID+1}" ]; then
        echo "Setting UOS_UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    else
        echo "No UOS_UUID present, generating..."
        UUID=$(cat /proc/sys/kernel/random/uuid)

        # Spoof a v5 UUID
        UOS_UUID=$(echo $UUID | sed s/./5/15)
        echo "Setting UOS_UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    fi
fi

ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" == "amd64" ]; then
    FIRMWARE_PLATFORM=linux-x64
elif [ "$ARCH" == "arm64" ]; then
    FIRMWARE_PLATFORM=arm64
else
    echo "FIRMWARE_PLATFORM not found for $ARCH"
    exit 1
fi

echo "Setting APP_MODEL to $APP_MODEL"
echo "Setting APP_VERSION to $APP_VERSION"
echo "Setting FIRMWARE_PLATFORM to $FIRMWARE_PLATFORM"
echo "Setting PRODUCT_NAME to $PRODUCT_NAME"

# Read version from package.json and write version string
echo "$APP_MODEL.0000000.$APP_VERSION.0000000.000000.0000" > /usr/lib/version
echo "$FIRMWARE_PLATFORM" > /usr/lib/platform
echo "$PRODUCT_NAME" > /usr/lib/product_name

# 5.1.34 added /usr/lib/app_model. /sbin/ubnt-tools reads it to look up
# board.sysid (UOSSERVER -> 0xae01) and board.shortname; unifi-core then asks
# ubnt-tools for the console model. Without this file the lookup yields an
# empty model and unifi-core dies with `Unsupported console model: ""`, so it
# never writes the nginx site config and the console never binds :443.
# No trailing newline -- ubnt-tools uses the value as an array subscript.
printf '%s' "$APP_MODEL" > /usr/lib/app_model

# Create eth0 alias to tap0 (requires NET_ADMIN cap & macvlan kernel module loaded on host) 
if [ ! -d "/sys/devices/virtual/net/eth0" ] && [ -d "/sys/devices/virtual/net/tap0" ]; then
    ip link add name eth0 link tap0 type macvlan
    ip link set eth0 up
fi 

# Initialize nginx log dirs
NXINX_LOG_DIR="/var/log/nginx"
if [ ! -d "$NXINX_LOG_DIR" ]; then
    mkdir -p "$NXINX_LOG_DIR"
    chown nginx:nginx "$NXINX_LOG_DIR"
    chmod 755 "$NXINX_LOG_DIR"
fi

# Initialize mongodb log dirs
MONGODB_LOG_DIR="/var/log/mongodb"
if [ ! -d "$MONGODB_LOG_DIR" ]; then
    mkdir -p "$MONGODB_LOG_DIR"
    chown mongodb:mongodb "$MONGODB_LOG_DIR"
    chmod 755 "$MONGODB_LOG_DIR"
fi

# Initialize mongodb lib dirs
MONGODB_LIB_DIR="/var/lib/mongodb"
chown -R mongodb:mongodb "$MONGODB_LIB_DIR"

# Initialize rabbitmq log dirs
RABBITMQ_LOG_DIR="/var/log/rabbitmq"
if [ ! -d "$RABBITMQ_LOG_DIR" ]; then
    mkdir -p "$RABBITMQ_LOG_DIR"
    chown rabbitmq:rabbitmq "$RABBITMQ_LOG_DIR"
    chmod 755 "$RABBITMQ_LOG_DIR"
fi

# Apply Synology patches
SYS_VENDOR="/sys/class/dmi/id/sys_vendor"
if { [ -f "$SYS_VENDOR" ] && grep -q "Synology" "$SYS_VENDOR"; } \
    || [ "${HARDWARE_PLATFORM:-}" = "synology" ]; then

    if [ -n "${HARDWARE_PLATFORM+1}" ]; then
        echo "Setting HARDWARE_PLATFORM to $HARDWARE_PLATFORM"
    else
        echo "Synology hardware found, applying patches..."
    fi

    # Set postgresql overrides
    mkdir -p /etc/systemd/system/postgresql@14-main.service.d
    {
        echo "[Service]"
        echo "PIDFile="
    } > /etc/systemd/system/postgresql@14-main.service.d/override.conf

    # Set rabbitmq overrides
    mkdir -p /etc/systemd/system/rabbitmq-server.service.d
    {
        echo "[Service]"
        echo "Type=simple"
    } > /etc/systemd/system/rabbitmq-server.service.d/override.conf

    # Set ulp-go overrides
    mkdir -p /etc/systemd/system/ulp-go.service.d
    {
        echo "[Service]"
        echo "Type=simple"
    } > /etc/systemd/system/ulp-go.service.d/override.conf

    echo "Synology patches applied!"
fi

# Set UOS_SYSTEM_IP
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"
if [ -n "${UOS_SYSTEM_IP+1}" ]; then
    echo "Setting UOS_SYSTEM_IP to $UOS_SYSTEM_IP"
    if [ ! -f "$UNIFI_SYSTEM_PROPERTIES" ]; then
        echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
    else
        if grep -q "^system_ip=.*" "$UNIFI_SYSTEM_PROPERTIES"; then
            sed -i 's/^system_ip=.*/system_ip='"$UOS_SYSTEM_IP"'/' "$UNIFI_SYSTEM_PROPERTIES"
        else
            echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
        fi
    fi
fi

# Behind a reverse proxy, nginx sees the proxy's address, and UniFi Core passes
# it on as X-Forwarded-For, so the audit log records the proxy instead of the
# client. With UOS_TRUSTED_PROXIES set, nginx takes the client address from
# X-Forwarded-For on requests from those addresses. unifi-core's pre-start hook
# copies nginx.conf.disabled over nginx.conf on every start, so the include
# goes into nginx.conf.disabled.
NGINX_CONF="/etc/nginx/nginx.conf.disabled"
NGINX_REALIP_CONF="/etc/nginx/uos-realip.conf"
rm -f "$NGINX_REALIP_CONF"
if [ -n "${UOS_TRUSTED_PROXIES:-}" ]; then
    echo "Setting UOS_TRUSTED_PROXIES to $UOS_TRUSTED_PROXIES"
    {
        for PROXY in ${UOS_TRUSTED_PROXIES//,/ }; do
            echo "set_real_ip_from $PROXY;"
        done
        echo "real_ip_header X-Forwarded-For;"
        echo "real_ip_recursive on;"
    } > "$NGINX_REALIP_CONF"
    if ! grep -q "uos-realip" "$NGINX_CONF"; then
        sed -i 's|^\( *\)include \+/etc/nginx/mime.types;|&\n\1include /etc/nginx/uos-realip[.]conf;|' "$NGINX_CONF"
    fi
    if ! grep -q "uos-realip" "$NGINX_CONF"; then
        echo "UOS_TRUSTED_PROXIES not applied: no mime.types include in $NGINX_CONF"
    fi
fi

# Start systemd
exec /sbin/init