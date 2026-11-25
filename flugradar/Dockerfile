# readsb + tar1090 + nginx fertig konfiguriert (SDR-Enthusiasts, multi-arch)
FROM ghcr.io/sdr-enthusiasts/docker-adsb-ultrafeeder:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends jq curl ca-certificates python3 python3-pip \
    && pip3 install --no-cache-dir --break-system-packages skyfield==1.49 \
    && rm -rf /var/lib/apt/lists/*

COPY start.sh /start.sh
COPY sensoren.sh /sensoren.sh
COPY flugwetter.py /flugwetter.py
COPY extras.py /extras.py
RUN chmod +x /start.sh /sensoren.sh /flugwetter.py /extras.py

ENTRYPOINT ["/start.sh"]
