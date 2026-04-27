FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn prometheus_client aioboto3

COPY app.py .

RUN adduser --disabled-password --gecos '' appuser && chown -R appuser /app

USER appuser

EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
