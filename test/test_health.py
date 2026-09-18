"""Liveness and readiness probe behaviour.

Kubernetes and AWS target groups decide health from the HTTP *status code* and
never look at the response body, so these two endpoints have to differ in the
status code they return when the database is unreachable:

  /.well-known/health  -> always 200 while the process runs   (liveness)
  /.well-known/ready   -> 503 when the database is unreachable (readiness)

Getting this backwards is a real outage: a liveness probe that fails during a
database outage makes Kubernetes restart every pod in a loop, and a readiness
probe that always passes routes live traffic to pods that cannot serve it.
"""
import os

# app.config raises at import time if DATABASE_URL is unset, so provide one
# before importing the app. setdefault keeps whatever another test module set.
os.environ.setdefault("DATABASE_URL", "sqlite:///:memory:")

from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app import main

client = TestClient(main.app)


def working_engine():
    return create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )


class UnreachableEngine:
    """Stands in for a database that is down, refusing every connection."""

    def connect(self):
        raise RuntimeError("could not connect to server: Connection refused")


def test_health_reports_connected_when_database_is_up(monkeypatch):
    monkeypatch.setattr(main, "engine", working_engine())
    response = client.get("/.well-known/health")
    assert response.status_code == 200
    assert response.json()["database"] == "connected"


def test_health_stays_200_when_database_is_down(monkeypatch):
    """Liveness must survive a database outage: a restart would not fix it."""
    monkeypatch.setattr(main, "engine", UnreachableEngine())
    response = client.get("/.well-known/health")
    assert response.status_code == 200
    assert response.json()["database"] == "disconnected"


def test_ready_returns_200_when_database_is_up(monkeypatch):
    monkeypatch.setattr(main, "engine", working_engine())
    response = client.get("/.well-known/ready")
    assert response.status_code == 200
    assert response.json()["status"] == "ready"


def test_ready_returns_503_when_database_is_down(monkeypatch):
    """The reason this endpoint exists: the failure must be in the status code."""
    monkeypatch.setattr(main, "engine", UnreachableEngine())
    response = client.get("/.well-known/ready")
    assert response.status_code == 503
    assert response.json()["status"] == "not-ready"
