# Backend API + WebSocket — self-contained, build from this folder:
#   docker build -t chat-backend .
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    STORAGE_DIR=/data/storage

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN mkdir -p /data/storage/uploads /data/storage/avatars /data/storage/wallpapers /app/certs \
 && useradd --create-home --uid 1000 app \
 && chown -R app:app /app /data
USER app

# 4000 = HTTP; 4443 = HTTPS, only when certs are mounted at /app/certs
EXPOSE 4000 4443

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:4000/api/health', timeout=4).status == 200 else 1)"

CMD ["python", "run.py"]
