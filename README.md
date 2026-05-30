# Datadog Labs — Observabilidade com OpenTelemetry

Stack local de observabilidade de ponta a ponta usando **OpenTelemetry SDK**, **OTel Collector**, **Datadog Agent** e **Terraform**, rodando sobre Docker Compose.

## Arquitetura

```
┌──────────────────────────────────────────────────────────────────┐
│  Docker Compose (projeto-master-datadog_default)                 │
│                                                                  │
│  ┌─────────────┐   OTLP gRPC   ┌────────────────┐               │
│  │  store-api  │ ────:4317───► │ otel-collector │ ──► Datadog   │
│  │  FastAPI    │               │  contrib:latest│     APM + Metrics
│  │  OTel SDK   │               └────────────────┘               │
│  └──────┬──────┘                                                 │
│         │  stdout JSON                                           │
│         ▼  (logs)              ┌────────────────┐               │
│  ┌─────────────┐               │ datadog-agent  │ ──► Datadog   │
│  │  container  │ ────────────► │    Agent 7     │     Logs + Infra
│  │   runtime   │               └────────────────┘               │
│  └─────────────┘                                                 │
│                                                                  │
│  ┌──────────────┐   ┌─────────────┐                             │
│  │  PostgreSQL  │   │    Redis    │                             │
│  │  (orders DB) │   │   (cache)   │                             │
│  └──────────────┘   └─────────────┘                             │
└──────────────────────────────────────────────────────────────────┘
                              │
                 ┌────────────▼───────────┐
                 │  Datadog (us5)         │
                 │  APM · Metrics · Logs  │
                 │  Monitors · Dashboard  │
                 └────────────────────────┘
```

**Por que dois coletores?**

| Componente | Responsabilidade |
|------------|-----------------|
| `otel-collector` | Recebe traces e métricas da app via OTLP gRPC; exporta para a Datadog API diretamente |
| `datadog-agent` | Coleta logs de todos os containers (`container_collect_all`) e métricas de infra (CPU, memória, Docker) |

O Agent 7 embutido tem um bug no pipeline OTLP em Docker/WSL que impede o gRPC de subir. O `otel-collector-contrib` com `service.telemetry.metrics.level: none` contorna o problema.

## Stack

| Componente | Versão |
|------------|--------|
| FastAPI | >=0.115.0 |
| OpenTelemetry SDK | 1.42.1 |
| opentelemetry-exporter-otlp-proto-grpc | 1.42.1 |
| opentelemetry-instrumentation-fastapi/sqlalchemy/redis | 0.63b1 |
| otel/opentelemetry-collector-contrib | latest (v0.153.0+) |
| datadog/agent | 7 |
| PostgreSQL | 15-alpine |
| Redis | 7-alpine |
| Terraform Datadog provider | ~> 3.0 |

## Pré-requisitos

- Docker + Docker Compose v2
- Terraform >= 1.0
- Conta Datadog com API Key e App Key (site US5)

## Setup

**1. Configurar credenciais**

```bash
cp .env.example .env   # edite com suas chaves reais
```

Conteúdo do `.env`:

```env
DD_API_KEY=<sua_api_key>
DD_SITE=us5.datadoghq.com
DD_ENV=sandbox
DD_SERVICE=store-api
DD_VERSION=1.0.0

POSTGRES_DB=storedb
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
```

**2. Subir a stack**

```bash
docker compose up -d --build
```

**3. Verificar saúde**

```bash
docker compose ps
curl http://localhost:8000/health
```

**4. Provisionar recursos Datadog via Terraform**

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edite com suas api_key e app_key

cd terraform
terraform init
terraform apply
```

Recursos criados:
- 1 Dashboard (APM + métricas de negócio)
- 4 Monitors (error rate, latência p95, fila de pedidos, anomalia de latência)
- 2 SLOs (requer permissão `slos_write` na App Key)

## Estrutura do Projeto

```
.
├── app/
│   ├── main.py                  # FastAPI + OTel SDK (traces, métricas, logs)
│   ├── requirements.txt
│   └── Dockerfile
├── terraform/
│   ├── main.tf                  # Variáveis de ambiente e locals
│   ├── provider.tf              # Datadog provider
│   ├── dashboard_store.tf       # Dashboard com APM e métricas de negócio
│   ├── monitors_apm.tf          # 4 monitores de alerta
│   ├── slo_store.tf             # 2 SLOs (availability + latency)
│   ├── variables.tf
│   └── terraform.tfvars.example # Template de credenciais (sem valores reais)
├── .github/
│   └── workflows/
│       └── devsecops.yml        # Pipeline CI: secret scan, dep scan, container scan, IaC scan
├── .pre-commit-config.yaml      # Hooks locais: detect-secrets + gitleaks + formatação
├── .gitleaks.toml               # Allowlist para .secrets.baseline e arquivos *.example
├── .secrets.baseline            # Baseline de falsos positivos auditados (detect-secrets)
├── .env.example                 # Template de variáveis de ambiente (sem valores reais)
├── docker-compose.yml
├── otelcol-config.yaml          # Pipeline OTLP → Datadog exporter
└── simulate_chaos.sh            # Script de testes de caos
```

## API Endpoints

| Método | Path | Descrição |
|--------|------|-----------|
| `GET` | `/health` | Health check com UST tags |
| `POST` | `/orders` | Cria pedido (span customizado + métricas) |
| `GET` | `/orders` | Lista pedidos (cache Redis com span de hit/miss) |
| `GET` | `/orders/{id}` | Busca pedido por ID |
| `POST` | `/orders/{id}/process` | Processa pedido (latência intencional de 150ms) |
| `DELETE` | `/orders/{id}` | Remove pedido |
| `GET` | `/error-test` | Gera erro 500 com span ERROR para testar monitores |

## Instrumentação OTel

### Traces

- **FastAPIInstrumentor**: span por request HTTP (automático)
- **SQLAlchemyInstrumentor**: sub-span por query SQL (automático)
- **RedisInstrumentor**: sub-span por operação Redis (automático)
- `order.validate_and_persist`: span customizado com atributos de negócio
- `order.process`: span com latência de processamento e status de transição

### Métricas

| Instrumento OTel | Nome | Tipo Datadog |
|------------------|------|-------------|
| Counter | `store.orders.created` | count |
| Counter | `store.orders.processed` | count |
| Counter | `store.orders.deleted` | count |
| Counter | `store.cache.requests` | count |
| Counter | `store.http.errors` | count |
| Histogram | `store.order.processing_ms` | distribution (p50/p95/p99) |
| ObservableGauge | `store.pending_orders` | gauge |

### Logs com Correlação

Logs em JSON estruturado com campos `dd.trace_id` e `dd.span_id` para correlação automática no Log Explorer do Datadog:

```json
{
  "timestamp": "2026-05-30T00:12:15Z",
  "status": "info",
  "message": "Order created: id=163",
  "service": "store-api",
  "env": "sandbox",
  "dd.trace_id": "1187633433760038480",
  "dd.span_id": "13296920929620538286"
}
```

## Simulação de Caos

```bash
chmod +x simulate_chaos.sh

# Dispara 60 pedidos pendentes (~12 req/s) → aciona monitor de fila
./simulate_chaos.sh pending

# Taxa de erro ~91% por 200 requests → aciona monitor de error rate
./simulate_chaos.sh errors

# Processa todos os pedidos pendentes
./simulate_chaos.sh cleanup

# Executa pending + errors em sequência
./simulate_chaos.sh all
```

## Verificação no Datadog

Após subir a stack e gerar tráfego:

- **APM > Traces** → serviço `store-api`, env `sandbox`
- **APM > Service Map** → dependências para PostgreSQL e Redis
- **Metrics Explorer** → buscar `store.orders.*` ou `store.pending_orders`
- **Dashboards** → "Store API — Observabilidade" (provisionado pelo Terraform)
- **Monitors** → 4 monitores ativos para error rate, latência, fila e anomalia
- **Log Explorer** → logs JSON com botão "Go to Trace" habilitado pela correlação

## DevSecOps

O projeto inclui um pipeline de segurança em duas camadas: **hooks locais** (antes do commit) e **GitHub Actions** (a cada push/PR).

### Pre-commit hooks

Instalação local:

```bash
pip install pre-commit
pre-commit install
```

A partir daí, cada `git commit` executa automaticamente:

| Hook | Ferramenta | O que verifica |
|------|-----------|----------------|
| `trailing-whitespace` | pre-commit-hooks | Formatação |
| `check-yaml` | pre-commit-hooks | Valida docker-compose e otelcol-config |
| `detect-secrets` | Yelp detect-secrets v1.5.0 | Tokens, chaves e senhas por entropia e padrão |
| `gitleaks` | gitleaks v8.27.2 | Regex de 100+ provedores (AWS, GCP, Datadog…) |

Falsos positivos são gerenciados em `.secrets.baseline` (auditados com `is_secret: false`) e `.gitleaks.toml` (allowlist de arquivos `*.example` e o próprio baseline).

### GitHub Actions

Pipeline em 4 jobs paralelos (`.github/workflows/devsecops.yml`):

```
push/PR → main
    │
    ├─ secret-scan        gitleaks no histórico completo (fetch-depth: 0)
    │                     Falha o pipeline antes de qualquer build
    │
    ├─ dependency-scan    pip-audit contra OSV + PyPI Advisory Database
    │                     Gera pip-audit-report.json como artefato
    │
    ├─ container-scan     trivy na imagem Docker (CRITICAL/HIGH com fix → falha)
    │                     SARIF enviado para Security → Code Scanning do GitHub
    │
    └─ iac-scan           trivy config no diretório terraform/
                          Informativo — não bloqueia o pipeline
```

**Status atual:** ✅ 4/4 jobs passando

### Decisões de segurança tomadas durante o projeto

| CVE encontrado | Causa raiz | Correção aplicada |
|----------------|-----------|-------------------|
| CVE-2024-47874, CVE-2025-54121, PYSEC-2026-161 | `starlette 0.37.2` via `fastapi==0.111.0` | Atualizado para `fastapi>=0.115.0` → starlette 1.2.0 |
| CVE-2026-23949 (HIGH) em `setuptools/_vendor/jaraco.context` | Pin `setuptools<80.0.0` necessário para `opentelemetry-instrumentation 0.46b0` que usava `pkg_resources` | Migrado OTel instrumentation para `0.63b1` (usa `importlib.metadata`) → pin removido |
| CVEs em `pip 25.0.1` (imagem base) | `python:3.12-slim` vem com pip desatualizado | `pip install --upgrade pip` adicionado ao Dockerfile e ao step de CI |

## Problemas Conhecidos

**SLO 403 Forbidden**: O Terraform tenta criar 2 SLOs mas falha se a App Key não tiver a permissão `slos_write`. Para resolver: acesse _Organization Settings → Application Keys_, edite a chave e adicione o escopo `slos_write`, depois execute:

```bash
cd terraform
terraform apply -target=datadog_service_level_objective.availability \
                -target=datadog_service_level_objective.latency
```
