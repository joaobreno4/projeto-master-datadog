# Observabilidade Docker com Datadog & Terraform

Este projeto demonstra a implementação de uma stack de monitoramento proativo para containers Docker, utilizando Terraform para provisionar infraestrutura como código (IaC) e o Datadog como plataforma de observabilidade.

## Tecnologias Utilizadas
* **Datadog (Site US5)**: Monitoramento de métricas e alertas.
* **Terraform**: Gerenciamento de Dashboards e Monitors via código.
* **Docker & Docker Compose**: Orquestração do Datadog Agent e aplicações.
* **WSL2 (Ubuntu)**: Ambiente de desenvolvimento Linux.

## Funcionalidades Implementadas
* **Provisionamento Automático**: Dashboard criado via Terraform com métricas de CPU e Memória por container.
* **Monitoramento Proativo**: Alerta de CPU configurado com gatilhos de Warning (60%) e Critical (80%).
* **Segurança**: Gerenciamento de variáveis sensíveis e chaves de API seguindo boas práticas de DevOps.


## Como Executar o Projeto

1. **Subir o Agente**:
 

   docker-compose up -d

Provisionar a Infraestrutura:

cd terraform
terraform init
terraform apply

---

## Resultados
O dashboard reflete o consumo real dos containers em tempo real, permitindo uma análise
