FROM debian:trixie-slim

ARG BUILD_ARCH
# Offizielles File-Browser-Programm in fester Version, geprüft gegen die Prüfsumme des Herstellers
ARG FB_VERSION=2.63.23
ARG FB_SHA_ARM64=c55b3450b6ac07ef73b5b49f0b2955a8e755100b71af1df73f9e5d25b12fd27a
ARG FB_SHA_AMD64=b14db2bb8033caa3f80205eb6578b2ed0744ebd9e716b790bc4a9703ce909e88

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq mount util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && case "${BUILD_ARCH}" in \
         aarch64) FB_ARCH=arm64; FB_SHA="${FB_SHA_ARM64}" ;; \
         amd64)   FB_ARCH=amd64; FB_SHA="${FB_SHA_AMD64}" ;; \
         *) echo "Nicht unterstützte Architektur: ${BUILD_ARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/fb.tar.gz \
         "https://github.com/filebrowser/filebrowser/releases/download/v${FB_VERSION}/linux-${FB_ARCH}-filebrowser.tar.gz" \
    && echo "${FB_SHA}  /tmp/fb.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/fb.tar.gz -C /usr/local/bin filebrowser \
    && rm /tmp/fb.tar.gz \
    && filebrowser version

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
