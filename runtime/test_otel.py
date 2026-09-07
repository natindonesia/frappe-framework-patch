import io
import json
import os
import subprocess
import sys
import unittest
from unittest import mock

import frappe
import frappe.otel as otel

try:
	import opentelemetry.trace  # noqa: F401

	HAVE_OTEL = True
except ImportError:
	HAVE_OTEL = False

if HAVE_OTEL:
	from opentelemetry import trace as otel_trace
	from opentelemetry.sdk.trace import TracerProvider
	from opentelemetry.sdk.trace.export import SimpleSpanProcessor
	from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

FRAPPE_ROOT = os.path.dirname(os.path.dirname(frappe.__file__))


def _run_python(script: str, **extra_env) -> subprocess.CompletedProcess:
	env = os.environ.copy()
	env["PYTHONPATH"] = FRAPPE_ROOT + os.pathsep + env.get("PYTHONPATH", "")
	for key in (
		"OTEL_EXPORTER_OTLP_ENDPOINT",
		"OTEL_SERVICE_NAME",
		"OTEL_TRACES_SAMPLER",
		"OTEL_TRACES_SAMPLER_ARG",
	):
		env.pop(key, None)
	env.update(extra_env)
	return subprocess.run(
		[sys.executable, "-c", script],
		env=env,
		cwd=FRAPPE_ROOT,
		capture_output=True,
		text=True,
		timeout=180,
	)


class TestOtelGate(unittest.TestCase):
	"""Tests that must pass even with opentelemetry not installed."""

	def test_boot_noop_without_env(self):
		with mock.patch.dict(os.environ, {"OTEL_EXPORTER_OTLP_ENDPOINT": ""}):
			otel.boot()
		self.assertFalse(otel._booted)
		self.assertFalse(otel._enabled)
		self.assertIsNone(otel._tracer)

	def test_import_is_lazy_and_boot_is_noop_without_env(self):
		# Runs in a subprocess with a clean module state; asserts both that
		# importing frappe.otel (and calling boot without env) pulls in zero
		# opentelemetry modules and that the gate stays closed.
		script = (
			"import sys\n"
			"import frappe.otel\n"
			"frappe.otel.boot()\n"
			"assert not frappe.otel._booted\n"
			"assert not frappe.otel._enabled\n"
			"assert not [m for m in sys.modules if m.startswith('opentelemetry')], sorted(\n"
			"    m for m in sys.modules if m.startswith('opentelemetry')\n"
			")\n"
		)
		proc = _run_python(script)
		self.assertEqual(proc.returncode, 0, proc.stderr)


@unittest.skipUnless(HAVE_OTEL, "requires opentelemetry packages")
class OTelInProcessTestCase(unittest.TestCase):
	def setUp(self):
		self._saved = (otel._enabled, otel._booted, otel._tracer)
		self.exporter = InMemorySpanExporter()
		self.provider = TracerProvider()
		self.provider.add_span_processor(SimpleSpanProcessor(self.exporter))
		otel._booted = True
		otel._enabled = True
		otel._tracer = self.provider.get_tracer("frappe.test")

	def tearDown(self):
		self.provider.force_flush()
		otel._enabled, otel._booted, otel._tracer = self._saved
		for attr in ("_otel_job_span", "_otel_job_context_token"):
			if hasattr(frappe.local, attr):
				delattr(frappe.local, attr)

	def get_finished_spans(self):
		self.provider.force_flush()
		return self.exporter.get_finished_spans()


class TestSqlSpanWrapper(OTelInProcessTestCase):
	class FakeDb:
		db_type = "mariadb"

	def test_run_false_creates_no_span(self):
		from frappe.database.database import Database

		otel._patch_sql()
		db = object.__new__(Database)
		db.db_type = "mariadb"

		result = db.sql("select 1", run=False)

		self.assertEqual(result, "select 1")
		self.assertEqual(len(self.get_finished_spans()), 0)

	def test_span_name_and_attributes(self):
		def stub(self, *args, **kwargs):
			return "ok"

		result = otel._sql_span_wrapper(stub, self.FakeDb(), "select 1")
		self.assertEqual(result, "ok")

		spans = self.get_finished_spans()
		self.assertEqual(len(spans), 1)
		span = spans[0]
		self.assertEqual(span.name, "SELECT")
		self.assertEqual(span.attributes["db.statement"], "select 1")
		self.assertEqual(span.attributes["db.system"], "mariadb")

	def test_ddl_query_span_name(self):
		def stub(self, *args, **kwargs):
			return "ok"

		otel._sql_span_wrapper(stub, self.FakeDb(), "create table t (id int)")
		spans = self.get_finished_spans()
		self.assertEqual(len(spans), 1)
		self.assertEqual(spans[0].name, "CREATE")

	def test_unknown_query_span_name(self):
		def stub(self, *args, **kwargs):
			return "ok"

		otel._sql_span_wrapper(stub, self.FakeDb(), "explain analyze select 1")
		spans = self.get_finished_spans()
		self.assertEqual(len(spans), 1)
		self.assertEqual(spans[0].name, "SQL")

	def test_exception_records_error(self):
		from opentelemetry.trace import StatusCode

		def boom(self, *args, **kwargs):
			raise ValueError("boom")

		with self.assertRaises(ValueError):
			otel._sql_span_wrapper(boom, self.FakeDb(), "select 1")

		spans = self.get_finished_spans()
		self.assertEqual(len(spans), 1)
		self.assertEqual(spans[0].status.status_code, StatusCode.ERROR)
		self.assertGreaterEqual(len(spans[0].events), 1)

	def test_statement_truncated(self):
		def stub(self, *args, **kwargs):
			return "ok"

		otel._sql_span_wrapper(stub, self.FakeDb(), "select " + "x" * 5000)
		spans = self.get_finished_spans()
		self.assertEqual(len(spans[0].attributes["db.statement"]), 2000)


class TestJobSpans(OTelInProcessTestCase):
	def tearDown(self):
		if hasattr(frappe.local, "site"):
			delattr(frappe.local, "site")
		if hasattr(frappe.local, "user"):
			delattr(frappe.local, "user")
		super().tearDown()

	def test_before_after_job_exports_span(self):
		frappe.local.site = "tests.local"
		frappe.local.user = "test@example.com"

		otel.before_job(method="x.y")
		self.assertIsNotNone(getattr(frappe.local, "_otel_job_span", None))
		otel.after_job(method="x.y")
		self.assertIsNone(getattr(frappe.local, "_otel_job_span", None))

		spans = self.get_finished_spans()
		self.assertEqual(len(spans), 1)
		self.assertEqual(spans[0].name, "frappe.job x.y")
		self.assertEqual(spans[0].attributes["frappe.job.method"], "x.y")
		self.assertEqual(spans[0].attributes["frappe.site"], "tests.local")
		self.assertEqual(spans[0].attributes["frappe.job.user"], "test@example.com")

	def test_after_job_without_before_job_is_noop(self):
		otel.after_job(method="x.y")
		self.assertEqual(len(self.get_finished_spans()), 0)

	def test_noop_when_disabled(self):
		otel._enabled = False
		otel.before_job(method="x.y")
		self.assertIsNone(getattr(frappe.local, "_otel_job_span", None))
		otel.after_job(method="x.y")
		self.assertEqual(len(self.get_finished_spans()), 0)


@unittest.skipUnless(HAVE_OTEL, "requires opentelemetry packages")
class TestBoot(unittest.TestCase):
	def test_boot_in_subprocess(self):
		script = (
			"import json\n"
			"import frappe.otel\n"
			"frappe.otel.boot()\n"
			"print(json.dumps({'booted': frappe.otel._booted, 'enabled': frappe.otel._enabled}))\n"
		)
		proc = _run_python(script, OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318")
		self.assertEqual(proc.returncode, 0, proc.stderr)
		data = json.loads(proc.stdout.strip().splitlines()[-1])
		self.assertTrue(data["booted"])
		self.assertTrue(data["enabled"])

	def test_boot_with_sampler_env_in_subprocess(self):
		script = (
			"import json\n"
			"import frappe.otel\n"
			"frappe.otel.boot()\n"
			"print(json.dumps({'booted': frappe.otel._booted, 'enabled': frappe.otel._enabled}))\n"
		)
		proc = _run_python(
			script,
			OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318",
			OTEL_TRACES_SAMPLER="parentbased_traceidratio",
			OTEL_TRACES_SAMPLER_ARG="0.5",
		)
		self.assertEqual(proc.returncode, 0, proc.stderr)
		data = json.loads(proc.stdout.strip().splitlines()[-1])
		self.assertTrue(data["booted"])


@unittest.skipUnless(HAVE_OTEL, "requires opentelemetry packages")
class TestWrapApplication(unittest.TestCase):
	def test_middleware_creates_request_span(self):
		script = """
import io
import json


def main():
	from opentelemetry import trace
	from opentelemetry.sdk.trace import TracerProvider
	from opentelemetry.sdk.trace.export import SimpleSpanProcessor
	from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

	exporter = InMemorySpanExporter()
	provider = TracerProvider()
	provider.add_span_processor(SimpleSpanProcessor(exporter))
	trace.set_tracer_provider(provider)

	import frappe.otel

	frappe.otel._booted = True
	frappe.otel._enabled = True

	def app(environ, start_response):
		start_response("200 OK", [("Content-Type", "text/plain")])
		return [b"ok"]

	middleware = frappe.otel.wrap_application(app)

	environ = {
		"REQUEST_METHOD": "GET",
		"PATH_INFO": "/",
		"QUERY_STRING": "",
		"SERVER_NAME": "localhost",
		"SERVER_PORT": "80",
		"SERVER_PROTOCOL": "HTTP/1.1",
		"HTTP_HOST": "tests.local:8000",
		"HTTP_TRACEPARENT": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
		"wsgi.version": (1, 0),
		"wsgi.url_scheme": "http",
		"wsgi.input": io.BytesIO(),
		"wsgi.errors": io.StringIO(),
		"wsgi.multithread": False,
		"wsgi.multiprocess": False,
		"wsgi.run_once": False,
	}

	status = {}

	def start_response(s, headers, exc_info=None):
		status["status"] = s

	body = middleware(environ, start_response)
	for chunk in body:
		pass
	if hasattr(body, "close"):
		body.close()

	provider.force_flush()
	spans = [
		{"name": s.name, "attributes": {k: str(v) for k, v in dict(s.attributes or {}).items()}}
		for s in exporter.get_finished_spans()
	]
	print(json.dumps({"status": status.get("status"), "spans": spans}))


main()
"""
		proc = _run_python(script)
		self.assertEqual(proc.returncode, 0, proc.stderr)
		data = json.loads(proc.stdout.strip().splitlines()[-1])
		self.assertEqual(data["status"], "200 OK")
		spans = data["spans"]
		self.assertTrue(spans, "expected at least one exported span")
		self.assertTrue(all(s["name"].startswith("GET") for s in spans), spans)
		self.assertTrue(any(s["attributes"].get("http.method") == "GET" for s in spans), spans)
		self.assertTrue(any(s["attributes"].get("frappe.site") == "tests.local" for s in spans), spans)


if __name__ == "__main__":
	unittest.main()
