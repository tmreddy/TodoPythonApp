import importlib
import sys
import pytest
import os


def reload_config():
    # ensure a fresh import each time
    if "app.config" in sys.modules:
        del sys.modules["app.config"]
    return importlib.import_module("app.config")


def test_missing_database_url(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    with pytest.raises(RuntimeError) as exc:
        reload_config()
    assert "required" in str(exc.value).lower()


def test_bare_host_raises(monkeypatch):
    # mimic the symptom seen in the traceback when only a hostname is provided
    monkeypatch.setenv("DATABASE_URL", "todo.cyvg0owu6hcg.us-east-1.rds.amazonaws.com")
    with pytest.raises(RuntimeError) as exc:
        reload_config()
    assert "scheme" in str(exc.value).lower()
    assert "host" in str(exc.value).lower()


def test_valid_url(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    cfg = reload_config()
    assert cfg.DATABASE_URL.startswith("sqlite://")
