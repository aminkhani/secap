# Stage 1 — builder: install production deps
FROM python:3.13-slim AS builder

RUN pip install uv

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_CACHE_DIR=/root/.cache/uv

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    gcc \
    libopenscap33 \
    openscap-common \
    openscap-scanner \
    openscap-utils \
    sshpass \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pyproject.toml uv.lock ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project

# ==============================================================
# Stage 2 — development
# ==============================================================
FROM python:3.13-slim AS development

RUN pip install uv

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    UV_CACHE_DIR=/root/.cache/uv \
    PATH="/app/.venv/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    gettext \
    libopenscap33 \
    openscap-common \
    openscap-scanner \
    openscap-utils \
    sshpass \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pyproject.toml uv.lock ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project

COPY src/ ./src/

WORKDIR /app/src

EXPOSE 8000
CMD ["python", "manage.py", "runserver", "0.0.0.0:8000"]

# ==============================================================
# Stage 3 — production
# ==============================================================
FROM python:3.13-slim AS production

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    PATH="/app/.venv/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    gettext \
    libopenscap33 \
    openscap-common \
    openscap-scanner \
    openscap-utils \
    sshpass \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/.venv /app/.venv

COPY src/ ./src/
COPY pyproject.toml ./

WORKDIR /app/src

ARG DJANGO_SETTINGS_MODULE=secapserver.settings.prod
ENV DJANGO_SETTINGS_MODULE=${DJANGO_SETTINGS_MODULE}

EXPOSE 8000

# RUN python manage.py migrate --noinput
# RUN python manage.py compilemessages
# RUN python manage.py collectstatic --noinput


CMD ["gunicorn", "secapserver.wsgi:application", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "4", \
     "--threads", "4", \
     "--timeout", "120", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "--log-level", "info"]