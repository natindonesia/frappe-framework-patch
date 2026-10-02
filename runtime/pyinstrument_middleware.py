import logging
import os
import threading
import time

logger = logging.getLogger("frappe.pyinstrument_middleware")

ENV_GATE = "OTEL_PYINSTRUMENT"
ENV_INTERVAL = "OTEL_PYINSTRUMENT_INTERVAL"
ENV_RSS_INTERVAL = "OTEL_PYINSTRUMENT_RSS_INTERVAL"

DEFAULT_INTERVAL = 0.001
DEFAULT_RSS_INTERVAL = 0.1

MAX_STACK_DEPTH = 64
MAX_STACK_CHARS = 2048

_TRUTHY = {"1", "true", "yes", "on"}

_lock = threading.Lock()
_registry = {}  # thread ident -> span
_rss_thread = None


def _truthy(value):
	return str(value).strip().lower() in _TRUTHY


def _gate_enabled():
	return _truthy(os.getenv(ENV_GATE, ""))


def _env_float(name, default):
	raw = os.getenv(name, "")
	if not raw:
		return default
	try:
		return float(raw)
	except ValueError:
		logger.warning("Invalid %s=%r, falling back to %s", name, raw, default)
		return default


def _serialize_stack(parts):
	"""Pure helper: join frame strings; cap depth at 64 entries (first 16 +
	'...' + tail) and total chars at 2048."""
	if len(parts) > MAX_STACK_DEPTH:
		keep_tail = MAX_STACK_DEPTH - 17
		parts = parts[:16] + ["..."] + parts[-keep_tail:]
	joined = ";".join(parts)
	if len(joined) > MAX_STACK_CHARS:
		joined = joined[: MAX_STACK_CHARS - 3] + "..."
	return joined


def _read_rss_bytes():
	pages = int(open("/proc/self/statm").read().split()[1])
	return pages * os.sysconf("SC_PAGE_SIZE")


def _rss_loop(rss_interval):
	while True:
		time.sleep(rss_interval)
		try:
			rss_bytes = _read_rss_bytes()
		except Exception:
			continue
		now_ns = time.time_ns()
		with _lock:
			spans = list(_registry.values())
		for span in spans:
			try:
				if span.is_recording():
					span.add_event(
						"system.sample",
						attributes={"process.rss_bytes": rss_bytes},
						timestamp=now_ns,
					)
			except Exception:
				pass


def _ensure_rss_thread(rss_interval):
	global _rss_thread
	with _lock:
		if _rss_thread is None:
			_rss_thread = threading.Thread(
				target=_rss_loop,
				args=(rss_interval,),
				daemon=True,
				name="frappe-rss-sampler",
			)
			_rss_thread.start()


def _register(span):
	with _lock:
		_registry[threading.get_ident()] = span


def _unregister():
	with _lock:
		return _registry.pop(threading.get_ident(), None)


def _emit_session_events(span, session):
	for i, (stack, elapsed) in enumerate(session.frame_records):
		try:
			span.add_event(
				"pyinstrument.sample",
				attributes={
					"sample.index": i,
					"sample.wall_duration_ns": int(elapsed * 1e9),
					"sample.source": "pyinstrument_sample",
					"sample.stack": _serialize_stack(list(stack)),
				},
			)
		except Exception:
			logger.warning("failed to record pyinstrument.sample event", exc_info=True)


def wrap(app):
	if not _gate_enabled():
		return app

	interval = _env_float(ENV_INTERVAL, DEFAULT_INTERVAL)
	rss_interval = _env_float(ENV_RSS_INTERVAL, DEFAULT_RSS_INTERVAL)
	if interval <= 0:
		return app

	try:
		from pyinstrument import Profiler
	except ImportError:
		logger.warning("OTEL_PYINSTRUMENT set but pyinstrument not installed")
		return app

	try:
		_ensure_rss_thread(max(rss_interval, 0.0))
	except Exception:
		logger.warning("failed to start rss sampler thread", exc_info=True)

	def profiled(environ, start_response):
		from opentelemetry import trace

		span = trace.get_current_span()
		if span is None or not span.is_recording():
			return app(environ, start_response)

		profiler = Profiler(interval=interval, async_mode="disabled")
		profiler.start()
		start_thread_cpu = time.thread_time_ns()
		_register(span)
		try:
			return app(environ, start_response)
		finally:
			_unregister()
			try:
				session = profiler.stop()
				span.set_attribute(
					"frappe.thread_cpu_ns", int(time.thread_time_ns() - start_thread_cpu)
				)
				span.set_attribute("frappe.profile.sample_count", session.sample_count)
				_emit_session_events(span, session)
			except Exception:
				logger.warning("pyinstrument session recording failed", exc_info=True)

	return profiled
