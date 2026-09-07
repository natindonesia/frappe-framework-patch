import os

from frappe.app import application

if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
	from frappe import otel

	otel.boot()
	# boot() disables itself if opentelemetry is missing; do not wrap then,
	# or the middleware import would kill the worker.
	if otel._enabled:
		application = otel.wrap_application(application)
