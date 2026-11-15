FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VENV_PATH=/opt/venv

RUN python -m venv ${VENV_PATH}
ENV PATH="${VENV_PATH}/bin:${PATH}"

WORKDIR /app

FROM base AS dev
COPY agent-sidecar/pyproject.toml /app/agent-sidecar/pyproject.toml
COPY agent-sidecar/src /app/agent-sidecar/src
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -e "/app/agent-sidecar[dev]"

COPY agent-sidecar/tests /app/agent-sidecar/tests
CMD ["python", "-m", "sidecar.server"]

FROM base AS prod
COPY agent-sidecar/pyproject.toml /app/agent-sidecar/pyproject.toml
COPY agent-sidecar/src /app/agent-sidecar/src
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir /app/agent-sidecar

CMD ["python", "-m", "sidecar.server"]
