import importlib
import sys
import types
import logging
import pytest

# we don’t depend on botocore in the test environment, so simply raise a
# generic exception when the fake handler is instantiated


def reload_main():
    # reload the app.main module fresh
    if "app.main" in sys.modules:
        del sys.modules["app.main"]
    return importlib.import_module("app.main")


def test_watchtower_not_installed(monkeypatch):
    # provide a valid DATABASE_URL so config import succeeds
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    # ensure import works when watchtower is absent
    monkeypatch.setitem(sys.modules, "watchtower", None)
    monkeypatch.delenv("CLOUDWATCH_LOG_GROUP", raising=False)
    reload_main()  # should not raise


def test_watchtower_handler_fails(monkeypatch, caplog):
    # provide valid DATABASE_URL so config import succeeds
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    # make a fake watchtower module whose constructor raises some error (e.g.
    # missing region, credentials, etc.).  The exact exception type doesn’t
    # matter since the application catches `Exception`.
    fake = types.SimpleNamespace()
    def failing_handler(*args, **kwargs):
        raise RuntimeError("no region")
    fake.CloudWatchLogHandler = failing_handler
    monkeypatch.setitem(sys.modules, "watchtower", fake)

    caplog.set_level(logging.WARNING)
    reload_main()  # import should not raise
    assert "CloudWatch handler unavailable" in caplog.text


def test_watchtower_respects_region(monkeypatch):
    # the value of AWS_REGION should be passed through to the handler
    monkeypatch.setenv("DATABASE_URL", "sqlite:///:memory:")
    monkeypatch.setenv("AWS_REGION", "eu-west-1")
    captured = {}

    fake = types.SimpleNamespace()
    def handler(log_group, region_name=None):
        captured["group"] = log_group
        captured["region"] = region_name
        class Dummy:
            pass
        return Dummy()
    fake.CloudWatchLogHandler = handler
    monkeypatch.setitem(sys.modules, "watchtower", fake)

    reload_main()  # should succeed
    assert captured.get("region") == "eu-west-1"
