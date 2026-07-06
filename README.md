# docker-squid

[![status-badge](https://ci.si.solutions/api/badges/9/status.svg)](https://ci.si.solutions/repos/9)

Alpine Linux Squid proxy container with s6-overlay, featuring built-in **antivirus
content scanning** (ClamAV via c-icap/ICAP).

[![squid](https://wiki.squid-cache.org/assets/images/squid-logo-lucky-2.gif)](https://wiki.squid-cache.org)

## Features

- [Squid](http://www.squid-cache.org/) forward proxy on Alpine Linux.
- Antivirus scanning of proxied HTTP traffic via [c-icap](https://c-icap.sourceforge.net/)
  (built from source, since it isn't packaged for Alpine) and
  [ClamAV](https://www.clamav.net/) (`clamd` + `freshclam`), wired together as an ICAP
  REQMOD/RESPMOD service.
- Optional SSL-bump (TLS interception) so HTTPS traffic gets scanned too, not just plain
  HTTP — off by default, see [below](#ssl-bump-https-scanning).
- Process supervision via [s6-overlay](https://github.com/just-containers/s6-overlay).
- Most of the behavior above is configurable through environment variables (see below) —
  no need to fork the image or hand-edit config files for common changes.
- A `HEALTHCHECK` that verifies outbound connectivity through the proxy.

## Quick start

```bash
docker run -d \
  --name squid \
  -p 3128:3128 \
  -v squid-clamav-db:/var/lib/clamav \
  ghcr.io/<you>/docker-squid:latest
```

Point a client at `http://<host>:3128` as its HTTP/HTTPS proxy. Plain HTTP responses are
scanned for malware; a response containing a virus (or the
[EICAR test file](https://www.eicar.org/download-anti-malware-testfile/)) is blocked with
an HTTP error instead of being delivered.

The `/var/lib/clamav` volume isn't required, but without it the ~200-300 MB virus
signature database is re-downloaded from scratch on every container start.

## docker-compose

See [`docker-compose.yml`](./docker-compose.yml) for a ready-to-use example:

```bash
docker compose up -d --build
```

## Environment variables

| Variable                    | Default                | Description                                                                                   |
|------------------------------|-------------------------|------------------------------------------------------------------------------------------------|
| `SQUID_HTTP_PORT`            | `3128`                  | Port Squid listens on inside the container (update your `-p`/`ports:` mapping to match).       |
| `SQUID_VISIBLE_HOSTNAME`     | `squid`                 | Value of Squid's `visible_hostname` directive.                                                 |
| `SQUID_CACHE_MEM_MB`         | `256`                   | In-memory cache size (`cache_mem`), in MB.                                                     |
| `SQUID_MAX_OBJECT_SIZE_MB`   | `10`                    | Largest object Squid will cache (`maximum_object_size`), in MB.                                |
| `SQUID_EXTRA_LOCALNET`       | *(empty)*               | Extra space-separated CIDRs/IPs to trust as `localnet` (e.g. `"203.0.113.0/24 198.51.100.5"`). |
| `ENABLE_ANTIVIRUS`           | `true`                  | Set to `false` to disable ICAP scanning entirely and stop clamd/freshclam/c-icap from starting.|
| `ICAP_BYPASS`                | `off`                   | `off` = fail closed, block traffic if c-icap/clamd is unreachable. `on` = fail open (pass unscanned) instead. |
| `ICAP_MAX_OBJECT_SIZE`       | `5M`                    | Largest object c-icap will scan (`virus_scan.MaxObjectSize`); larger objects pass unscanned.    |
| `CLAMAV_DATABASE_MIRROR`     | `database.clamav.net`   | ClamAV signature mirror used by `freshclam` (point this at a private mirror if you run one).    |
| `CLAMAV_UPDATE_CHECKS`       | `24`                    | Times per day `freshclam` checks for signature updates.                                        |
| `ENABLE_SSL_BUMP`            | `false`                 | Set to `true` to intercept and scan HTTPS traffic too (see [SSL-bump](#ssl-bump-https-scanning) below). |
| `SSL_BUMP_CA_CN`             | `docker-squid AV Proxy CA` | Common Name of the self-signed CA certificate generated for SSL-bump.                        |
| `SSL_BUMP_CA_DAYS`           | `3650`                  | Validity period, in days, of the generated CA certificate.                                     |
| `SSL_BUMP_SPLICE_DOMAINS`    | *(empty)*               | Space-separated domains to tunnel instead of intercept (e.g. sites broken by certificate pinning), matched via `dstdomain` against the `CONNECT` target. |

Config files are rendered from these variables once at container start (see
[`cont-init.d/05-render-config`](./cont-init.d/05-render-config)), so changes take effect on
the next `docker run`/`docker compose up`/container recreation — not on a plain restart of
an already-configured container's writable layer, though that's harmless since re-rendering
is idempotent.

## How the antivirus scanning works

```
client -> Squid (:3128) -> [ICAP REQMOD/RESPMOD] -> c-icap (:1344, loopback only)
                                                            |
                                                            v
                                                     clamd (Unix socket)
```

- Squid sends every request/response through c-icap's `avscan` ICAP service
  (`icap_service` + `adaptation_access` in `squid.conf`).
- c-icap's `virus_scan` module (from `c-icap-modules`) forwards the content to `clamd` for
  scanning and either passes it through unmodified or substitutes a block page.
- `freshclam` keeps the ClamAV signature database up to date in the background.

**By default, scanning applies to plain HTTP traffic only.** HTTPS traffic tunneled via
`CONNECT` isn't inspected, since Squid can't hand encrypted bytes to ICAP without
decrypting the connection first — that's what SSL-bump (below) is for.

## SSL-bump (HTTPS scanning)

Set `ENABLE_SSL_BUMP=true` to have Squid transparently decrypt HTTPS traffic (using a
locally-generated CA to mint an impersonation certificate per site on the fly), send it
through the same ICAP antivirus pipeline as plain HTTP, then re-encrypt it to the client.
This is a **man-in-the-middle by design** — be sure you're allowed to do this on the
network/clients in question before enabling it.

```
client <--TLS(fake cert)--> Squid <--TLS(real cert)--> origin server
                              |
                              v
                    [ICAP REQMOD/RESPMOD, same as HTTP]
```

### Trusting the CA certificate

The first time it starts with `ENABLE_SSL_BUMP=true`, the container generates a CA
key/certificate pair at `/etc/squid/ssl_cert/squidCA.{key,pem}`. Every client that goes
through the proxy must import `squidCA.pem` into its trusted root store, or every HTTPS
site will show a certificate warning (or fail outright for apps that pin certificates —
add those domains to `SSL_BUMP_SPLICE_DOMAINS` to exempt them instead).

```bash
docker cp <container>:/etc/squid/ssl_cert/squidCA.pem ./squidCA.pem
# then import squidCA.pem into your OS/browser trust store
```

**Mount a volume over `/etc/squid/ssl_cert`** (see `docker-compose.yml`) so the CA
persists across container recreations — otherwise a new CA is generated every time, and
every client would need to re-import it.

## Testing that scanning actually works

```bash
# Should pass through untouched:
curl -x http://<host>:3128 http://example.com/ -o /dev/null -w '%{http_code}\n'

# Should be blocked (the EICAR test file is a standard, harmless antivirus test string):
curl -x http://<host>:3128 https://secure.eicar.org/eicar.com.txt -o /dev/null -w '%{http_code}\n'
```

With `ENABLE_SSL_BUMP=true`, the same commands scan HTTPS URLs too, provided the client
trusts `squidCA.pem` (or add `--cacert ./squidCA.pem` to the `curl` calls above instead of
installing it system-wide).

## Building locally

```bash
docker build -t docker-squid .
```

c-icap and c-icap-modules are compiled from source in a dedicated build stage (they aren't
packaged for Alpine); only the resulting binaries are copied into the final image.
