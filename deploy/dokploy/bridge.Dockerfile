# Bridge NERUDS (FastAPI) — produção no Dokploy.
# DATA_DIR resolve para /srv/data (BASE_DIR.parent / "data"): monte um volume
# nomeado ali para persistir sessões, missões, identidade e app_config.json.

FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN pip install --no-cache-dir uv

WORKDIR /srv
COPY bridge/ /srv/bridge/

WORKDIR /srv/bridge
RUN uv sync --frozen --no-dev

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["uv", "run", "--no-sync", "python", "-c", \
       "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8787/health', timeout=4).status == 200 else 1)"]

CMD ["uv", "run", "--no-sync", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8787"]
