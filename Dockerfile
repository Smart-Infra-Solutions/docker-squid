FROM alpine:latest AS base

COPY --from=crazymax/alpine-s6 / /

RUN apk update \
    && apk add --no-cache curl xz squid \
    && rm -rf /var/cache/apk/*

# ---

FROM base AS final

COPY start-squid.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/start-squid.sh

HEALTHCHECK --interval=60s --timeout=15s --start-period=180s \
            CMD curl -LSs 'https://api.ipify.org' || kill 1

CMD ["/usr/local/bin/start-squid.sh"]
ENTRYPOINT ["/init"]
