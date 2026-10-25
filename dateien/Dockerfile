FROM debian:trixie-slim

ARG BUILD_ARCH
# FileBrowser Quantum (gepflegter Nachfolger von File Browser) in fester Version,
# geprüft gegen die Prüfsumme der offiziellen Release-Datei
ARG FBQ_VERSION=v2.0.2-stable
ARG FBQ_SHA_ARM64=03eac074efc1b0ef3cb39882c04eeee26027049d261b6b6706650d4ac2d8e21c
ARG FBQ_SHA_AMD64=5710dc6f51d77f1db884eace44f6952286c49f2ce40b6a59af37e0dc7c4a8bbd

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq mount util-linux librsvg2-bin \
    && rm -rf /var/lib/apt/lists/* \
    && case "${BUILD_ARCH}" in \
         aarch64) FBQ_ARCH=arm64; FBQ_SHA="${FBQ_SHA_ARM64}" ;; \
         amd64)   FBQ_ARCH=amd64; FBQ_SHA="${FBQ_SHA_AMD64}" ;; \
         *) echo "Nicht unterstützte Architektur: ${BUILD_ARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /usr/local/bin/filebrowser \
         "https://github.com/gtsteffaniak/filebrowser/releases/download/${FBQ_VERSION}/linux-${FBQ_ARCH}-filebrowser" \
    && echo "${FBQ_SHA}  /usr/local/bin/filebrowser" | sha256sum -c - \
    && chmod +x /usr/local/bin/filebrowser

# Design (Neon wie das SecuriPi-Panel) und Logo; PNG-Fassung fürs iPhone-Homescreen-Symbol
COPY neon.css logo.svg /opt/dateien/
RUN rsvg-convert -w 512 -h 512 -b "#070b12" /opt/dateien/logo.svg -o /opt/dateien/logo.png

COPY run.sh gaeste.sh /
RUN chmod +x /run.sh /gaeste.sh

CMD ["/run.sh"]
