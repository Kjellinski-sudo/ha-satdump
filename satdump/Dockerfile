FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends satdump jq ca-certificates findutils \
    && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
