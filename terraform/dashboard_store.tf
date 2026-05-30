# Dashboard consolidado: APM + Negócio + Infra
# Criado via Terraform — nenhuma configuração manual pela UI é necessária.
#
# ESTRUTURA:
#   Grupo 1 → APM: request rate, error rate, latência por percentil
#   Grupo 2 → Negócio: pedidos, fila, cache, latência de processamento
#   Grupo 3 → Erros & Infra: HTTP errors por status, CPU/Memória

resource "datadog_dashboard" "store_api" {
  title       = "Store API — Observabilidade Completa"
  description = "Dashboard Fase 5: APM + DogStatsD + Infra. Gerenciado por Terraform."
  layout_type = "ordered"

  # ── Grupo 1: APM ───────────────────────────────────────────────────────────
  widget {
    group_definition {
      title       = "APM — Tráfego, Errors & Latência"
      layout_type = "ordered"

      widget {
        timeseries_definition {
          title = "Request Rate (req/s)"
          request {
            q            = "sum:trace.fastapi.request.hits{service:store-api,env:sandbox}.as_rate()"
            display_type = "line"
            style {
              palette    = "blue"
              line_width = "normal"
            }
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Error Rate (%)"
          request {
            q            = "100 * sum:trace.fastapi.request.errors{service:store-api,env:sandbox}.as_rate() / sum:trace.fastapi.request.hits{service:store-api,env:sandbox}.as_rate()"
            display_type = "area"
            style {
              palette = "warm"
            }
          }
          # Linha de referência do SLO: error_rate <= 1% → disponibilidade >= 99%
          marker {
            value        = "y = 1"
            display_type = "error dashed"
            label        = "SLO budget: 1%"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Latência P50 / P95 / P99 (segundos)"
          # P50: mediana — metade das requests é mais rápida que isso
          request {
            q            = "p50:trace.fastapi.request.duration{service:store-api,env:sandbox}"
            display_type = "line"
            style {
              palette    = "green"
              line_width = "thin"
            }
          }
          # P95: 95% das requests ficam abaixo — o "pior dos comuns"
          request {
            q            = "p95:trace.fastapi.request.duration{service:store-api,env:sandbox}"
            display_type = "line"
            style {
              palette    = "yellow"
              line_width = "normal"
            }
          }
          # P99: cauda pesada — captura os outliers
          request {
            q            = "p99:trace.fastapi.request.duration{service:store-api,env:sandbox}"
            display_type = "line"
            style {
              palette    = "orange"
              line_width = "thick"
            }
          }
          marker {
            value        = "y = 0.5"
            display_type = "error dashed"
            label        = "SLO P95: 500ms"
          }
        }
      }
    }
  }

  # ── Grupo 2: Métricas de Negócio (DogStatsD) ───────────────────────────────
  widget {
    group_definition {
      title       = "Negócio — Pedidos, Fila & Cache"
      layout_type = "ordered"

      widget {
        timeseries_definition {
          title = "Pedidos Criados por Tier de Preço"
          request {
            q            = "sum:store.orders.created{service:store-api,env:sandbox} by {price_tier}.as_count()"
            display_type = "bars"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Fila de Pedidos Pendentes (Gauge)"
          # Gauge = snapshot do estado atual. Diferente de Counter (acumulado).
          # Se crescer indefinidamente → gargalo no processamento.
          request {
            q            = "avg:store.pending_orders{service:store-api,env:sandbox}"
            display_type = "area"
            style {
              palette = "purple"
            }
          }
          marker {
            value        = "y = 50"
            display_type = "error dashed"
            label        = "Limite crítico: 50"
          }
          marker {
            value        = "y = 30"
            display_type = "warning dashed"
            label        = "Aviso: 30"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Cache: Hits vs Misses"
          request {
            q            = "sum:store.cache.requests{service:store-api,env:sandbox,result:hit}.as_count()"
            display_type = "bars"
            style {
              palette = "green"
            }
          }
          request {
            q            = "sum:store.cache.requests{service:store-api,env:sandbox,result:miss}.as_count()"
            display_type = "bars"
            style {
              palette = "orange"
            }
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Latência de Processamento P50 / P95 (ms)"
          # Histogram DogStatsD → Datadog calcula percentis automaticamente
          request {
            q            = "p50:store.order.processing_ms{service:store-api,env:sandbox}"
            display_type = "line"
            style {
              palette = "green"
            }
          }
          request {
            q            = "p95:store.order.processing_ms{service:store-api,env:sandbox}"
            display_type = "line"
            style {
              palette = "red"
            }
          }
          marker {
            value        = "y = 500"
            display_type = "error dashed"
            label        = "SLO budget: 500ms"
          }
        }
      }
    }
  }

  # ── Grupo 3: Errors HTTP & Infra ───────────────────────────────────────────
  widget {
    group_definition {
      title       = "Errors & Infraestrutura"
      layout_type = "ordered"

      widget {
        timeseries_definition {
          title = "Erros HTTP por Status Code"
          request {
            q            = "sum:store.http.errors{service:store-api,env:sandbox} by {status_code}.as_count()"
            display_type = "bars"
            style {
              palette = "warm"
            }
          }
        }
      }

      widget {
        timeseries_definition {
          title = "CPU por Container (%)"
          request {
            q            = "avg:docker.cpu.usage{*} by {container_name}"
            display_type = "line"
          }
        }
      }

      widget {
        timeseries_definition {
          title = "Memória RSS por Container (bytes)"
          request {
            q            = "avg:docker.mem.rss{*} by {container_name}"
            display_type = "area"
          }
        }
      }
    }
  }

  tags = ["team:platform"]
}
