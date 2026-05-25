"""m23 proto-envelope compatibility tests for tools/tui.py:_read_status.

The Python sidecar must accept both shapes during the transition:
 - Legacy bare-payload (pre-m23): {"version":1,"milestone":"m22",...}
 - m23 envelope: {"proto":"tekhton.tui.status.v1","run_id":"...","payload":{...}}

An unknown proto major must produce a None return so the sidecar keeps the
last valid frame visible (skew-loud-not-silent invariant).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import tui  # tools/tui.py


def _write_status(tmp_path: Path, doc) -> Path:
    p = tmp_path / "tui_status.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    return p


def test_read_legacy_bare_payload(tmp_path: Path):
    legacy = {
        "version": 1,
        "milestone": "m22",
        "stage_label": "Coder",
        "complete": False,
    }
    path = _write_status(tmp_path, legacy)
    got = tui._read_status(path)
    assert got is not None
    assert got["milestone"] == "m22"
    assert got["stage_label"] == "Coder"


def test_read_proto_envelope_v1(tmp_path: Path):
    env = {
        "proto": "tekhton.tui.status.v1",
        "run_id": "20260525_120000",
        "payload": {
            "version": 1,
            "milestone": "m23",
            "stage_label": "Tester",
            "complete": False,
        },
    }
    path = _write_status(tmp_path, env)
    got = tui._read_status(path)
    assert got is not None
    assert got["milestone"] == "m23"
    assert got["stage_label"] == "Tester"


def test_read_unknown_proto_major_returns_none(tmp_path: Path):
    env = {
        "proto": "tekhton.tui.status.v9",  # major drift, unknown
        "payload": {"milestone": "future"},
    }
    path = _write_status(tmp_path, env)
    assert tui._read_status(path) is None


def test_read_envelope_with_missing_payload(tmp_path: Path):
    env = {"proto": "tekhton.tui.status.v1"}
    path = _write_status(tmp_path, env)
    assert tui._read_status(path) is None


def test_read_invalid_json_returns_none(tmp_path: Path):
    path = tmp_path / "tui_status.json"
    path.write_text("not json", encoding="utf-8")
    assert tui._read_status(path) is None


def test_read_missing_file_returns_none(tmp_path: Path):
    assert tui._read_status(tmp_path / "missing.json") is None
