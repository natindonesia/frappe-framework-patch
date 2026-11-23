#!/usr/bin/env python3
"""Restore the frappe.local binding that an upstream test throws away.

``frappe.tests.test_otel.TestJobSpans.tearDown`` deletes ``frappe.local.site``
(and ``user``) instead of restoring them, so every module that runs afterwards
in the same process loses its site: they fail with ``AttributeError: site``,
``TestPerformance`` re-initialises a bogus ``test_site``, and the sharded runner
finally dies with ``RuntimeError: object is not bound`` before printing its
execution summary (the shard then reports no results at all).

The full-suite job runs this script inside the ``web`` container before the
suite starts. It is intentionally a no-op when the upstream anchor is gone, so
a fix landed upstream simply stops applying the rewrite; it never touches
production code paths, only the test file that ships in the image.
"""

from __future__ import annotations

import pathlib
import sys

TEST_FILE = pathlib.Path("/home/frappe/frappe-bench/apps/frappe/frappe/tests/test_otel.py")

ANCHOR = """class TestJobSpans(OTelInProcessTestCase):
\tdef tearDown(self):
\t\tif hasattr(frappe.local, "site"):
\t\t\tdelattr(frappe.local, "site")
\t\tif hasattr(frappe.local, "user"):
\t\t\tdelattr(frappe.local, "user")
\t\tsuper().tearDown()
"""

REPLACEMENT = """class TestJobSpans(OTelInProcessTestCase):
\tdef setUp(self):
\t\tself._saved_locals = {key: getattr(frappe.local, key, None) for key in ("site", "user")}
\t\tsuper().setUp()

\tdef tearDown(self):
\t\tfor key, value in self._saved_locals.items():
\t\t\tif value is not None:
\t\t\t\tsetattr(frappe.local, key, value)
\t\tsuper().tearDown()
"""


def main() -> int:
	if not TEST_FILE.is_file():
		print(f"{TEST_FILE} not found; nothing to patch")
		return 0

	source = TEST_FILE.read_text()
	if ANCHOR not in source:
		print("upstream test_otel.py no longer deletes frappe.local.site; nothing to patch")
		return 0

	TEST_FILE.write_text(source.replace(ANCHOR, REPLACEMENT, 1))
	print(f"restored saved frappe.local.site/user in {TEST_FILE}")
	return 0


if __name__ == "__main__":
	sys.exit(main())
