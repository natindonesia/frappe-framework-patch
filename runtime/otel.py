import functools
import logging
import os

import frappe

logger = logging.getLogger("frappe.otel")

SQL_STATEMENT_MAX_LENGTH = 2000

_QUERY_KEYWORDS = frozenset(
	{
		"select",
		"insert",
		"update",
		"delete",
		"replace",
		"create",
		"alter",
		"drop",
		"truncate",
		"rename",
		"with",
		"set",
	}
)

# Module-level state. _tracer is set by boot() and read on every wrapped SQL
# call, so it must stay cheap to check (None when disabled).
_enabled = False
_booted = False
_tracer = None
_rq_instrumented = False


def _get_sampler(sdk_always_on, sdk_always_off, trace_id_ratio_based, parent_based):
	sampler_name = os.getenv("OTEL_TRACES_SAMPLER") or "parentbased_always_on"
	sampler_arg = os.getenv("OTEL_TRACES_SAMPLER_ARG")

	def _ratio():
		try:
			return float(sampler_arg) if sampler_arg else 1.0
		except (TypeError, ValueError):
			logger.warning("Invalid OTEL_TRACES_SAMPLER_ARG %r, falling back to 1.0", sampler_arg)
			return 1.0

	if sampler_name == "always_on":
		return sdk_always_on
	if sampler_name == "always_off":
		return sdk_always_off
	if sampler_name == "traceidratio":
		return trace_id_ratio_based(_ratio())
	if sampler_name == "parentbased_always_on":
		return parent_based(sdk_always_on)
	if sampler_name == "parentbased_always_off":
		return parent_based(sdk_always_off)
	if sampler_name == "parentbased_traceidratio":
		return parent_based(trace_id_ratio_based(_ratio()))

	logger.warning("Unknown OTEL_TRACES_SAMPLER %r, falling back to parentbased_always_on", sampler_name)
	return parent_based(sdk_always_on)


def _env_int(name, default):
	try:
		return int(os.getenv(name, ""))
	except (TypeError, ValueError):
		return default


def boot():
	global _enabled, _booted, _tracer

	if _booted or not os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
		return

	try:
		from opentelemetry import trace
		from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
		from opentelemetry.sdk.resources import Resource
		from opentelemetry.sdk.trace import TracerProvider
		from opentelemetry.sdk.trace.export import BatchSpanProcessor
		from opentelemetry.sdk.trace.sampling import (
			ALWAYS_OFF,
			ALWAYS_ON,
			ParentBased,
			TraceIdRatioBased,
		)
	except Exception:
		_enabled = False
		_booted = True
		logger.warning(
			"OTEL_EXPORTER_OTLP_ENDPOINT is set but opentelemetry packages are not available; tracing disabled"
		)
		return

	try:
		provider = TracerProvider(
			resource=Resource.create(
				{"service.name": os.getenv("OTEL_SERVICE_NAME") or "frappe-app"}
			),
			sampler=_get_sampler(ALWAYS_ON, ALWAYS_OFF, TraceIdRatioBased, ParentBased),
		)
		provider.add_span_processor(
			BatchSpanProcessor(
				OTLPSpanExporter(),
				schedule_delay_millis=_env_int("OTEL_BSP_SCHEDULE_DELAY_MILLIS", 5000),
				max_queue_size=_env_int("OTEL_BSP_MAX_QUEUE_SIZE", 2048),
				max_export_batch_size=_env_int("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", 512),
			)
		)
		trace.set_tracer_provider(provider)
		_tracer = trace.get_tracer("frappe")
	except Exception:
		_enabled = False
		_booted = True
		_tracer = None
		logger.warning("Failed to initialize OpenTelemetry tracing", exc_info=True)
		return

	for installer in (_patch_sql, _instrument_rq):
		try:
			installer()
		except Exception:
			logger.warning("Failed to install %s", installer.__name__, exc_info=True)

	_enabled = True
	_booted = True


def _instrument_rq():
	global _rq_instrumented

	if _rq_instrumented:
		return

	try:
		from opentelemetry.instrumentation.rq import RQInstrumentation
	except ImportError:
		# No official contrib RQ instrumentation exists on PyPI; job spans
		# still come from the before_job/after_job hooks.
		logger.debug("opentelemetry rq instrumentation unavailable, skipping")
		return

	RQInstrumentation().instrument()
	_rq_instrumented = True


def _get_sql_span_name(query: str) -> str:
	parts = query.strip().split(None, 1)
	if parts and parts[0].lower() in _QUERY_KEYWORDS:
		return parts[0].upper()
	return "SQL"


def _get_sql_span_attributes(db, query: str) -> dict:
	attributes = {}
	db_type = getattr(db, "db_type", None)
	if db_type:
		attributes["db.system"] = db_type
	site = getattr(frappe.local, "site", None)
	if site:
		attributes["frappe.site"] = site
	# db.statement is opt-out: full SQL text can carry inline literals (PII).
	if os.getenv("OTEL_FRAPPE_DB_STATEMENTS", "1").lower() not in {"0", "false", "no"}:
		attributes["db.statement"] = query[:SQL_STATEMENT_MAX_LENGTH]
	return attributes


def _sql_span_wrapper(orig, self, *args, **kwargs):
	# Kept standalone (instead of a closure) so tests can exercise it against a
	# stub `self` without a database connection or patched class.
	if not kwargs.get("run", True):
		return orig(self, *args, **kwargs)

	if _tracer is None:
		return orig(self, *args, **kwargs)

	try:
		query = str(kwargs["query"]) if "query" in kwargs else str(args[0] if args else "")
	except Exception:
		query = ""

	with _tracer.start_as_current_span(
		_get_sql_span_name(query), attributes=_get_sql_span_attributes(self, query)
	) as span:
		try:
			return orig(self, *args, **kwargs)
		except Exception as e:
			span.record_exception(e)
			from opentelemetry.trace import Status, StatusCode

			span.set_status(Status(StatusCode.ERROR))
			raise


def _patch_sql():
	from frappe.database.database import Database

	if getattr(Database.sql, "_otel_patched", False):
		return

	orig = Database.sql

	@functools.wraps(orig)
	def wrapper(self, *args, **kwargs):
		return _sql_span_wrapper(orig, self, *args, **kwargs)

	Database.sql = wrapper
	Database.sql._otel_patched = True


def before_job(method=None, kwargs=None, transaction_type=None, **_ignored):
	if not (_enabled and _tracer):
		return

	try:
		from opentelemetry import context as otel_context
		from opentelemetry import trace as otel_trace

		attributes = {"frappe.job.method": method}
		if site := getattr(frappe.local, "site", None):
			attributes["frappe.site"] = site
		if user := getattr(frappe.local, "user", None):
			attributes["frappe.job.user"] = user

		span = _tracer.start_span(f"frappe.job {method}", attributes=attributes)
		frappe.local._otel_job_span = span
		frappe.local._otel_job_context_token = otel_context.attach(
			otel_trace.set_span_in_context(span)
		)
	except Exception:
		logger.debug("otel.before_job failed", exc_info=True)


def after_job(method=None, kwargs=None, result=None, **_ignored):
	try:
		span = getattr(frappe.local, "_otel_job_span", None)
		if span is None:
			return
		delattr(frappe.local, "_otel_job_span")

		try:
			from opentelemetry import context as otel_context
			from opentelemetry.trace import Status, StatusCode

			token = getattr(frappe.local, "_otel_job_context_token", None)
			if token is not None:
				delattr(frappe.local, "_otel_job_context_token")
				otel_context.detach(token)
			span.set_status(Status(StatusCode.UNSET))
		finally:
			span.end()
	except Exception:
		logger.debug("otel.after_job failed", exc_info=True)


def wrap_application(wsgi_app):
	from opentelemetry.instrumentation.wsgi import OpenTelemetryMiddleware

	def request_hook(span, environ):
		try:
			if not span.is_recording():
				return
			host = environ.get("HTTP_HOST")
			if not host:
				return
			from frappe.utils import get_site_name

			site = get_site_name(host)
			if site:
				span.set_attribute("frappe.site", site)
		except Exception:
			logger.debug("otel.request_hook failed", exc_info=True)

	return OpenTelemetryMiddleware(wsgi_app, request_hook=request_hook)
