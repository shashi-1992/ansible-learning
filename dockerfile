# =============================================================================
# Exomind Tasker API — Production Dockerfile
#
# Single image, 4 services via CMD override:
#   API:        uvicorn main:app --workers 4 --host 0.0.0.0 --port 8000
#   Worker-v1:  celery -A summarization_worker.celery worker -Q summarization ...
#   Worker-v2:  celery -A summarization_worker_v2.celery worker -Q verb ...
#   KPI Worker: celery -A kpi_generation_worker.celery worker -Q kpi_generation ...
# =============================================================================
# =============================================================================
# Stage 1: BASE — OS-level runtime dependencies
# =============================================================================
FROM python:3.11.13-slim-bookworm AS base
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        libpq5 \
        curl && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
# =============================================================================
# Stage 2: DEPENDENCIES — pip install with build tools (discarded after)
# =============================================================================
FROM base AS dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        gcc && \
    rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
# =============================================================================
# Stage 3: BUILDER — copy source code, download data, validate
# =============================================================================
FROM base AS builder
COPY --from=dependencies /install /usr/local
COPY . .
RUN python -c "import nltk; nltk.download('punkt_tab', download_dir='/app/nltk_data')" && \
    python -c "from config import get_config; print('Config import OK')" && \
    python -c "from contract import JobRequest; print('Contract import OK')"
# =============================================================================
# Stage 4: RUNNER — final minimal production image
# =============================================================================
FROM base AS runner
RUN groupadd --gid 1001 tasker && \
    useradd --uid 1001 --gid tasker --shell /bin/false --create-home tasker && \
    mkdir -p /tmp/tasker
COPY --from=dependencies /install /usr/local
COPY --from=builder /app /app
COPY --from=builder /app/nltk_data /app/nltk_data
RUN chown -R tasker:tasker /app /tmp/tasker
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV NLTK_DATA=/app/nltk_data
ENV HOME=/home/tasker
USER tasker
WORKDIR /app
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8000/ping || exit 1
CMD ["uvicorn", "main:app", "--workers", "4", "--host", "0.0.0.0", "--port", "8000", "--access-log"]
