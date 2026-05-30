FROM python:3.12-slim

WORKDIR /app

# gcc + libpq-dev: compilar psycopg2 em imagens slim.
# grpcio vem com wheel pré-compilada para Python 3.12 / Linux x86_64 — sem custo extra.
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8000

# Sem ddtrace-run: a instrumentação OTel é feita programaticamente em main.py
# (TracerProvider, MeterProvider, FastAPIInstrumentor, etc.) antes do lifespan.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
