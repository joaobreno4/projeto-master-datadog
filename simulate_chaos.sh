#!/usr/bin/env bash
# simulate_chaos.sh — Dispara cenários de caos contra o store-api para
# cruzar as linhas de marker configuradas no Terraform e ver os monitores
# do Datadog alertando em tempo real.
#
# USO:
#   ./simulate_chaos.sh              → roda cenário 1 + 2 em sequência
#   ./simulate_chaos.sh pending [N]  → cria N pedidos pendentes (default: 60)
#   ./simulate_chaos.sh errors  [N]  → dispara N erros em /error-test (default: 200)
#   ./simulate_chaos.sh cleanup      → processa todos os pedidos pendentes
#
# VARIÁVEIS DE AMBIENTE:
#   BASE_URL=http://localhost:8000   → URL da API (default)

set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"

# ── ANSI ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m';    NC='\033[0m'

log()  { echo -e "  ${CYN}▶${NC} $*"; }
ok()   { echo -e "  ${GRN}✔${NC} $*"; }
warn() { echo -e "  ${YEL}⚠${NC} $*"; }
sep()  { echo -e "  ${BLD}─────────────────────────────────────────────────${NC}"; }

# ── Healthcheck ───────────────────────────────────────────────────────────────
check_api() {
    if ! curl -sf "$BASE_URL/health" > /dev/null 2>&1; then
        echo -e "\n  ${RED}✘ API inacessível em $BASE_URL${NC}"
        echo -e "  Suba o ambiente primeiro:\n    docker compose up -d\n"
        exit 1
    fi
    ok "API respondendo em ${BLD}$BASE_URL${NC}"
}

# ── Cenário 1: flood_pending_orders ──────────────────────────────────────────
#
# O QUE FAZ:
#   Cria N pedidos via POST /orders sem jamais chamar /orders/{id}/process.
#   Cada criação emite um Gauge (store.pending_orders) com o total atual da fila.
#
# POR QUE DISPARA O MONITOR:
#   Monitor "Fila de Pedidos Pendentes Alta" avalia:
#     avg(last_5m): avg:store.pending_orders{...} > 50
#   A cada pedido criado, a app faz um SELECT COUNT(*) WHERE status='pending'
#   e emite o resultado como gauge. Com 60+ pedidos acumulados, a média da
#   janela de 5 min ultrapassa 50 → ALERT.
#
# NO DASHBOARD:
#   Widget "Fila de Pedidos Pendentes (Gauge)" mostra a curva subindo e
#   cruzando a linha vermelha "Limite crítico: 50".
#
flood_pending_orders() {
    local n="${1:-60}"
    local products=("notebook" "teclado" "monitor" "headset" "webcam" "mouse" "ssd" "ram" "gpu" "hub-usb")

    echo ""
    echo -e "  ${BLD}${RED}💥 CENÁRIO 1 — Flood Pending Orders${NC}"
    sep
    log "Criando ${BLD}$n${NC} pedidos sem processar"
    log "Monitor alvo : ${BLD}[store-api] Negócio — Fila de Pedidos Pendentes Alta${NC}"
    log "Threshold    : avg(last_5m) > ${BLD}50 pedidos${NC} → linha vermelha no dashboard"
    sep
    echo ""

    local created=0 failed=0

    for i in $(seq 1 "$n"); do
        local prod="${products[$((i % ${#products[@]}))]}"
        # Preço entre R$50,00 e R$999,99 com decimais reais
        local cents=$(( RANDOM % 95000 + 5000 ))
        local price="$(( cents / 100 )).$(printf '%02d' $(( cents % 100 )))"
        local qty=$(( RANDOM % 5 + 1 ))

        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "$BASE_URL/orders" \
            -H "Content-Type: application/json" \
            -d "{\"product\":\"$prod\",\"quantity\":$qty,\"price\":$price}")

        if [[ "$status" == "201" ]]; then
            (( created++ ))
        else
            (( failed++ ))
        fi

        printf "\r  Pedidos criados: ${GRN}%d${NC} / %d  (falhas: %d)" "$created" "$n" "$failed"
        sleep 0.08   # ~12 req/s — visível nos gráficos sem saturar o stack local
    done

    echo -e "\n"
    ok "${BLD}$created${NC} pedidos pendentes no banco"
    [[ $failed -gt 0 ]] && warn "$failed requests falharam (API sobrecarregada?)"
    echo ""
    warn "Aguarde ~1 min → gauge store.pending_orders cruza ${BLD}y=50${NC} no dashboard"
    warn "Monitor entra em ${RED}ALERT${NC} após avg(last_5m) > 50"
}

# ── Cenário 2: bomb_error_rate ────────────────────────────────────────────────
#
# O QUE FAZ:
#   Bombardeia /error-test em bursts paralelos. Esse endpoint levanta
#   HTTPException(500) intencionalmente, que o ddtrace captura como span de erro.
#   A cada 10 erros injeta 1 request normal (/health) para haver denominador
#   real — mas a error rate ainda fica em ~90%, muito acima do threshold.
#
# POR QUE DISPARA O MONITOR:
#   Monitor "APM — Error Rate Alta" avalia:
#     sum(last_5m): (errors.as_count() / hits.as_count()) * 100 > 10
#   Com 90%+ de error rate na janela de 5 min, o threshold de 10% é
#   ultrapassado com folga → CRITICAL.
#
# NO DASHBOARD:
#   Widget "Error Rate (%)" mostra a curva subindo e cruzando a linha
#   vermelha "SLO budget: 1%" (e o monitor dispara bem antes disso).
#
bomb_error_rate() {
    local n="${1:-200}"
    local burst=5   # requests paralelos por ciclo
    local normal_every=10  # 1 request normal a cada N erros

    echo ""
    echo -e "  ${BLD}${RED}💥 CENÁRIO 2 — Bomb Error Rate${NC}"
    sep
    log "Disparando ${BLD}$n${NC} requisições para /error-test em bursts de $burst"
    log "Monitor alvo : ${BLD}[store-api] APM — Error Rate Alta${NC}"
    log "Threshold    : (errors / hits) * 100 > ${BLD}10%${NC} → linha vermelha no dashboard"
    sep
    echo ""

    local errors=0 normal=0 i=0

    while (( i < n )); do
        # Burst de erros em paralelo
        local b=0
        while (( b < burst && i < n )); do
            curl -s -o /dev/null "$BASE_URL/error-test" &
            (( errors++ )); (( i++ )); (( b++ ))
        done

        # Request normal intercalado para ter denominador real
        if (( errors % normal_every == 0 )); then
            curl -s -o /dev/null "$BASE_URL/health" &
            (( normal++ ))
        fi

        wait  # aguarda o burst terminar antes do próximo

        local total=$(( errors + normal ))
        local rate_str
        rate_str=$(awk "BEGIN{printf \"%.0f\", $errors / ($total + 0.001) * 100}")
        printf "\r  Erros: ${RED}%d${NC}  Normais: ${GRN}%d${NC}  Error rate: ${RED}%s%%${NC}   " \
            "$errors" "$normal" "$rate_str"

        sleep 0.05
    done

    wait
    echo -e "\n"

    local total=$(( errors + normal ))
    local rate_final
    rate_final=$(awk "BEGIN{printf \"%.1f\", $errors / ($total + 0.001) * 100}")
    ok "${BLD}$errors${NC} erros em $total requests totais → ${RED}${rate_final}%${NC} de error rate"
    echo ""
    warn "Aguarde ~1 min → curva de Error Rate cruza ${BLD}y=10%${NC} no dashboard"
    warn "Monitor entra em ${RED}ALERT${NC} após avg(last_5m) > 10%"
}

# ── Cenário 3: cleanup ────────────────────────────────────────────────────────
#
# Processa todos os pedidos pendentes para zerar o gauge store.pending_orders.
# Útil para resetar o estado após o caos e observar o monitor se recuperando.
#
cleanup_pending() {
    echo ""
    echo -e "  ${BLD}${GRN}🧹 CLEANUP — Processar Pedidos Pendentes${NC}"
    sep
    log "Buscando pedidos com status=pending..."
    echo ""

    local ids
    ids=$(curl -sf "$BASE_URL/orders" 2>/dev/null | python3 -c "
import sys, json
orders = json.load(sys.stdin)
pending = [str(o['id']) for o in orders if o['status'] == 'pending']
print(' '.join(pending))
" 2>/dev/null || true)

    if [[ -z "${ids// /}" ]]; then
        ok "Nenhum pedido pendente. Fila já está zerada."
        return
    fi

    local count
    count=$(echo "$ids" | wc -w)
    log "Processando ${BLD}$count${NC} pedidos pendentes..."

    local processed=0 failed=0
    for id in $ids; do
        local status
        status=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/orders/$id/process")
        if [[ "$status" == "200" ]]; then
            (( processed++ ))
        else
            (( failed++ ))
        fi
        printf "\r  Processados: ${GRN}%d${NC} / %d" "$processed" "$count"
    done

    echo -e "\n"
    ok "${BLD}$processed${NC} pedidos processados — gauge store.pending_orders voltando a 0"
    [[ $failed -gt 0 ]] && warn "$failed pedidos falharam ao processar"
    warn "Monitor deve se recuperar (ALERT → OK) após a janela de 5 min"
}

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo -e "${BLD}${RED}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║          🔥  DATADOG CHAOS SIMULATOR  🔥            ║"
    echo "  ║        store-api  ·  env:sandbox  ·  Fase 5         ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${CYN}Base URL  :${NC} $BASE_URL"
    echo -e "  ${CYN}Dashboard :${NC} https://us5.datadoghq.com/dashboard/cvw-kyf-ma4"
    echo -e "  ${CYN}Monitores :${NC} https://us5.datadoghq.com/monitors/manage?q=tag%3Aservice%3Astore-api"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
print_banner
check_api

case "${1:-all}" in
    pending)
        flood_pending_orders "${2:-60}"
        ;;
    errors)
        bomb_error_rate "${2:-200}"
        ;;
    cleanup)
        cleanup_pending
        ;;
    all)
        flood_pending_orders 60
        echo ""
        sleep 1
        bomb_error_rate 200
        echo ""
        sep
        echo ""
        ok "${BLD}Ambos os cenários disparados!${NC}"
        echo ""
        log "Abra o dashboard e observe:"
        log "  ${GRN}1.${NC} Gauge 'Fila de Pedidos Pendentes' cruzando ${BLD}y=50${NC} (linha vermelha)"
        log "  ${RED}2.${NC} Curva 'Error Rate' cruzando ${BLD}y=10%${NC} (linha vermelha)"
        log "  ${YEL}3.${NC} Monitores entrando em ${RED}ALERT${NC} na aba Monitors"
        echo ""
        log "Para resetar o estado: ${BLD}./simulate_chaos.sh cleanup${NC}"
        echo ""
        ;;
    *)
        echo -e "\n  ${BLD}Uso:${NC} $0 [all|pending|errors|cleanup] [count]\n"
        echo "    all         → Roda cenário 1 + 2 em sequência ${BLD}(default)${NC}"
        echo "    pending [N] → Cria N pedidos sem processar ${YEL}(default: 60)${NC}"
        echo "    errors  [N] → Dispara N erros em /error-test ${YEL}(default: 200)${NC}"
        echo "    cleanup     → Processa todos os pedidos pendentes"
        echo ""
        echo "  ${CYN}Exemplos:${NC}"
        echo "    ./simulate_chaos.sh                # roda tudo"
        echo "    ./simulate_chaos.sh pending 100    # 100 pedidos pendentes"
        echo "    ./simulate_chaos.sh errors 500     # 500 erros"
        echo "    ./simulate_chaos.sh cleanup        # zera a fila"
        echo ""
        ;;
esac
