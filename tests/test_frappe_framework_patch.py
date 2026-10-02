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
  2. Patch delta (patch vs pristine base must genuinely differ)
        - every patch defines exactly one observable marker;
        - pristine tree: markers flipped the "unpatched" way;
        - patched tree:  markers flipped the "patched" way;
        - the CI patch-delta script and workflow step exist and cover every patch.
  2. Functional (OTel, optional)
       - the trace_context helper imports and reports availability;
       - a W3C trace-context roundtrip works when OpenTelemetry is installed;
       - these are skipped with a clear message when opentelemetry is unavailable.

Run from the repository root:
    python -m unittest discover -s tests -p 'test_*.py' -t .
or use the convenience wrapper tests/run_tests.sh.
"""

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SUBMODULE = REPO_ROOT / "frappe"
PATCHES_DIR = REPO_ROOT / "patches"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "build-images.yml"

# Files the patch set is expected to produce/touch (relative to the submodule root).
PATCHED_FILES = [
    "frappe/integrations/trace_context.py",
    "frappe/utils/background_jobs.py",
]

# The patch-delta contract. One marker per patch under patches/:
#   (patch filename, submodule-relative path, fixed-string marker, kind)
# kind "added":   pristine tree must NOT contain the marker, patched tree MUST.
# kind "removed": pristine tree must contain the marker, patched tree must NOT.
# Keep in sync with scripts/ci/patch-delta-verify.sh (which checks the same
# markers INSIDE the built frappe:latest / frappe:base images).
PATCH_DELTA_SCRIPT = REPO_ROOT / "scripts" / "ci" / "patch-delta-verify.sh"
PATCH_MARKERS = [
    (
        "0001-otel-trace-context-propagation.patch",
        "frappe/integrations/trace_context.py",
        "def get_trace_context",
        "added",
    ),
    (
        "0002-remove-frappe-build-comment.patch",
        "frappe/templates/base.html",
        "Built on Frappe",
        "removed",
    ),
    (
        "0003-desktop-remove-frappe-support-link.patch",
        "frappe/desk/page/desktop/desktop.js",
        "Frappe Support",
        "removed",
    ),
    (
        "0004-desktop-remove-about-link.patch",
        "frappe/desk/page/desktop/desktop.js",
        "frappe.ui.toolbar.show_about",
        "removed",
    ),
    (
        "0005-sidebar-remove-crm-banner.patch",
        "frappe/public/js/frappe/ui/sidebar/sidebar.js",
        "Switch to CRM",
        "removed",
    ),
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


def _marker_present(root: Path, rel: str, marker: str) -> bool:
    target = root / rel
    if not target.exists():
        return False
    return marker in target.read_text(errors="replace")


class PatchDeltaTests(unittest.TestCase):
    """Patch vs pristine base must genuinely differ: every patch flips exactly
    one observable marker, in the right direction. Runs against a pristine
    `git archive` copy — no Docker, no submodule mutation."""

    def setUp(self):
        if not (SUBMODULE / "frappe").exists():
            self.fail("submodule ./frappe not initialized; run `git submodule update --init`")

    def test_every_patch_has_exactly_one_marker(self):
        patch_names = sorted(p.name for p in PATCHES_DIR.glob("*.patch"))
        marker_names = sorted(m[0] for m in PATCH_MARKERS)
        self.assertEqual(patch_names, marker_names, "every patch needs a marker entry")
        self.assertGreater(len(marker_names), 0, "no *.patch files under patches/")

    def test_marker_paths_exist_in_pristine_tree(self):
        tmp = _pristine_tree()
        try:
            root = tmp / "frappe"
            for patch, rel, marker, kind in PATCH_MARKERS:
                if kind == "removed":
                    self.assertTrue(
                        (root / rel).exists(),
                        f"{patch}: {rel} must exist upstream for a removal patch",
                    )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_pristine_tree_is_unpatched_on_every_marker(self):
        tmp = _pristine_tree()
        try:
            root = tmp / "frappe"
            for patch, rel, marker, kind in PATCH_MARKERS:
                present = _marker_present(root, rel, marker)
                self.assertEqual(
                    present, kind == "removed",
                    f"{patch}: pristine base marker state wrong for {rel} :: {marker}",
                )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_patched_tree_flips_every_marker(self):
        tmp = _pristine_tree()
        try:
            root = tmp / "frappe"
            _apply_patches(tmp)
            for patch, rel, marker, kind in PATCH_MARKERS:
                present = _marker_present(root, rel, marker)
                self.assertEqual(
                    present, kind == "added",
                    f"{patch}: patched tree marker state wrong for {rel} :: {marker}",
                )
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_patch_delta_script_and_workflow_step_exist(self):
        self.assertTrue(PATCH_DELTA_SCRIPT.exists(), f"missing {PATCH_DELTA_SCRIPT}")
        script = PATCH_DELTA_SCRIPT.read_text()
        for patch, rel, marker, kind in PATCH_MARKERS:
            self.assertIn(patch, script, f"{PATCH_DELTA_SCRIPT.name} must reference {patch}")
            self.assertIn(rel, script, f"{PATCH_DELTA_SCRIPT.name} must check {rel}")
            self.assertIn(marker, script, f"{PATCH_DELTA_SCRIPT.name} must check marker from {patch}")
        self.assertIn("frappe:latest", script)
        self.assertIn("frappe:base", script)
        self.assertTrue(WORKFLOW.exists(), f"workflow missing: {WORKFLOW}")
        steps = WORKFLOW.read_text()
        self.assertIn("patch-delta-verify.sh", steps, "workflow must run the patch-delta check")


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
        # Install a recording tracer provider ONCE. The SDK rejects (with a warning)
        # any later set_tracer_provider call once a non-noop provider is installed, so
        # this must be the FIRST (and only) place we set it. All tests share it.
        from opentelemetry import trace as otel_trace

        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import SimpleSpanProcessor
        try:
            from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter  # modern SDK (>=1.4x)
        except ImportError:  # older SDK still ships it in the package __init__
            from opentelemetry.sdk.trace.export import InMemorySpanExporter

        cls.exporter = InMemorySpanExporter()
        provider = TracerProvider()
        provider.add_span_processor(SimpleSpanProcessor(cls.exporter))
        otel_trace.set_tracer_provider(provider)

    def test_is_available_true(self):
        self.assertTrue(self._tc.is_available())

    def test_get_trace_context_empty_without_active_span(self):
        self.assertEqual(self._tc.get_trace_context(), {})

    def test_w3c_trace_context_roundtrip(self):
        from opentelemetry import trace as otel_trace

        tracer = otel_trace.get_tracer("frappe-framework-patch.test")
        span = tracer.start_span("background-job")
        with otel_trace.use_span(span, end_on_exit=False):
            carrier = self._tc.get_trace_context()
        self.assertIn("traceparent", carrier, "recording span should inject traceparent")

        token = self._tc.attach_trace_context(carrier)
        self.assertIsNotNone(token, "attach_trace_context should return an attach token")
        self._tc.detach_trace_context(token)

        span.end()


class WorkflowStructureTests(unittest.TestCase):
    """Static assertions that the consolidated CI matrix is correctly wired:
    exactly three variants, all consuming the exact tested-image archive, and
    publish gated behind the matrix. No Docker/network required."""

    def setUp(self):
        self.assertTrue(WORKFLOW.exists(), f"workflow missing: {WORKFLOW}")
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed")
        self.workflow = yaml.safe_load(WORKFLOW.read_text())

    def test_matrix_has_exactly_three_variants(self):
        m = self.workflow["jobs"]["variant-matrix"]["strategy"]["matrix"]["variant"]
        self.assertEqual(sorted(m), ["base", "latest", "latest-granian"])

    def test_matrix_downloads_and_loads_tested_images(self):
        job = self.workflow["jobs"]["variant-matrix"]
        steps = "\n".join(
            f'{s.get("name","")} :: {s.get("uses","")} :: {s.get("run","")} :: {s.get("with",{})}'
            for s in job["steps"]
        )
        self.assertIn("tested-vanilla-and-granian-images", steps, "matrix must download the tested-images archive")
        self.assertIn("gunzip", steps, "matrix must load the exported archive")
        self.assertIn("matrix-variant-test.sh", steps, "matrix must invoke the variant-aware test")
        # Matrix must never rebuild; it must consume the artifact.
        for s in job["steps"]:
            run = s.get("run", "")
            self.assertNotIn("vanilla-build.sh", run)
            self.assertNotIn("base-build.sh", run)
            self.assertNotIn("granian-build.sh", run)

    def test_matrix_needs_images_job(self):
        self.assertEqual(
            self.workflow["jobs"]["variant-matrix"]["needs"], "images",
            "variant-matrix must build only after the images job produced the archive",
        )

    def test_publish_depends_on_matrix(self):
        self.assertIn(
            "variant-matrix", self.workflow["jobs"]["publish"]["needs"],
            "publish must be gated behind variant-matrix",
        )

    def test_images_job_builds_all_three_and_granian_from_latest(self):
        job = self.workflow["jobs"]["images"]
        steps = "\n".join(s.get("run", "") for s in job["steps"])
        for script in ("vanilla-build.sh", "base-build.sh", "granian-build.sh", "granian-verify.sh"):
            self.assertIn(script, steps, f"images job must run {script}")
        self.assertIn("tested-images.tar.gz", steps, "images job must export exact tested images")
        # granian-build.sh preserves the explicit FROM base=frappe:latest contract.
        gb = Path(REPO_ROOT) / "scripts" / "ci" / "granian-build.sh"
        self.assertIn("BASE_IMAGE=frappe:latest", gb.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
