# PromptGuard 2 22M sidecar — CPU-only image for the Caroline safety layer's classifier slot.
#
# The model is BAKED INTO THE IMAGE (fetch-model.sh, sha256-pinned by model.sha256). That is the
# whole point of this file: the request path must never touch the network, and a model swap must
# fail the build instead of silently changing verdicts. It also means the image carries no HF token
# and needs no credential at runtime — Meta's canonical repo is gated (401 anonymously) and there is
# no HF_TOKEN on node-8, so the pinned non-gated mirror in model.sha256's header is the source.
#
# Build (from the repo root, so the context is just this directory):
#   docker build -t hydra-promptguard:<sha> promptguard/
#
# Run: see scripts/install-aux-units.sh — a systemd unit wraps `docker run` with
#   --publish 127.0.0.1:18793:18793  (loopback only; never 0.0.0.0)
#   --cpus 1 --memory 1g             (cannot starve the gateway sharing this host)
#   --restart unless-stopped         (systemd also restarts it)
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PROMPTGUARD_MODEL_DIR=/app/model \
    PROMPTGUARD_THREADS=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# curl for the model fetch + the container HEALTHCHECK below. ca-certificates for the HF fetch.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# torch FIRST and from the CPU wheel index: the default PyPI wheel pulls ~2.5 GB of CUDA libraries
# this image can never use. Separate layer so a server.py edit does not re-download torch.
COPY requirements-torch.txt .
RUN pip install -r requirements-torch.txt --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install -r requirements.txt

# Model layer: pin file + fetcher, verified at build. A checksum mismatch fails the build.
COPY model.sha256 fetch-model.sh ./
RUN chmod +x fetch-model.sh && ./fetch-model.sh /app/model

COPY server.py .

# Non-root, and the model directory must be readable by it (the COPY above lands as root).
RUN useradd -m -r promptguard \
    && chown -R promptguard:promptguard /app/model
USER promptguard

# 18793 is published to the host's loopback only by the systemd unit. Binding 0.0.0.0 INSIDE the
# container is required for docker's published-port proxy to reach it; the host side stays 127.0.0.1.
EXPOSE 18793

# start-period is generous on purpose: torch + transformers import and the first model load cost a
# few seconds on a cold container. The unit's own readiness wait uses this same endpoint.
HEALTHCHECK --interval=60s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS http://127.0.0.1:18793/health || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "18793", "--workers", "1"]
