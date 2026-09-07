"""
Tests for the frappe-framework-patch layer.

NON-DESTRUCTIVE: these tests never modify the ./frappe submodule. The patched-piece
checks run against a pristine copy produced with `git archive` (the exact pinned
tree, no .git), so the repository submodule working tree is left untouched.

Coverage:

  1. Structural / static
       - the pinned submodule exists and is a clean git checkout at HEAD;
       - every *.patch under patches/ applies to the pristine pinned tree;
       - the patched Python sources compile (py_compile).
  2. Functional (OTel, optional)
       - the trace_context helper imports and reports availability;
       - a W3C trace-context roundtrip works when OpenTelemetry is installed;
       - these are skipped with a clear message when opentelemetry is unavailable.

Run from the repository root:
    python -m unittest discover -s tests -p 'test_*.py' -t .
or use the convenience wrapper tests/run_tests.sh.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SUBMODULE = REPO_ROOT / "frappe"
PATCHES_DIR = REPO_ROOT / "patches"

# Files the patch set is expected to produce/touch (relative to the submodule root).
PATCHED_FILES = [
    "frappe/integrations/trace_context.py",
    "frappe/utils/background_jobs.py",
]


def git(cmd, cwd):
    return subprocess.run(["git"] + list(cmd), cwd=cwd, capture_output=True, text=True)


def _pristine_tree():
    """Return a temp dir containing the pristine upstream tree at the pinned SHA.
    The caller is responsible for cleanup (remove the returned tempdir)."""
    tmp = Path(tempfile.mkdtemp(prefix="frappe-fw-patch-test-"))
    root = tmp / "frappe"
    root.mkdir()
    tar = tmp / "tree.tar"
    with tar.open("wb") as fh:
        proc = subprocess.run(["git", "archive", "HEAD"], cwd=SUBMODULE, stdout=fh)
    if proc.returncode != 0:
        shutil.rmtree(tmp, ignore_errors=True)
        raise RuntimeError("git archive of the submodule failed")
    subprocess.run(["tar", "-x", "-C", str(root), "-f", str(tar)], check=True)
    tar.unlink()
    return tmp


def _apply_patches(tree_root):
    """Apply every patch under patches/ onto tree_root/frappe. Raises on failure."""
    root = tree_root / "frappe"
    for patch in sorted(PATCHES_DIR.glob("*.patch")):
        res = git(["apply", str(patch)], root)
        if res.returncode != 0:
            raise AssertionError(
                f"patch {patch.name} failed:\n{res.stdout}\n{res.stderr}"
            )


def py_compile_file(target: Path):
    import py_compile
    py_compile.compile(str(target), doraise=True)


class PatchApplyTests(unittest.TestCase):
    def setUp(self):
        if not (SUBMODULE / "frappe").exists():
            self.fail("submodule ./frappe not initialized; run `git submodule update --init`")
        patches = sorted(PATCHES_DIR.glob("*.patch"))
        self.assertGreater(len(patches), 0, "no *.patch files under patches/")
        self.patches = patches

    def test_submodule_is_clean(self):
        out = git(["status", "--porcelain"], SUBMODULE)
        self.assertEqual(out.stdout.strip(), "", f"submodule dirty:\n{out.stdout}")

    def test_patches_apply_to_pristine_tree_and_compile(self):
        tmp = _pristine_tree()
        try:
            root = tmp / "frappe"
            _apply_patches(tmp)
            for rel in PATCHED_FILES:
                target = root / rel
                self.assertTrue(target.exists(), f"{rel} missing after applying")

            py_compile_file(root / "frappe/integrations/trace_context.py")
            py_compile_file(root / "frappe/utils/background_jobs.py")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


def _load_trace_module():
    """Import the patched trace_context helper standalone (it has no frappe-package
    import, so we can load it without the heavy frappe machinery)."""
    tmp = _pristine_tree()
    try:
        _apply_patches(tmp)
        bench = tmp / "frappe" / "frappe"
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    sys.path.insert(0, str(bench / "integrations"))
    import trace_context
    return trace_context


_OTEL_IMPORTABLE = False
try:
    import opentelemetry  # noqa: F401
    _OTEL_IMPORTABLE = True
except Exception:
    _OTEL_IMPORTABLE = False


@unittest.skipUnless(_OTEL_IMPORTABLE, "opentelemetry not installed (install in a venv to run)")
class OTelPropagationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tc = _load_trace_module()

    def setUp(self):
        # ensure a clean no-op tracer provider before each test
        from opentelemetry import trace as otel_trace
        otel_trace.set_tracer_provider(None)

    def test_is_available_true(self):
        self.assertTrue(self._tc.is_available())

    def test_get_trace_context_empty_without_active_span(self):
        self.assertEqual(self._tc.get_trace_context(), {})

    def test_w3c_trace_context_roundtrip(self):
        from opentelemetry import trace as otel_trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import (
            InMemorySpanExporter,
            SimpleSpanProcessor,
        )

        exporter = InMemorySpanExporter()
        provider = TracerProvider()
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        otel_trace.set_tracer_provider(provider)

        tracer = provider.get_tracer("frappe-framework-patch.test")
        span = tracer.start_span("background-job")
        with otel_trace.use_span(span, end=False):
            carrier = self._tc.get_trace_context()
        self.assertIn("traceparent", carrier, "recording span should inject traceparent")

        token = self._tc.attach_trace_context(carrier)
        self.assertIsNotNone(token, "attach_trace_context should return an attach token")
        self._tc.detach_trace_context(token)

        span.end()
        otel_trace.set_tracer_provider(None)


if __name__ == "__main__":
    unittest.main(verbosity=2)