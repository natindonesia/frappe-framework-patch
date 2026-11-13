#!/usr/bin/env python3
"""Relax the pinned Frappe pyproject.toml so it installs on CPython 3.15.

EXPERIMENTAL. Used only by the py315 image build (Dockerfile build arg
RELAX_FRAPPE_PYPROJECT). It rewrites the copy of the submodule inside the build
context; the submodule itself is never modified.

Each replacement is the smallest version jump whose package ships a cp315
(or abi3) manylinux x86_64 wheel on PyPI, checked on 2026-11-13. Every expected
original string must match exactly once, so upstream pin drift fails the build
loudly instead of silently shipping an unintended dependency set.

Packages deliberately left untouched:
  RestrictedPython~=8.5  (8.5 already declares requires-python <3.16)
  psutil~=7.0.0          (abi3 wheel)
  mysqlclient, PyYAML    (no wheel on 3.15 either way; built from source)
"""

import sys

REPLACEMENTS = [
    ('requires-python = ">=3.14,<3.15"', 'requires-python = ">=3.14,<3.16"'),
    ("duckdb~=1.4.3", "duckdb>=2.0.0,<3"),
    ("pyarrow~=25.0.0", "pyarrow>=26.0.0,<27"),
    ("orjson~=3.11.5", "orjson>=3.12.0,<4"),
    ("hiredis~=3.3.0", "hiredis>=3.5.0,<4"),
    ("pydantic~=2.12.5", "pydantic>=2.14.0,<2.15"),
    ("plutoprint~=0.22.0", "plutoprint>=0.23.0,<0.24"),
]


def main(path: str) -> int:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    for old, new in REPLACEMENTS:
        count = text.count(old)
        if count != 1:
            print(f"ERROR: expected exactly one {old!r} in {path}, found {count}", file=sys.stderr)
            return 1
        text = text.replace(old, new)
        print(f"relaxed: {old} -> {new}")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path/to/pyproject.toml>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
