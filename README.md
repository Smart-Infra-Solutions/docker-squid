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
- A `HEALTHCHECK` that verifies the container still has outbound connectivity.

## Quick start

The image is published for `linux/amd64` and `linux/arm64` on the GitHub Container
Registry as `ghcr.io/smart-infra-solutions/docker-squid` (and on Docker Hub as
`smartinfrasolutions/squid`), with these tags:

| Tag            | Content                                                     |
| -------------- | ----------------------------------------------------------- |
| `latest`       | Latest tested build of the `main` branch.                   |
| `<git tag>`    | A release, e.g. `v1.0.0`.                                   |
| `sha-<commit>` | The build of a given commit (including pull requests).      |

```bash
docker run -d \
  --name squid \
  -p 3128:3128 \
  -v squid-clamav-db:/var/lib/clamav \
  ghcr.io/smart-infra-solutions/docker-squid:latest
```

Point a client at `http://<host>:3128` as its HTTP/HTTPS proxy. Plain HTTP downloads and
uploads are scanned for malware; a file containing a virus (or the
[EICAR test file](https://www.eicar.org/download-anti-malware-testfile/)) is replaced by an
HTTP 403 "VIRUS FOUND" page. HTTPS is only scanned with SSL-bump enabled, see
[How the antivirus scanning works](#how-the-antivirus-scanning-works).

The `/var/lib/clamav` volume isn't required, but without it the ClamAV signature database
(~100-200 MB) is re-downloaded from scratch on every container start.

On first start, the proxy only starts listening once the signature database has been
downloaded and the antivirus is ready (typically 30 s to a few minutes, depending on the
network). Plan for **about 1.2 GB of RAM**, almost all of it used by `clamd` to hold the
signatures in memory; set `ENABLE_ANTIVIRUS=false` to run a plain Squid proxy without it.

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
- `freshclam` keeps the ClamAV signature database up to date in the background
  (`CLAMAV_UPDATE_CHECKS` times a day, from `CLAMAV_DATABASE_MIRROR`).

What gets scanned:

| Traffic                                     | Scanned?                                                                 |
| ------------------------------------------- | ------------------------------------------------------------------------ |
| Plain HTTP downloads (responses, RESPMOD)   | Yes.                                                                     |
| Plain HTTP uploads (request bodies, REQMOD) | Yes.                                                                     |
| HTTPS (`CONNECT` tunnels)                   | Only with `ENABLE_SSL_BUMP=true`, see [below](#ssl-bump-https-scanning). |
| Objects larger than `ICAP_MAX_OBJECT_SIZE`  | No, passed through unscanned (default `5M`).                             |

**By default, scanning applies to plain HTTP traffic only.** HTTPS traffic tunneled via
`CONNECT` isn't inspected, since Squid can't hand encrypted bytes to ICAP without
decrypting the connection first — that's what SSL-bump (below) is for.

- **Infected content is blocked**: the client gets an **HTTP 403** "VIRUS FOUND" page from
  c-icap, naming the detected signature, instead of the file.
- **Fail closed by default** (`ICAP_BYPASS=off`): if c-icap or clamd is down, requests
  fail with an error rather than going through unscanned. Set `ICAP_BYPASS=on` to favor
  availability over protection.
- **Startup order is enforced** so scanning is never silently off: `clamd` waits for a
  signature database, c-icap waits for `clamd` to answer, and Squid waits for c-icap.
- **Logs** inside the container: `/var/log/squid/` (`access.log`, `cache.log`) and
  `/var/log/c-icap/` (`access.log`, `server.log`).

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

The simplest check is the automated smoke test: it serves the
[EICAR test file](https://www.eicar.org/download-anti-malware-testfile/) (a standard,
harmless antivirus test string) over plain HTTP and expects it to be blocked, see
[Tests and CI](#tests-and-ci).

By hand:

```bash
# Should pass through untouched (200):
curl -x http://<host>:3128 http://example.com/ -o /dev/null -w '%{http_code}\n'

# Should be blocked (403), but only with ENABLE_SSL_BUMP=true, since this URL is HTTPS
# (--cacert is not needed if squidCA.pem is installed in the system trust store):
curl -x http://<host>:3128 --cacert ./squidCA.pem \
  https://secure.eicar.org/eicar.com.txt -o /dev/null -w '%{http_code}\n'
```

Without SSL-bump, that HTTPS download goes through the `CONNECT` tunnel unscanned and
returns 200: that's expected, not a sign that the antivirus is broken.

## Building locally

```bash
docker build -t docker-squid .
```

c-icap and c-icap-modules are compiled from source in a dedicated build stage (they aren't
packaged for Alpine); only the resulting binaries are copied into the final image.

## Tests and CI

`tests/smoke.sh` checks a running container end to end: a clean file goes through the
proxy unchanged, the [EICAR test file](https://www.eicar.org/download-anti-malware-testfile/)
is blocked by the antivirus, and `CONNECT` to a non-SSL port is denied. To build the image
and run it locally (needs Docker; the first start downloads the ClamAV database, so allow a
few minutes):

```bash
tests/run-local.sh
```

The Woodpecker pipeline (`.woodpecker/`) lints the `Dockerfile` (hadolint) and the shell
scripts (shellcheck), builds the multi-arch image and pushes it as `sha-<commit>`, runs the
smoke test against that image, then, on `main` or a git tag, publishes the very same image
as `latest` / `<tag>` (copied, not rebuilt). Dependabot keeps the pinned base images
(`alpine`, `crazymax/alpine-s6`) up to date.
