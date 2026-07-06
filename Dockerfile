FROM alpine:latest AS base

COPY --from=crazymax/alpine-s6 / /

RUN apk update \
    && apk add --no-cache curl xz squid clamav clamav-daemon libatomic openssl \
    && rm -rf /var/cache/apk/*

# ---
# c-icap / c-icap-modules aren't packaged for Alpine: build them from source
# here, then copy just the resulting binaries into the final image below.

FROM base AS icap-builder

ARG C_ICAP_VERSION=0.6.5
ARG C_ICAP_MODULES_VERSION=0.5.7

RUN apk add --no-cache build-base pkgconfig

WORKDIR /usr/src

# Installed for real (not just DESTDIR-staged) so c-icap-modules' configure
# script can find real headers/libs/pkg-config files to build against.
RUN curl -LO "https://downloads.sourceforge.net/project/c-icap/c-icap/0.6.x/c_icap-${C_ICAP_VERSION}.tar.gz" \
    && tar xzf "c_icap-${C_ICAP_VERSION}.tar.gz" \
    && cd "c_icap-${C_ICAP_VERSION}" \
    && ./configure --prefix=/usr --sysconfdir=/etc/c-icap --localstatedir=/var \
    && make -j"$(nproc)" \
    && make install \
    && make install DESTDIR=/out

RUN curl -LO "https://downloads.sourceforge.net/project/c-icap/c-icap-modules/0.5.x/c_icap_modules-${C_ICAP_MODULES_VERSION}.tar.gz" \
    && tar xzf "c_icap_modules-${C_ICAP_MODULES_VERSION}.tar.gz" \
    && cd "c_icap_modules-${C_ICAP_MODULES_VERSION}" \
    && ./configure --prefix=/usr --sysconfdir=/etc/c-icap \
    && make -j"$(nproc)" \
    && make install \
    && make install DESTDIR=/out

# ---

FROM base AS final

COPY --from=icap-builder /out/usr/ /usr/
COPY --from=icap-builder /out/etc/c-icap/ /etc/c-icap/
COPY start-squid.sh /usr/local/bin/
COPY squid.conf /etc/squid/squid.conf
COPY clamd_mod.conf virus_scan.conf /etc/c-icap/
COPY cont-init.d/ /etc/cont-init.d/
COPY services.d/ /etc/services.d/

RUN chmod +x /usr/local/bin/start-squid.sh /etc/cont-init.d/* /etc/services.d/*/run \
    # Enable the antivirus ICAP service in c-icap.
    && echo "Include /etc/c-icap/virus_scan.conf" >> /etc/c-icap/c-icap.conf \
    # c-icap's default log paths (/usr/var/log/*) don't exist on Alpine; use
    # a conventional log dir instead (created at container start, see
    # cont-init.d/10-clamav-init).
    && sed -i \
         -e 's|^ServerLog .*|ServerLog /var/log/c-icap/server.log|' \
         -e 's|^AccessLog .*|AccessLog /var/log/c-icap/access.log|' \
         /etc/c-icap/c-icap.conf \
    # Alpine ships clamd.conf/freshclam.conf with a leading "Example" directive
    # that must be removed before the daemons will actually start.
    && sed -i '/^Example/d' /etc/clamav/clamd.conf /etc/clamav/freshclam.conf \
    && sed -i \
         -e 's|^#\?LocalSocket .*|LocalSocket /run/clamav/clamd.sock|' \
         -e 's|^#\?Foreground .*|Foreground yes|' \
         /etc/clamav/clamd.conf \
    # DatabaseMirror/Checks are rendered from env vars at container start
    # (see cont-init.d/05-render-config).
    && sed -i \
         -e 's|^#\?DatabaseMirror .*|DatabaseMirror __CLAMAV_DATABASE_MIRROR__|' \
         /etc/clamav/freshclam.conf \
    && echo "Checks __CLAMAV_UPDATE_CHECKS__" >> /etc/clamav/freshclam.conf

# Persist the ClamAV signature database and the SSL-bump CA across container
# restarts (regenerating the CA would require clients to re-trust it).
VOLUME /var/lib/clamav
VOLUME /etc/squid/ssl_cert

HEALTHCHECK --interval=60s --timeout=15s --start-period=180s \
            CMD curl -LSs 'https://api.ipify.org' || kill 1

CMD ["/usr/local/bin/start-squid.sh"]
ENTRYPOINT ["/init"]
