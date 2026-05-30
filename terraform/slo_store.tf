# SLOs (Service Level Objectives) do store-api
#
# METRIC-BASED SLO vs MONITOR-BASED SLO:
#
#   METRIC-BASED:
#     Calcula SLI = good_events / total_events diretamente nas métricas.
#     Mais preciso — granularidade de 1 minuto, sem delay de estado do monitor.
#     Ideal para: disponibilidade (sucesso/total), throughput.
#
#   MONITOR-BASED:
#     Mede o % de tempo em que um monitor está em estado OK.
#     Mais simples de configurar quando o monitor já existe.
#     Desvantagem: granularidade de 1 minuto e depende do estado do monitor.
#     Ideal para: latência (onde o threshold já está definido no monitor).

# ── SLO 1: Disponibilidade — Metric-based ──────────────────────────────────────
#
# SLI: (requests bem-sucedidas) / (total de requests)
# SLO: manter SLI >= 99.0% em qualquer janela de 7 dias
#
# ERROR BUDGET:
#   7 dias = 10.080 minutos
#   1% de budget = 100,8 minutos de indisponibilidade permitida por semana
#   Se gastar o budget: equipe entra em freeze de deploys até repor.

resource "datadog_service_level_objective" "availability" {
  name        = "Store API — Disponibilidade 99% (7d)"
  type        = "metric"
  description = "99% das requisições ao store-api devem retornar status não-5xx em qualquer janela de 7 dias."

  query {
    # Good events: total hits MENOS os erros (5xx)
    numerator = "sum:trace.fastapi.request.hits{service:store-api,env:sandbox}.as_count() - sum:trace.fastapi.request.errors{service:store-api,env:sandbox}.as_count()"
    # Total events: todos os hits
    denominator = "sum:trace.fastapi.request.hits{service:store-api,env:sandbox}.as_count()"
  }

  # Múltiplos timeframes: o Datadog mostra o status de cada um simultaneamente
  thresholds {
    timeframe = "7d"
    target    = 99.0
    warning   = 99.5
  }

  tags = ["service:store-api", "env:sandbox", "team:platform", "managed-by:terraform"]
}

# ── SLO 2: Latência P95 < 500ms — Monitor-based ───────────────────────────────
#
# SLI: % do tempo em que o monitor apm_latency_p95 está em estado OK
# SLO: monitor em OK >= 99.0% do tempo em 7 dias
#
# Reusa o monitor existente — não precisa redefinir o threshold aqui.
# Quando o monitor alertar (P95 > 500ms), o SLO consome error budget.

resource "datadog_service_level_objective" "latency" {
  name        = "Store API — Latência P95 < 500ms (99% em 7d)"
  type        = "monitor"
  description = "O P95 de latência do store-api deve ficar abaixo de 500ms em 99% do tempo em 7 dias."

  # Referência ao monitor criado em monitors_apm.tf — o Terraform resolve a dependência
  monitor_ids = [datadog_monitor.apm_latency_p95.id]

  thresholds {
    timeframe = "7d"
    target    = 99.0
    warning   = 99.5
  }

  tags = ["service:store-api", "env:sandbox", "team:platform", "managed-by:terraform"]
}
