# ---- build stage: install deps into a venv ----
FROM python:3.12-slim AS build
WORKDIR /app
RUN python -m venv /venv
ENV PATH="/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- runtime stage: small, non-root ----
FROM python:3.12-slim
ENV PATH="/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src
RUN useradd --uid 10001 --no-create-home appuser
WORKDIR /app
COPY --from=build /venv /venv
COPY src ./src
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:8000/healthz'); sys.exit(0)"
CMD ["uvicorn", "cloudpulse.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
