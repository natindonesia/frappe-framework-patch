import cProfile
import glob
import logging
import os
import pstats
import sys
import time

# Gunicorn and Granian import this module directly; neither calls
# frappe.app.serve(), which is where Frappe normally installs its static-file
# middleware.  Keep the path explicit so this entrypoint does not depend on
# the process cwd (and so the same WSGI object works behind an ingress with no
# Nginx sidecar).
os.environ.setdefault("SITES_PATH", "/home/frappe/frappe-bench/sites")

logger = logging.getLogger("frappe.otel_wsgi")


class WallTimeProfilerMiddleware:
	"""WSGI middleware capturing true wall-clock time per request using cProfile + time.perf_counter.

	Captures database queries, lock waits, external HTTP calls, and template rendering.
	Profiles are dumped as individual `.prof` files into `profile_dir`.
	"""

	def __init__(self, app, profile_dir=None, ignore_prefixes=None):
		self.app = app
		if profile_dir is None:
			profile_dir = os.path.join(
				os.environ.get("SITES_PATH", "/home/frappe/frappe-bench/sites"),
				"profiles",
			)
		self.profile_dir = profile_dir
		os.makedirs(self.profile_dir, exist_ok=True)

		if ignore_prefixes is None:
			raw_ignore = os.getenv(
				"WALL_PROFILING_IGNORE",
				"/api/method/ping,/healthz,/assets,/favicon.ico",
			)
			self.ignore_prefixes = tuple(
				p.strip() for p in raw_ignore.split(",") if p.strip()
			)
		else:
			self.ignore_prefixes = tuple(ignore_prefixes)

	def __call__(self, environ, start_response):
		path = environ.get("PATH_INFO", "")
		if any(path.startswith(prefix) for prefix in self.ignore_prefixes):
			return self.app(environ, start_response)

		response_chunks = []

		def catching_start_response(status, headers, exc_info=None):
			start_response(status, headers, exc_info)
			return response_chunks.append

		profiler = cProfile.Profile(time.perf_counter)

		def runapp():
			app_iter = self.app(environ, catching_start_response)
			try:
				for chunk in app_iter:
					response_chunks.append(chunk)
			finally:
				if hasattr(app_iter, "close"):
					app_iter.close()

		profiler.runcall(runapp)

		clean_path = path.strip("/").replace("/", "_") or "root"
		ts = int(time.time() * 1000)
		pid = os.getpid()

		# Correlate with active OpenTelemetry trace context if available
		trace_id_suffix = ""
		active_span = None
		try:
			from opentelemetry import trace

			active_span = trace.get_current_span()
			if active_span and active_span.is_recording():
				ctx = active_span.get_span_context()
				if ctx and ctx.trace_id:
					trace_id_suffix = f"_trace_{format(ctx.trace_id, '032x')}"
		except Exception:
			pass

		filename = os.path.join(
			self.profile_dir, f"req_{ts}_{pid}{trace_id_suffix}_{clean_path}.prof"
		)
		try:
			profiler.dump_stats(filename)
			# Link the profile file and summary metrics directly to the OTel span
			if active_span and active_span.is_recording():
				stats = pstats.Stats(profiler)
				active_span.set_attribute("frappe.profile.file", filename)
				active_span.set_attribute(
					"frappe.profile.wall_time_ms", round(stats.total_tt * 1000.0, 2)
				)
				active_span.set_attribute("frappe.profile.total_calls", stats.total_calls)
		except Exception as e:
			logger.warning("Failed to dump wall profile to %s: %s", filename, e)

		return response_chunks


def analyze_distribution(profile_dir=None):
	"""Compute request duration percentiles (p50, p90, p95, p99), averages, and endpoint breakdown across all profiles."""
	if profile_dir is None:
		profile_dir = os.path.join(
			os.environ.get("SITES_PATH", "/home/frappe/frappe-bench/sites"),
			"profiles",
		)

	files = glob.glob(os.path.join(profile_dir, "req_*.prof"))
	if not files:
		print(f"[Distribution] No individual profile files found in {profile_dir}")
		return None

	records = []
	by_endpoint = {}

	for f in files:
		try:
			st = pstats.Stats(f)
			wall_ms = st.total_tt * 1000.0
			base = os.path.basename(f).replace(".prof", "")
			# extract trace_id if present
			trace_id = ""
			if "_trace_" in base:
				trace_id = base.split("_trace_")[1].split("_")[0]
			endpoint = base.split("_")[-1]

			records.append(
				{
					"file": f,
					"endpoint": endpoint,
					"trace_id": trace_id,
					"wall_ms": wall_ms,
					"calls": st.total_calls,
				}
			)
			by_endpoint.setdefault(endpoint, []).append(wall_ms)
		except Exception:
			continue

	if not records:
		return None

	def _calc_stats(values):
		vals = sorted(values)
		n = len(vals)
		mean = sum(vals) / n
		variance = sum((x - mean) ** 2 for x in vals) / n
		std = variance**0.5

		def _pct(p):
			k = (n - 1) * (p / 100.0)
			f = int(k)
			c = f + 1 if f + 1 < n else f
			return vals[f] + (k - f) * (vals[c] - vals[f])

		return {
			"count": n,
			"mean": mean,
			"std": std,
			"min": vals[0],
			"p50": _pct(50),
			"p90": _pct(90),
			"p95": _pct(95),
			"p99": _pct(99),
			"max": vals[-1],
		}

	overall = _calc_stats([r["wall_ms"] for r in records])

	print("\n" + "=" * 80)
	print("REQUEST WALL-TIME LATENCY DISTRIBUTION")
	print("=" * 80)
	print(f"Sample Size : {overall['count']} requests")
	print(f"Mean        : {overall['mean']:8.2f} ms  (± {overall['std']:.2f} ms)")
	print(f"Min         : {overall['min']:8.2f} ms")
	print(f"p50 (Median): {overall['p50']:8.2f} ms")
	print(f"p90         : {overall['p90']:8.2f} ms")
	print(f"p95         : {overall['p95']:8.2f} ms")
	print(f"p99         : {overall['p99']:8.2f} ms")
	print(f"Max         : {overall['max']:8.2f} ms")

	print("\n" + "-" * 80)
	print("BREAKDOWN BY ENDPOINT")
	print("-" * 80)
	print(
		f"{'Endpoint':<25} {'Count':>6} {'p50 (ms)':>10} {'p90 (ms)':>10} {'p95 (ms)':>10} {'Max (ms)':>10}"
	)
	print("-" * 80)
	for ep, ep_vals in sorted(by_endpoint.items(), key=lambda x: len(x[1]), reverse=True):
		ep_st = _calc_stats(ep_vals)
		print(
			f"{ep:<25} {ep_st['count']:>6} {ep_st['p50']:>10.2f} {ep_st['p90']:>10.2f} {ep_st['p95']:>10.2f} {ep_st['max']:>10.2f}"
		)

	# Top 5 slowest outlier requests with trace_id correlation
	slowest = sorted(records, key=lambda x: x["wall_ms"], reverse=True)[:5]
	print("\n" + "-" * 80)
	print("TOP OUTLIER (SLOWEST) REQUESTS FOR TRACE CORRELATION")
	print("-" * 80)
	for s in slowest:
		trace_info = f"OTel Trace ID: {s['trace_id']}" if s["trace_id"] else "No Trace Context"
		print(f"{s['wall_ms']:8.2f} ms | {s['endpoint']:<15} | {trace_info} | {os.path.basename(s['file'])}")

	return overall


def aggregate_profiles(profile_dir=None, output_file=None, top_n=30):
	"""Aggregate all individual `.prof` and `.pstats` files in profile_dir into a single consolidated profile."""
	if profile_dir is None:
		profile_dir = os.path.join(
			os.environ.get("SITES_PATH", "/home/frappe/frappe-bench/sites"),
			"profiles",
		)

	files = glob.glob(os.path.join(profile_dir, "*.prof")) + glob.glob(
		os.path.join(profile_dir, "*.pstats")
	)
	if not files:
		print(f"[Profiling] No profile files found in {profile_dir}")
		return None

	print(f"[Profiling] Found {len(files)} profile files in {profile_dir}. Aggregating...")
	merged = pstats.Stats(files[0])
	for f in files[1:]:
		merged.add(f)

	if output_file is None:
		output_file = os.path.join(profile_dir, "aggregated.prof")

	merged.dump_stats(output_file)
	print(f"[Profiling] Aggregated profile saved to: {output_file}")
	print("\n" + "=" * 80)
	print(f"TOP {top_n} FUNCTIONS BY CUMULATIVE WALL-CLOCK TIME (includes DB, I/O & CPU):")
	print("=" * 80)
	merged.strip_dirs().sort_stats("cumulative").print_stats(top_n)
	return output_file


from frappe.app import application, application_with_statics

application = application_with_statics()

# Wall-clock time profiling gate
if os.getenv("ENABLE_WALL_PROFILING", "").strip().lower() in ("1", "true", "yes", "on"):
	profiler_dir = os.getenv("WALL_PROFILING_DIR")
	application = WallTimeProfilerMiddleware(application, profile_dir=profiler_dir)

if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
	from frappe import otel

	otel.boot()
	# boot() disables itself if opentelemetry is missing; do not wrap then,
	# or the middleware import would kill the worker.
	if otel._enabled:
		application = otel.wrap_application(application)


if __name__ == "__main__":
	# CLI support:
	#   python -m frappe.otel_wsgi --distribution [PROFILE_DIR]
	#   python -m frappe.otel_wsgi --aggregate [PROFILE_DIR] [OUTPUT_FILE]
	if "--distribution" in sys.argv:
		idx = sys.argv.index("--distribution")
		pdir = (
			sys.argv[idx + 1]
			if len(sys.argv) > idx + 1 and not sys.argv[idx + 1].startswith("-")
			else None
		)
		analyze_distribution(profile_dir=pdir)
	elif "--aggregate" in sys.argv:
		idx = sys.argv.index("--aggregate")
		pdir = (
			sys.argv[idx + 1]
			if len(sys.argv) > idx + 1 and not sys.argv[idx + 1].startswith("-")
			else None
		)
		out = (
			sys.argv[idx + 2]
			if len(sys.argv) > idx + 2 and not sys.argv[idx + 2].startswith("-")
			else None
		)
		aggregate_profiles(profile_dir=pdir, output_file=out)
	else:
		print("Usage:")
		print("  python -m frappe.otel_wsgi --distribution [PROFILE_DIR]")
		print("  python -m frappe.otel_wsgi --aggregate [PROFILE_DIR] [OUTPUT_FILE]")

