# OpenTelemetry deployment

This repository deploys OpenTelemetry (OTel) as a local OpenTelemetry Collector beside the Frappe services. Application, worker, scheduler, and nginx containers export to that collector. The collector can either log spans locally for diagnostics or forward them to a central OTLP collector/backend.

The deployment is opt-in. If `OTEL_EXPORTER_OTLP_ENDPOINT` is empty, Frappe does not initialize its SDK and the application-side spans are disabled. If `NGINX_OTEL_ENDPOINT` is empty, nginx runs without its OTel module directives.

## Architecture

```text
                         OTLP/gRPC :4317
                  +----------------------------+
                  |                            v
nginx ----------> |                       +---------+
                  |                       |         |
Frappe web ------>| OTLP/HTTP :4318       |  OTel   |----> debug logs
workers ---------->---------------------->|collector| \
scheduler -------->                       |         |  \
                                          +---------+   +--> central OTLP collector
```

Protocol/port mapping is important:

| Producer | Environment variable | Protocol | Collector port |
|---|---|---|---:|
| Frappe web, workers, scheduler | `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP/HTTP | `4318` |
| nginx `ngx_otel_module` | `NGINX_OTEL_ENDPOINT` | OTLP/gRPC | `4317` |

The Python SDK exporter is configured by `OTEL_EXPORTER_OTLP_ENDPOINT` and expects a URL such as `http://otel-collector:4318`. The nginx module expects a scheme-less `host:port`, such as `otel-collector:4317`; do not use `http://` in `NGINX_OTEL_ENDPOINT`.

## Prerequisites

- Docker Engine and Docker Compose v2.
- The repository checkout, including the Frappe submodule:

```bash
git submodule update --init --recursive
```

- A central OTLP endpoint if spans are to leave the host. Do not put credentials in this documentation or commit them to `.env` files tracked by Git.

## Deploy with local collector logging

This mode is useful for first deployment and troubleshooting. The collector uses the repository's built-in configuration and writes detailed span records to its container log.

```bash
cd /mnt/project-premium/hris/new-bench-2/apps/frappe-framework-patch

export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
export NGINX_OTEL_ENDPOINT=otel-collector:4317
export TRACE_EXPORTERS=debug

# Set real values in the deployment environment; these defaults are only for local use.
export SITE_NAME=crm.localhost
export MYSQL_ROOT_PASSWORD='change-me'
export ADMIN_PASSWORD='change-me'

docker compose up -d --build
```

The Compose file builds the Frappe image from the repository Dockerfile. It starts MariaDB and Redis, runs `init`, then starts the web, queue workers, scheduler, Socket.IO, nginx, and collector services.

Check that the expected containers and exporter settings are running:

```bash
docker compose ps
docker compose exec web env | grep '^OTEL_'
docker compose exec nginx env | grep -E '^(OTEL_|NGINX_OTEL_)'
docker compose logs --tail=100 nginx
docker compose logs --tail=100 otel-collector
```

Expected nginx messages include:

```text
OpenTelemetry nginx module enabled (exporter: otel-collector:4317)
```

Generate a request through nginx and wait for the collector batch timeout (the default is 5 seconds):

```bash
docker compose exec -T nginx curl -s -H 'Host: crm.localhost' \
  http://127.0.0.1:8080/api/method/ping
sleep 6
docker compose logs otel-collector | grep -E 'Trace ID|service.name|Span #' | tail -80
```

A healthy request has spans with the same trace ID for both `frappe-nginx` and `frappe-app`. Failed requests can also produce spans and are useful for diagnostics.

## Forward spans to a central collector

The repository collector configuration defines an `otlp/central` exporter with a retry queue. Configure the central destination using a host and port, then select that exporter in the trace pipeline:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
export NGINX_OTEL_ENDPOINT=otel-collector:4317
export CENTRAL_OTLP_ENDPOINT=central-otel.example.internal:4317
export CENTRAL_OTLP_INSECURE=false
export TRACE_EXPORTERS=otlp/central

docker compose up -d --build
```

`CENTRAL_OTLP_ENDPOINT` is consumed by the collector's OTLP exporter and should be a collector endpoint in `host:port` form. `CENTRAL_OTLP_INSECURE=false` enables TLS verification behavior in the collector exporter. If the central service requires authentication headers, provide an operator-managed collector configuration through `OTEL_COLLECTOR_CONFIG_URI` rather than adding credentials to this repository's Compose file.

For a deployment that needs both central forwarding and local diagnostics, use an operator-managed collector configuration whose trace pipeline exporters include both `otlp/central` and `debug`. The stock configuration uses the value of `TRACE_EXPORTERS` as the exporter list and is intended to select one exporter.

The collector has a persistent in-memory sending queue only: `sending_queue.queue_size` protects against short central outages, but it is not a durable disk buffer. Plan central availability and alerting accordingly.

## Use an external collector configuration

The collector command accepts a configuration URI through `OTEL_COLLECTOR_CONFIG_URI`. Supported forms are documented in the Compose comments and include a mounted `file:` URI or an operator-managed `env:`, `http:`, or `https:` URI.

For a file mounted by a Compose override:

```yaml
# compose.otel-production.yml
services:
  otel-collector:
    volumes:
      - ./otel-collector-production.yaml:/etc/otelcol/production.yaml:ro
    command:
      - --config=/etc/otelcol/production.yaml
      - --set=exporters::debug::verbosity=detailed
```

Start with every Compose file supplied on every command:

```bash
docker compose \
  -f docker-compose.yml \
  -f compose.otel-production.yml \
  up -d --build
```

Validate the merged configuration before applying it:

```bash
docker compose \
  -f docker-compose.yml \
  -f compose.otel-production.yml \
  config
```

If the collector image runs as a non-root user, ensure a mounted configuration is readable inside the container (for example, mode `0644` for a non-secret config). Keep credentials in a secret mechanism supported by the deployment platform, not in a world-readable configuration file.

## Deployment settings

| Variable | Required | Recommended value | Purpose |
|---|---:|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | No | `http://otel-collector:4318` | Enables Python SDK tracing and sends OTLP/HTTP to the local collector. Empty disables app tracing. |
| `NGINX_OTEL_ENDPOINT` | No | `otel-collector:4317` | Enables nginx tracing over OTLP/gRPC. Must be scheme-less. Empty disables nginx span export. |
| `OTEL_SERVICE_NAME` | No | Per service | Service identity. Compose sets `frappe-app`, `frappe-nginx`, and distinct worker/scheduler names. |
| `TRACE_EXPORTERS` | No | `debug` locally; `otlp/central` in production | Collector trace pipeline exporter selection. |
| `CENTRAL_OTLP_ENDPOINT` | For central export | `central-otel.example:4317` | Destination for `otlp/central`. Use `host:port`, not an application URL. |
| `CENTRAL_OTLP_INSECURE` | For central export | `false` with TLS | Controls TLS behavior for the central exporter. |
| `OTEL_COLLECTOR_CONFIG_URI` | No | `/etc/otelcol/config.yaml` | Selects a collector configuration URI. |
| `OTEL_TRACES_SAMPLER` | No | `parentbased_always_on` | Python SDK sampler. Other supported values include `always_on`, `always_off`, `traceidratio`, and parent-based variants. |
| `OTEL_TRACES_SAMPLER_ARG` | With ratio sampler | `0.1`–`1.0` | Sampling ratio for `traceidratio` samplers. |
| `OTEL_FRAPPE_DB_STATEMENTS` | No | `0` in sensitive environments | Controls the `db.statement` SQL attribute. Disable it to avoid exporting SQL literals or PII. |
| `OTEL_BSP_SCHEDULE_DELAY_MILLIS` | No | `5000` | Python batch exporter flush delay. |

The Compose defaults include development credentials and should not be used for production. Set all database and administrator passwords explicitly through the deployment platform's secret configuration.

## Production rollout

1. Build and publish the intended Frappe image through the repository CI workflow, or build it locally with `bash scripts/build.sh` and publish only through an approved registry process.
2. Pin the production deployment to the verified image tag. Do not rebuild unrelated service images from a different source during rollout.
3. Provide the OTLP endpoint variables through the deployment platform's environment/secret settings.
4. Use `TRACE_EXPORTERS=otlp/central` and TLS for central forwarding. Avoid `debug` in production unless detailed collector logs are explicitly required for a short diagnostic window.
5. Apply the Compose stack and inspect `docker compose ps` and collector/nginx startup logs.
6. Send a request through nginx and verify a shared trace in the central backend. Confirm service names include the expected `frappe-nginx` and `frappe-app` legs.
7. Monitor collector retry/export errors, queue growth, container restarts, and central backend ingestion.
8. To disable tracing, set both `OTEL_EXPORTER_OTLP_ENDPOINT` and `NGINX_OTEL_ENDPOINT` to empty strings, recreate the affected services, and verify nginx logs `OpenTelemetry disabled`.

## Verification and CI behavior

The repository's integration checks exercise the same deployment contract:

```bash
bash scripts/ci/matrix-variant-test.sh latest
```

The script starts cold, checks trace continuity, and verifies the gate-off path for gunicorn variants. CI intentionally polls for spans because the collector batch processor can wait up to 5 seconds before logging them. A one-time immediate grep can incorrectly report that tracing is broken.

The gate-off check compares span start times rather than raw log counts. Buffered spans generated before disabling OTel may be flushed after the restart; they are not leaks. A real leak is a span whose start time is newer than the last pre-gate-off span.

For a direct local check without the full CI matrix:

```bash
docker compose up -d --build
# wait for web/nginx readiness, then:
docker compose exec -T nginx curl -s -H 'Host: crm.localhost' \
  http://127.0.0.1:8080/api/method/ping
for _ in $(seq 1 20); do
  docker compose logs otel-collector | grep -q 'frappe-app' && break
  sleep 2
done
docker compose logs otel-collector | grep -E 'frappe-nginx|frappe-app'
```

## Troubleshooting

### App spans exist, but nginx spans do not

Check the nginx endpoint and protocol first:

```bash
docker compose exec nginx env | grep -E '^(OTEL_EXPORTER_OTLP_ENDPOINT|NGINX_OTEL_ENDPOINT)'
docker compose logs nginx | grep -E 'OpenTelemetry|otel'
```

`NGINX_OTEL_ENDPOINT` must be `otel-collector:4317`, not `http://otel-collector:4317` and not port `4318`. Also confirm the image contains `/usr/lib/nginx/modules/ngx_otel_module.so`.

### No app spans

- Confirm `OTEL_EXPORTER_OTLP_ENDPOINT` is present inside `web`, not only exported in the shell that launched Compose.
- Confirm it uses `http://...:4318`.
- Check the web logs for missing OpenTelemetry packages or initialization warnings.
- Wait for the collector batch timeout before judging the result.
- Confirm the collector is on the same Compose network and is healthy enough to accept connections.

### Collector starts but exports nowhere

Inspect the effective merged configuration and environment:

```bash
docker compose config
# Avoid printing secrets; inspect only non-sensitive settings.
docker compose exec otel-collector env | grep -E '^(CENTRAL_OTLP_ENDPOINT|CENTRAL_OTLP_INSECURE|TRACE_EXPORTERS)'
docker compose logs otel-collector
```

Check that `TRACE_EXPORTERS` names an exporter defined in the selected collector configuration. For central forwarding, confirm the destination is reachable from the collector container and that the protocol/TLS settings match the central receiver.

### Traces are split across services

Ensure the request enters through nginx and that the nginx module has `otel_trace_context propagate`. The repository entrypoint injects this directive when nginx OTel is enabled. Verify that the application and nginx legs use the same request and that a shared trace ID appears in the collector output/backend.

## Teardown

Stop the stack without deleting data volumes:

```bash
docker compose down
```

Use `docker compose down -v` only when deliberately destroying the MariaDB and Frappe site volumes, such as an isolated CI run.

## Repository references

- `docker-compose.yml` — service wiring, environment variables, collector ports, and image builds.
- `resources/otel-collector-config.yaml` — local receiver, batch processor, debug exporter, and central OTLP exporter.
- `resources/nginx-entrypoint.sh` — nginx OTel module loading and gRPC exporter injection.
- `runtime/otel.py` — lazy SDK boot, sampling, SQL spans, and background-job spans.
- `runtime/otel_wsgi.py` — WSGI middleware setup.
- `resources/gunicorn-otel-conf.py` — worker boot hook.
- `scripts/ci/compose-otel-spans.sh` — cold-start trace continuity assertion.
- `scripts/ci/compose-gate-off.sh` — gate-off assertion using span start times.
- `scripts/ci/matrix-variant-test.sh` — end-to-end variant contract.
- `Dockerfile` — OTel Python dependencies, nginx OTel module, and runtime overlays.
- `README.md` — general image build and CI information.
