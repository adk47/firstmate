FROM python:3.12-slim

WORKDIR /app

# System deps for torch CPU
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

# Non-root user
RUN useradd -m -r promptguard
USER promptguard

EXPOSE 18793

HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:18793/health || exit 1

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "18793", "--workers", "1"]
