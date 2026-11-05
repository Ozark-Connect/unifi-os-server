FROM ghcr.io/ozark-connect/uosserver:fd48e96764d3-multiarch

LABEL org.opencontainers.image.source="https://github.com/Ozark-Connect/unifi-os-server"

ENV container="docker"
ENV APP_VERSION="6.0.21"
ENV APP_MODEL="UOSSERVER"
ENV PRODUCT_NAME="UniFi OS Server"

STOPSIGNAL SIGRTMIN+3

COPY uos-entrypoint.sh /root/uos-entrypoint.sh
COPY patch-core-features.py /root/patch-core-features.py

RUN ["chmod", "+x", "/root/uos-entrypoint.sh", "/root/patch-core-features.py"]
ENTRYPOINT ["/root/uos-entrypoint.sh"]
