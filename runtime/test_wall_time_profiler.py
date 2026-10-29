import glob
import os
import shutil
import tempfile
import time
import unittest
from werkzeug.test import Client

from runtime.otel_wsgi import (
	WallTimeProfilerMiddleware,
	aggregate_profiles,
	analyze_distribution,
)


class TestWallTimeProfilerMiddleware(unittest.TestCase):
	def setUp(self):
		self.tmpdir = tempfile.mkdtemp(prefix="test_wall_prof_")

	def tearDown(self):
		shutil.rmtree(self.tmpdir, ignore_errors=True)

	def test_captures_wall_time_and_aggregates(self):
		def dummy_app(environ, start_response):
			path = environ.get("PATH_INFO", "")
			if path == "/api/method/ping":
				start_response("200 OK", [("Content-Type", "text/plain")])
				return [b"pong"]
			elif path == "/test-io":
				time.sleep(0.05)  # simulate 50ms I/O wait
				start_response("200 OK", [("Content-Type", "application/json")])
				return [b'{"status":"ok"}']
			start_response("404 Not Found", [("Content-Type", "text/plain")])
			return [b"404"]

		wrapped = WallTimeProfilerMiddleware(dummy_app, profile_dir=self.tmpdir)
		client = Client(wrapped)

		# 1. Ignored endpoint: /api/method/ping
		res_ping = client.get("/api/method/ping")
		self.assertEqual(res_ping.status_code, 200)
		self.assertEqual(len(glob.glob(os.path.join(self.tmpdir, "*.prof"))), 0)

		# 2. Profiled endpoints
		res1 = client.get("/test-io")
		res2 = client.get("/test-io")
		self.assertEqual(res1.status_code, 200)
		self.assertEqual(res2.status_code, 200)

		profiles = sorted(glob.glob(os.path.join(self.tmpdir, "*.prof")))
		self.assertEqual(len(profiles), 2)

		# 3. Aggregate profiles
		out_file = os.path.join(self.tmpdir, "merged.prof")
		res_out = aggregate_profiles(self.tmpdir, output_file=out_file, top_n=5)
		self.assertEqual(res_out, out_file)
		self.assertTrue(os.path.exists(out_file))

		# 4. Verify wall-clock time was recorded (>= 0.09s total across both requests)
		import pstats

		stats = pstats.Stats(out_file)
		self.assertGreaterEqual(stats.total_tt, 0.09)

		# 5. Distribution analysis
		dist = analyze_distribution(self.tmpdir)
		self.assertEqual(dist["count"], 2)
		self.assertGreaterEqual(dist["p50"], 45.0)  # in ms


if __name__ == "__main__":
	unittest.main()
