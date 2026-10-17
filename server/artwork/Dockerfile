FROM python:3.13-slim
ARG SOURCE_COMMIT=development
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home aux && mkdir /data && chown aux:aux /data
COPY app.py .
USER aux
ENV DATA_DIR=/data PYTHONUNBUFFERED=1 SOURCE_COMMIT=$SOURCE_COMMIT
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3)"
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", "--timeout", "30", "--worker-tmp-dir", "/tmp", "--error-logfile", "-", "app:create_app()"]
