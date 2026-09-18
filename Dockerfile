# syntax=docker/dockerfile:1
#
# Multi-stage build. The builder stage compiles dependencies into a virtualenv;
# the runtime stage copies only that venv, so build tooling never ships to
# production. Keeps the final image small and reduces its attack surface.

# ---------- builder ----------
FROM python:3.12-slim AS builder

# Never write .pyc files or buffer stdout: pyc files bloat the layer, and
# buffered stdout means container logs appear late or not at all.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Copy only requirements first. Docker caches layers, so dependencies are
# reinstalled only when requirements.txt changes -- not on every code edit.
COPY requirements.txt .

RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install -r requirements.txt

# ---------- runtime ----------
FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Run as an unprivileged user. If the process is compromised it has no root in
# the container, which is the single cheapest container hardening step there is.
RUN groupadd --system --gid 1001 appuser \
 && useradd --system --uid 1001 --gid appuser --create-home appuser

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv

# swagger.json is read from the project root at runtime by the
# /.well-known/swagger endpoint, so it has to be in the image.
COPY --chown=appuser:appuser app/ ./app/
COPY --chown=appuser:appuser swagger.json ./swagger.json

USER appuser

EXPOSE 8000

# python:*-slim has no curl, so probe with the stdlib. Kubernetes uses its own
# probes (see k8s/deployment.yaml) and ignores this, but it makes `docker run`
# and docker-compose report health correctly.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://127.0.0.1:8000/.well-known/health', timeout=2).status == 200 else sys.exit(1)"]

# No --reload: that is a development convenience and would watch the filesystem
# in production. One worker per container; scale with replicas, not workers, so
# the orchestrator controls capacity and each process stays independently
# restartable.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
