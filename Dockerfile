FROM ghcr.io/ozark-connect/uosserver:dd63bc1f3aee-multiarch

LABEL org.opencontainers.image.source="https://github.com/Ozark-Connect/unifi-os-server"

ENV container="docker"
ENV APP_VERSION="5.1.34"
ENV APP_MODEL="UOSSERVER"
ENV PRODUCT_NAME="UniFi OS Server"

STOPSIGNAL SIGRTMIN+3

COPY uos-entrypoint.sh /root/uos-entrypoint.sh

RUN ["chmod", "+x", "/root/uos-entrypoint.sh"]
ENTRYPOINT ["/root/uos-entrypoint.sh"]
