ARG DEBIAN_VERSION=trixie-20260202-slim

FROM debian:${DEBIAN_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*

COPY ./docker/usersetup.sh /usr/local/bin/usersetup.sh
RUN chmod +x /usr/local/bin/usersetup.sh

ENTRYPOINT ["/usr/local/bin/usersetup.sh"]
