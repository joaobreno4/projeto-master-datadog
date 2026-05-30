# Monitores de APM e Negócio para o store-api
#
# THRESHOLD vs ANOMALY — quando usar cada um:
#
#   THRESHOLD: você conhece o limite aceitável a priori e ele não muda com o tempo.
#   Exemplo: error rate > 10% é sempre crítico, independente da hora.
#   Simples, previsível, zero histórico necessário.
#
#   ANOMALY: o valor "normal" varia com o tempo (pico de dia, fim de semana),
#   e um threshold fixo geraria falsos positivos. O algoritmo aprende a baseline
#   histórica e alerta quando o comportamento DESVIA do padrão aprendido.
#   Exemplo: latência normal é 150ms às 10h e 400ms às 23h — threshold fixo
#   de 300ms alertaria toda noite sem motivo.

locals {
  service_tags = [
    "service:store-api",
    "env:sandbox",
    "team:platform",
    "managed-by:terraform",
  ]
  # Troque por "@slack-sre-alerts" ou "@pagerduty" para notificações reais
  notify = ""
}

# ── Monitor 1: APM Error Rate — Threshold ─────────────────────────────────────
resource "datadog_monitor" "apm_error_rate" {
  name    = "[store-api] APM — Error Rate Alta"
  type    = "query alert"
  message = <<-EOT
    🚨 A taxa de erros do *store-api* está em {{value}}%.
    Threshold crítico: {{threshold}}%

    [APM Service Page](https://us5.datadoghq.com/apm/services/store-api)
    [Logs de Erro](https://us5.datadoghq.com/logs?query=service%3Astore-api+status%3Aerror)

    ${local.notify}
  EOT

  # Fórmula: (errors / total_hits) * 100
  # .as_count() agrega o total no período — mais estável que .as_rate() aqui
  query = "sum(last_5m):( sum:trace.fastapi.request.errors{service:store-api,env:sandbox}.as_count() / sum:trace.fastapi.request.hits{service:store-api,env:sandbox}.as_count() ) * 100 > 10"

  monitor_thresholds {
    critical          = 10
    warning           = 5
    critical_recovery = 5
    warning_recovery  = 2
  }

  require_full_window = false  # não espera janela completa — alerta mais rápido
  notify_no_data      = false  # sandbox pode ficar idle sem tráfego

  tags = local.service_tags
}

# ── Monitor 2: APM P95 Latência — Threshold ────────────────────────────────────
resource "datadog_monitor" "apm_latency_p95" {
  name    = "[store-api] APM — P95 Latência > 500ms"
  type    = "query alert"
  message = <<-EOT
    ⏱ Latência P95 do *store-api* está em {{value}}s.
    Threshold crítico: {{threshold}}s (500ms)

    Consulte o Flame Graph no Trace Explorer para identificar o span mais lento.
    [Trace Explorer](https://us5.datadoghq.com/apm/traces?query=service%3Astore-api)

    ${local.notify}
  EOT

  # APM trace metrics usam segundos (não ms) como unidade de duração
  query = "avg(last_5m):p95:trace.fastapi.request.duration{service:store-api,env:sandbox} > 0.5"

  monitor_thresholds {
    critical          = 0.5    # 500ms
    warning           = 0.3    # 300ms
    critical_recovery = 0.4
    warning_recovery  = 0.25
  }

  require_full_window = false
  notify_no_data      = false

  tags = local.service_tags
}

# ── Monitor 3: Fila de Pendentes — Threshold (métrica de negócio) ─────────────
resource "datadog_monitor" "pending_orders_high" {
  name    = "[store-api] Negócio — Fila de Pedidos Pendentes Alta"
  type    = "query alert"
  message = <<-EOT
    📦 Há {{value}} pedidos pendentes — acima do limite de {{threshold}}.

    Possíveis causas:
    - Gargalo no endpoint POST /orders/{id}/process
    - Alto volume de criações sem processamento correspondente

    Verifique `store.order.processing_ms` no Dashboard.

    ${local.notify}
  EOT

  query = "avg(last_5m):avg:store.pending_orders{service:store-api,env:sandbox} > 50"

  monitor_thresholds {
    critical = 50
    warning  = 30
  }

  require_full_window = false
  notify_no_data      = false

  tags = local.service_tags
}

# ── Monitor 4: Latência de Processamento — Anomaly Detection ──────────────────
# Usa algoritmo "basic" (sem sazonalidade) porque o sandbox tem < 2 semanas
# de histórico. Em produção com 2+ semanas: use "agile" ou "robust".
#
# A query retorna um score entre 0 e 1:
#   0   = dentro da banda normal
#   1   = completamente fora da banda (anomalia confirmada)
#
# O threshold >= 1 significa "alertar quando 100% do período está anômalo".
# Para sensibilidade maior: use >= 0.75 (75% do período anômalo).
resource "datadog_monitor" "processing_latency_anomaly" {
  name    = "[store-api] Negócio — Latência de Processamento Anômala"
  type    = "query alert"
  message = <<-EOT
    🔍 A latência de processamento de pedidos está anômala.
    Valor atual: {{value}}ms

    Este monitor usa Anomaly Detection — não um threshold fixo.
    O algoritmo aprendeu que a latência normal é ~150ms (sleep intencional).
    Um desvio acima de 3 desvios padrão dispara este alerta.

    [Dashboard de Negócio](https://us5.datadoghq.com/dashboard/lists)

    ${local.notify}
  EOT

  # anomalies(metric, algorithm, deviations)
  query = "avg(last_15m):anomalies(avg:store.order.processing_ms{service:store-api,env:sandbox}, 'basic', 3) >= 1"

  monitor_thresholds {
    critical = 1
    warning  = 0.75
  }

  monitor_threshold_windows {
    trigger_window  = "last_15m"
    recovery_window = "last_15m"
  }

  require_full_window = false
  notify_no_data      = false

  tags = local.service_tags
}
