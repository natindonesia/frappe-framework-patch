#!/bin/bash

# Set worker_connections (default to 4096 for high throughput)
WORKER_CONNECTIONS=${WORKER_CONNECTIONS:-4096}
echo "Setting nginx worker_connections to $WORKER_CONNECTIONS"
# Use sed to stdout + cat to overwrite (avoids sed -i temp file in /etc/nginx which is root-owned)
sed "s/worker_connections [0-9]*;/worker_connections $WORKER_CONNECTIONS;/" /etc/nginx/nginx.conf > /tmp/nginx.conf.tmp && cat /tmp/nginx.conf.tmp > /etc/nginx/nginx.conf

# Set variables that do not exist
if [[ -z "$BACKEND" ]]; then
  echo "BACKEND defaulting to 0.0.0.0:8000"
  export BACKEND=0.0.0.0:8000
fi
if [[ -z "$SOCKETIO" ]]; then
  echo "SOCKETIO defaulting to 0.0.0.0:9000"
  export SOCKETIO=0.0.0.0:9000
fi
if [[ -z "$UPSTREAM_REAL_IP_ADDRESS" ]]; then
  echo "UPSTREAM_REAL_IP_ADDRESS defaulting to 127.0.0.1"
  export UPSTREAM_REAL_IP_ADDRESS=127.0.0.1
fi
if [[ -z "$UPSTREAM_REAL_IP_HEADER" ]]; then
  echo "UPSTREAM_REAL_IP_HEADER defaulting to X-Forwarded-For"
  export UPSTREAM_REAL_IP_HEADER=X-Forwarded-For
fi
if [[ -z "$UPSTREAM_REAL_IP_RECURSIVE" ]]; then
  echo "UPSTREAM_REAL_IP_RECURSIVE defaulting to off"
  export UPSTREAM_REAL_IP_RECURSIVE=off
fi
if [[ -z "$FRAPPE_SITE_NAME_HEADER" ]]; then
  # shellcheck disable=SC2016
  echo 'FRAPPE_SITE_NAME_HEADER defaulting to $host'
  # shellcheck disable=SC2016
  export FRAPPE_SITE_NAME_HEADER='$host'
fi

if [[ -z "$PROXY_READ_TIMEOUT" ]]; then
  echo "PROXY_READ_TIMEOUT defaulting to 120"
  export PROXY_READ_TIMEOUT=120
fi

if [[ -z "$CLIENT_MAX_BODY_SIZE" ]]; then
  echo "CLIENT_MAX_BODY_SIZE defaulting to 100m"
  export CLIENT_MAX_BODY_SIZE=100m
fi

if [[ -z "$OTEL_SERVICE_NAME" ]]; then
  echo "OTEL_SERVICE_NAME defaulting to frappe-nginx"
  export OTEL_SERVICE_NAME=frappe-nginx
fi

# shellcheck disable=SC2016
envsubst '${BACKEND}
  ${SOCKETIO}
  ${UPSTREAM_REAL_IP_ADDRESS}
  ${UPSTREAM_REAL_IP_HEADER}
  ${UPSTREAM_REAL_IP_RECURSIVE}
  ${FRAPPE_SITE_NAME_HEADER}
  ${PROXY_READ_TIMEOUT}
	${CLIENT_MAX_BODY_SIZE}' \
  </templates/nginx/frappe.conf.template >/etc/nginx/conf.d/frappe.conf

# OpenTelemetry: the nginx leg is enabled by the presence of
# NGINX_OTEL_ENDPOINT, which defaults to being derived from the shared
# OTEL_EXPORTER_OTLP_ENDPOINT when set. The prebuilt ngx_otel_module (shipped
# by the nginx-module-otel package from nginx.org) exports OTLP over gRPC
# only, so it must target the collector's gRPC receiver (:4317) — the shared
# OTEL_EXPORTER_OTLP_ENDPOINT points at the HTTP receiver (:4318), which is
# what the app's Python exporter uses. Without an endpoint, or when the module
# is missing (older image), nginx keeps serving and merely passes the W3C
# traceparent header through, so the trace stays continuous without an nginx
# span.
if [[ -z "$NGINX_OTEL_ENDPOINT" && -n "$OTEL_EXPORTER_OTLP_ENDPOINT" ]]; then
  # ngx_otel_module speaks OTLP/gRPC (:4317); swap the shared endpoint's port
  # so the nginx leg does not silently drop its spans into the void.
  ep="${OTEL_EXPORTER_OTLP_ENDPOINT#*://}"
  echo "NGINX_OTEL_ENDPOINT defaulting to ${ep%:*}:4317 (gRPC)"
  export NGINX_OTEL_ENDPOINT="${ep%:*}:4317"
fi

if [[ -n "$NGINX_OTEL_ENDPOINT" ]]; then
  if [[ -f /usr/lib/nginx/modules/ngx_otel_module.so ]]; then
    # Load the module unless the nginx package already auto-loads it via its
    # modules include. Overwrite via stdout + cat (avoids sed -i temp file in
    # the root-owned /etc/nginx dir — see line 7).
    if ! grep -qs 'ngx_otel_module' /etc/nginx/nginx.conf /etc/nginx/modules/*.conf /etc/nginx/modules-enabled/*.conf; then
      sed '1i load_module modules/ngx_otel_module.so;' /etc/nginx/nginx.conf > /tmp/nginx.conf.tmp \
        && cat /tmp/nginx.conf.tmp > /etc/nginx/nginx.conf
    fi

    OTEL_DIRECTIVES="$(printf '\totel_exporter {\n\t\tendpoint "%s";\n\t\tinterval 500ms;\n\t\tbatch_size 512;\n\t}\n\totel_trace on;\n\totel_trace_context propagate;\n\totel_service_name "%s";' "$NGINX_OTEL_ENDPOINT" "$OTEL_SERVICE_NAME")"
    awk -v directives="$OTEL_DIRECTIVES" '{ sub(/# OTEL_SPAN_DIRECTIVES/, directives); print }' \
      /etc/nginx/conf.d/frappe.conf > /tmp/frappe.conf.otel \
      && cat /tmp/frappe.conf.otel > /etc/nginx/conf.d/frappe.conf \
      && rm /tmp/frappe.conf.otel
    echo "OpenTelemetry nginx module enabled (exporter: $NGINX_OTEL_ENDPOINT)"
  else
    echo "WARNING: NGINX_OTEL_ENDPOINT set but ngx_otel_module.so is missing — continuing without nginx spans"
  fi
else
  echo "OpenTelemetry disabled (NGINX_OTEL_ENDPOINT / OTEL_EXPORTER_OTLP_ENDPOINT not set)"
  # Strip the marker so the rendered conf is valid stock nginx.
  sed -i '/# OTEL_SPAN_DIRECTIVES/d' /etc/nginx/conf.d/frappe.conf
fi

nginx -g 'daemon off;'
