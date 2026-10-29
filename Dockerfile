FROM ghcr.io/ozark-connect/uosserver:c9603dec9010-multiarch

LABEL org.opencontainers.image.source="https://github.com/Ozark-Connect/unifi-os-server"

ENV container="docker"
ENV APP_VERSION="5.1.42"
ENV APP_MODEL="UOSSERVER"
ENV PRODUCT_NAME="UniFi OS Server"

STOPSIGNAL SIGRTMIN+3

# Optional realip config, written by the entrypoint from UOS_TRUSTED_PROXIES.
# The [.] glob lets nginx start when the file does not exist.
RUN sed -i 's|^    merge_slashes off;|&\n    include /etc/nginx/uos-realip[.]conf;|' /etc/nginx/nginx.conf \
    && grep -q 'uos-realip' /etc/nginx/nginx.conf

COPY uos-entrypoint.sh /root/uos-entrypoint.sh

RUN ["chmod", "+x", "/root/uos-entrypoint.sh"]
ENTRYPOINT ["/root/uos-entrypoint.sh"]
