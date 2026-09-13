import os

# Gunicorn and Granian import this module directly; neither calls
# frappe.app.serve(), which is where Frappe normally installs its static-file
# middleware.  Keep the path explicit so this entrypoint does not depend on
# the process cwd (and so the same WSGI object works behind an ingress with no
# Nginx sidecar).
os.environ.setdefault("SITES_PATH", "/home/frappe/frappe-bench/sites")

from frappe.app import application, application_with_statics

application = application_with_statics()

if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
	from frappe import otel

	otel.boot()
	# boot() disables itself if opentelemetry is missing; do not wrap then,
	# or the middleware import would kill the worker.
	if otel._enabled:
		application = otel.wrap_application(application)
