resource "datadog_dashboard" "docker_dashboard" {
  title       = "Dashboard Docker - Joao Breno"
  description = "Criado via Terraform"
  layout_type = "ordered"

  widget {
    timeseries_definition {
      title = "Uso de CPU por Container"
      request {
        q = "avg:docker.cpu.usage{*} by {container_name}"
        display_type = "line"
      }
    }
  }

  widget {
    timeseries_definition {
      title = "Memoria por Container"
      request {
        q = "avg:docker.mem.rss{*} by {container_name}"
        display_type = "area"
      }
    }
  }
}

resource "datadog_monitor" "cpu_usage_alert" {
  name               = "Alerta: CPU Alta nos Containers - Joao Breno"
  type               = "metric alert"
  message            = "O container {{container_name.name}} esta com uso de CPU elevado ({{value}}%). @joao.silva@deal.com.br"
  
  # Esta query olha a média de CPU por container nos últimos 5 minutos
  query = "avg(last_5m):avg:docker.cpu.usage{*} by {container_name} > 80"

  monitor_thresholds {
    critical = 80
    warning  = 60
  }

  notify_audit = false
  timeout_h    = 0
  include_tags = true

  tags = ["owner:joao_breno", "projeto:master-datadog"]
}
