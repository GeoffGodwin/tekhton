"""Shared test fixtures for repo map tool tests."""

from __future__ import annotations

import os
import tempfile
from typing import Generator

import pytest


@pytest.fixture
def tmp_project(tmp_path: os.PathLike) -> os.PathLike:
    """Create a temporary project directory with sample source files."""
    # Python file
    py_file = tmp_path / "src" / "models" / "user.py"
    py_file.parent.mkdir(parents=True)
    py_file.write_text(
        'class User:\n'
        '    def __init__(self, name, email):\n'
        '        self.name = name\n'
        '        self.email = email\n'
        '\n'
        '    def validate(self) -> bool:\n'
        '        return bool(self.name and self.email)\n'
        '\n'
        '    def to_dict(self) -> dict:\n'
        '        return {"name": self.name, "email": self.email}\n'
    )

    # Python file that imports from user.py
    routes_file = tmp_path / "src" / "api" / "routes.py"
    routes_file.parent.mkdir(parents=True)
    routes_file.write_text(
        'from src.models.user import User\n'
        '\n'
        'def register_routes(app):\n'
        '    pass\n'
        '\n'
        'def handle_user_create(request):\n'
        '    user = User(request.name, request.email)\n'
        '    user.validate()\n'
        '    return user.to_dict()\n'
    )

    # Python file with no imports
    db_file = tmp_path / "src" / "db" / "connection.py"
    db_file.parent.mkdir(parents=True)
    db_file.write_text(
        'class DatabasePool:\n'
        '    def get_connection(self):\n'
        '        pass\n'
        '\n'
        '    def release(self, conn):\n'
        '        pass\n'
    )

    return tmp_path


@pytest.fixture
def cache_dir(tmp_path: os.PathLike) -> os.PathLike:
    """Create a temporary cache directory."""
    d = tmp_path / "cache"
    d.mkdir()
    return d
