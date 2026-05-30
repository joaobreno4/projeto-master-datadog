import os
import json
import logging
import time
from contextlib import asynccontextmanager
from datetime import datetime

import redis as redis_lib
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy import Column, DateTime, Float, Integer, String, create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

# ── OpenTelemetry — Imports ────────────────────────────────────────────────────
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.trace import Status, StatusCode
from opentelemetry.metrics import Observation
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor

# ── OTel Resource (Unified Service Tagging) ────────────────────────────────────
#
# O Resource é o equivalente OTel ao Unified Service Tagging do Datadog.
# O Agent mapeia automaticamente:
#   "service.name"           → tag service:<value>
#   "deployment.environment" → tag env:<value>
#   "service.version"        → tag version:<value>
#
# Todos os spans e métricas herdam esses atributos automaticamente,
# sem precisar repeti-los em cada chamada individual.
_resource = Resource.create({
    "service.name":           os.getenv("DD_SERVICE", "store-api"),
    "deployment.environment": os.getenv("DD_ENV", "sandbox"),
    "service.version":        os.getenv("DD_VERSION", "1.0.0"),
})

# Endpoint gRPC do Datadog Agent — formato "host:porta" sem esquema http://
# O OTLP gRPC usa esta convenção; HTTP usaria "http://host:4318".
_agent_host    = os.getenv("DD_AGENT_HOST", "localhost")
_otlp_endpoint = f"{_agent_host}:4317"

# ── TracerProvider ─────────────────────────────────────────────────────────────
#
# BatchSpanProcessor: acumula spans em memória e os envia em lotes para o
# OTLPSpanExporter. Diferente de SimpleSpanProcessor (síncrono por request),
# o batch não adiciona latência ao path da requisição.
#
# insecure=True: conexão gRPC sem TLS — apropriado para rede interna Docker.
# Em produção com Agent externo, usar credentials=grpc.ssl_channel_credentials().
_tracer_provider = TracerProvider(resource=_resource)
_tracer_provider.add_span_processor(
    BatchSpanProcessor(
        OTLPSpanExporter(endpoint=_otlp_endpoint, insecure=True)
    )
)
trace.set_tracer_provider(_tracer_provider)
tracer = trace.get_tracer(__name__)

# ── MeterProvider ──────────────────────────────────────────────────────────────
#
# PeriodicExportingMetricReader: coleta os valores acumulados dos instrumentos
# a cada 10 segundos e envia via OTLPMetricExporter. O Datadog Agent converte
# OTel Counters → Datadog count, Histograms → distribution, Gauges → gauge.
_meter_provider = MeterProvider(
    resource=_resource,
    metric_readers=[
        PeriodicExportingMetricReader(
            OTLPMetricExporter(endpoint=_otlp_endpoint, insecure=True),
            export_interval_millis=10_000,
        )
    ],
)
metrics.set_meter_provider(_meter_provider)
_meter = metrics.get_meter(__name__)

# ── Redis instrumentation ──────────────────────────────────────────────────────
#
# DEVE ser chamado ANTES de criar qualquer instância redis.client.Redis.
# O instrumentador patcha execute_command() globalmente na lib redis-py.
# Se chamado depois do from_url(), os clientes já criados não serão cobertos.
RedisInstrumentor().instrument(tracer_provider=_tracer_provider)

# ── Logging estruturado (JSON) com correlação OTel → Datadog ──────────────────
_LOG_RECORD_SKIP = frozenset({
    "name", "msg", "args", "levelname", "levelno", "pathname", "filename",
    "module", "exc_info", "exc_text", "stack_info", "lineno", "funcName",
    "created", "msecs", "relativeCreated", "thread", "threadName",
    "processName", "process", "message", "taskName",
})

class _JSONFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry: dict = {
            "timestamp":   datetime.utcnow().isoformat() + "Z",
            "status":      record.levelname.lower(),
            "message":     record.getMessage(),
            "logger.name": record.name,
            "service":     os.getenv("DD_SERVICE", "store-api"),
            "env":         os.getenv("DD_ENV", "sandbox"),
            "version":     os.getenv("DD_VERSION", "1.0.0"),
        }

        # ── OTel → Datadog log correlation ────────────────────────────────────
        #
        # OTel usa trace_id de 128 bits (inteiro). O Datadog backend trabalha com
        # trace IDs de 64 bits. A convenção é usar os 64 bits INFERIORES (metade
        # direita do inteiro 128-bit), obtidos com "& 0xFFFF...FFFF" (16 Fs).
        #
        # OTel span_id já é 64 bits — converte direto para decimal.
        #
        # Com dd.trace_id e dd.span_id corretos nos logs, o Datadog habilita o
        # botão "Go to Trace" na Log Explorer, fazendo a correlação log ↔ trace.
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            entry["dd.trace_id"] = str(ctx.trace_id & 0xFFFFFFFFFFFFFFFF)
            entry["dd.span_id"]  = str(ctx.span_id)
        else:
            entry["dd.trace_id"] = "0"
            entry["dd.span_id"]  = "0"

        for key, val in record.__dict__.items():
            if key not in _LOG_RECORD_SKIP and not key.startswith("_"):
                entry[key] = val
        if record.exc_info:
            entry["error.stack"] = self.formatException(record.exc_info)
        return json.dumps(entry)

_handler = logging.StreamHandler()
_handler.setFormatter(_JSONFormatter())
logger = logging.getLogger("store-api")
logger.setLevel(logging.INFO)
logger.addHandler(_handler)
logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)

# ── Database ───────────────────────────────────────────────────────────────────
DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/storedb"
)
engine = create_engine(DATABASE_URL, pool_pre_ping=True)

# SQLAlchemyInstrumentor deve ser chamado imediatamente após criar o engine.
# Ele instala um event listener no engine que cria spans para cada operação SQL.
SQLAlchemyInstrumentor().instrument(engine=engine, tracer_provider=_tracer_provider)


class Base(DeclarativeBase):
    pass


class Order(Base):
    __tablename__ = "orders"
    id         = Column(Integer, primary_key=True, index=True)
    product    = Column(String, nullable=False)
    quantity   = Column(Integer, nullable=False)
    price      = Column(Float, nullable=False)
    status     = Column(String, default="pending")
    created_at = Column(DateTime, default=datetime.utcnow)


SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# ── Redis (com resiliência) ────────────────────────────────────────────────────
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
try:
    _redis = redis_lib.from_url(REDIS_URL, decode_responses=True, socket_connect_timeout=2)
    _redis.ping()
    logger.info("Redis connected")
except Exception as exc:
    logger.warning(f"Redis unavailable at startup — cache disabled: {exc}")
    _redis = None


def cache_get(key: str) -> str | None:
    if _redis is None:
        return None
    try:
        return _redis.get(key)
    except Exception:
        return None


def cache_set(key: str, value: str, ex: int = 30) -> None:
    if _redis is None:
        return
    try:
        _redis.setex(key, ex, value)
    except Exception:
        pass


def cache_delete(*keys: str) -> None:
    if _redis is None:
        return
    try:
        _redis.delete(*keys)
    except Exception:
        pass


# ── OTel Metric Instruments ────────────────────────────────────────────────────
#
# Nomes IDÊNTICOS ao DogStatsD anterior para não quebrar as queries do Dashboard
# e dos Monitores do Terraform. O Datadog Agent converte os tipos OTel assim:
#
#   OTel Counter          → Datadog count  (monotônico, visto como rate no UI)
#   OTel Histogram        → Datadog distribution (suporta p50/p95/p99 nativo)
#   OTel ObservableGauge  → Datadog gauge  (snapshot do estado atual)
#
# Mapeamento de tipos DogStatsD → OTel:
#   statsd.increment  → Counter        (eventos discretos, só sobe)
#   statsd.gauge      → ObservableGauge (via callback, lido no intervalo de export)
#   statsd.histogram  → Histogram       (distribuição de latências)

_ctr_orders_created   = _meter.create_counter("store.orders.created",   description="Pedidos criados")
_ctr_orders_processed = _meter.create_counter("store.orders.processed", description="Pedidos processados")
_ctr_orders_deleted   = _meter.create_counter("store.orders.deleted",   description="Pedidos deletados")
_ctr_cache_requests   = _meter.create_counter("store.cache.requests",   description="Cache hits e misses")
_ctr_http_errors      = _meter.create_counter("store.http.errors",      description="Erros HTTP por status e path")

_hist_processing_ms = _meter.create_histogram(
    "store.order.processing_ms",
    description="Latência de processamento de pedidos",
    unit="ms",
)

# ObservableGauge — modelo pull: o SDK chama o callback no intervalo de export.
#
# Por que lista e não int?
#   Python não permite reatribuir variáveis de escopo externo sem "global".
#   Usar uma lista de um elemento é o idioma padrão para estado mutável
#   compartilhado entre funções sem declaração global.
#
# Thread safety: FastAPI/uvicorn corre em single-process asyncio. A mutação
# de lista[0] é atômica no CPython (GIL), então não há race condition.
_pending_orders_current: list[int] = [0]


def _pending_orders_callback(options):
    yield Observation(_pending_orders_current[0])


_meter.create_observable_gauge(
    "store.pending_orders",
    callbacks=[_pending_orders_callback],
    description="Snapshot da fila de pedidos pendentes",
)


def _m(fn, *args, **kwargs) -> None:
    """Emite métrica silenciosamente — OTel nunca quebra a app."""
    try:
        fn(*args, **kwargs)
    except Exception:
        pass


def _pending_count(db: Session) -> int:
    """Snapshot da fila: pedidos ainda não processados. Alimenta o ObservableGauge."""
    return db.query(Order).filter(Order.status == "pending").count()


# ── App lifecycle ──────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    Base.metadata.create_all(bind=engine)
    logger.info("Database tables ready")
    yield
    logger.info("Application shutdown")
    # Flush de spans e métricas pendentes antes de sair.
    # Sem isso, o BatchSpanProcessor pode perder os últimos spans do processo.
    _tracer_provider.shutdown()
    _meter_provider.shutdown()


app = FastAPI(
    title="Store API",
    version=os.getenv("DD_VERSION", "1.0.0"),
    lifespan=lifespan,
)

# FastAPIInstrumentor injeta middleware ASGI que cria um span por request,
# propagando o W3C Trace Context (traceparent header) para serviços downstream.
# Deve ser chamado após app = FastAPI(...) e antes do servidor iniciar.
FastAPIInstrumentor().instrument_app(app, tracer_provider=_tracer_provider)


# ── Global error handler ───────────────────────────────────────────────────────
@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    span = trace.get_current_span()
    span.set_status(Status(StatusCode.ERROR, exc.detail))
    span.set_attribute("http.status_code", exc.status_code)
    span.set_attribute("error.message", exc.detail)

    _m(_ctr_http_errors.add, 1, {
        "status_code": str(exc.status_code),
        "path":        request.url.path,
    })

    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})


# ── Schemas ────────────────────────────────────────────────────────────────────
class OrderCreate(BaseModel):
    product:  str
    quantity: int
    price:    float


class OrderOut(BaseModel):
    id:       int
    product:  str
    quantity: int
    price:    float
    status:   str

    model_config = {"from_attributes": True}


# ── Routes ─────────────────────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {
        "status":  "ok",
        "service": os.getenv("DD_SERVICE"),
        "version": os.getenv("DD_VERSION"),
        "env":     os.getenv("DD_ENV"),
    }


@app.post("/orders", response_model=OrderOut, status_code=201)
def create_order(payload: OrderCreate, db: Session = Depends(get_db)):
    price_tier = "premium" if payload.price > 500 else "standard"

    # tracer.start_as_current_span() cria um span filho do span do FastAPI
    # (que por sua vez pode ser filho de um span de serviço upstream via
    # W3C traceparent header). O "with" garante que o span é encerrado ao sair.
    with tracer.start_as_current_span("order.validate_and_persist") as span:
        span.set_attribute("order.product",    payload.product)
        span.set_attribute("order.quantity",   payload.quantity)
        span.set_attribute("order.price_tier", price_tier)

        order = Order(**payload.model_dump())
        db.add(order)
        db.commit()
        db.refresh(order)
        span.set_attribute("order.id", order.id)

    cache_delete("orders:all")

    _m(_ctr_orders_created.add, 1, {"price_tier": price_tier})
    _pending_orders_current[0] = _pending_count(db)

    logger.info(f"Order created: id={order.id} product={payload.product} qty={payload.quantity}")
    return order


@app.get("/orders", response_model=list[OrderOut])
def list_orders(db: Session = Depends(get_db)):
    cached = cache_get("orders:all")
    if cached:
        span = trace.get_current_span()
        span.set_attribute("cache.hit", True)
        _m(_ctr_cache_requests.add, 1, {"result": "hit", "key_type": "list"})
        logger.info("Cache HIT: orders:all")
        return json.loads(cached)

    orders = db.query(Order).all()
    result = [OrderOut.model_validate(o).model_dump() for o in orders]
    cache_set("orders:all", json.dumps(result), ex=30)

    span = trace.get_current_span()
    span.set_attribute("cache.hit",        False)
    span.set_attribute("db.rows_returned", len(result))

    _m(_ctr_cache_requests.add, 1, {"result": "miss", "key_type": "list"})
    logger.info(f"Cache MISS: orders:all — {len(result)} rows loaded from DB")
    return orders


@app.get("/orders/{order_id}", response_model=OrderOut)
def get_order(order_id: int, db: Session = Depends(get_db)):
    key = f"orders:{order_id}"
    cached = cache_get(key)
    if cached:
        span = trace.get_current_span()
        span.set_attribute("cache.hit", True)
        _m(_ctr_cache_requests.add, 1, {"result": "hit", "key_type": "single"})
        logger.info(f"Cache HIT: {key}")
        return json.loads(cached)

    order = db.query(Order).filter(Order.id == order_id).first()
    if not order:
        logger.warning(f"Order not found: id={order_id}")
        raise HTTPException(status_code=404, detail="Order not found")

    cache_set(key, OrderOut.model_validate(order).model_dump_json(), ex=60)
    _m(_ctr_cache_requests.add, 1, {"result": "miss", "key_type": "single"})
    logger.info(f"Cache MISS: {key}")
    return order


@app.post("/orders/{order_id}/process", response_model=OrderOut)
def process_order(order_id: int, db: Session = Depends(get_db)):
    with tracer.start_as_current_span("order.process") as span:
        span.set_attribute("order.id", order_id)

        t0 = time.perf_counter()
        time.sleep(0.15)  # latência intencional — visível no Flame Graph

        order = db.query(Order).filter(Order.id == order_id).first()
        if not order:
            span.set_status(Status(StatusCode.ERROR, "Order not found"))
            raise HTTPException(status_code=404, detail="Order not found")

        order.status = "processed"
        db.commit()
        db.refresh(order)

        elapsed_ms = (time.perf_counter() - t0) * 1000
        span.set_attribute("order.product",         order.product)
        span.set_attribute("order.previous_status", "pending")
        span.set_attribute("order.new_status",      "processed")
        span.set_attribute("order.processing_ms",   round(elapsed_ms, 2))

    cache_delete(f"orders:{order_id}", "orders:all")

    _m(_hist_processing_ms.record, elapsed_ms)
    _m(_ctr_orders_processed.add, 1)
    _pending_orders_current[0] = _pending_count(db)

    logger.info(f"Order processed: id={order_id}")
    return order


@app.delete("/orders/{order_id}", status_code=204)
def delete_order(order_id: int, db: Session = Depends(get_db)):
    order = db.query(Order).filter(Order.id == order_id).first()
    if not order:
        raise HTTPException(status_code=404, detail="Order not found")
    db.delete(order)
    db.commit()
    cache_delete(f"orders:{order_id}", "orders:all")

    _m(_ctr_orders_deleted.add, 1)
    _pending_orders_current[0] = _pending_count(db)

    logger.info(f"Order deleted: id={order_id}")


@app.get("/error-test")
def error_test():
    # record_exception() captura o stack trace e o anexa ao span como evento.
    # set_status(ERROR) marca o span como falha no Datadog APM (vermelho no Flame Graph).
    with tracer.start_as_current_span("error.simulation") as span:
        try:
            raise ValueError("Simulated error — OTel error tracking test")
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(Status(StatusCode.ERROR, str(exc)))
            raise HTTPException(status_code=500, detail="Simulated internal error")
