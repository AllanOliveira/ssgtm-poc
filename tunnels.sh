#!/usr/bin/env bash
#
# tunnels.sh — sobe/para/checa os tuneis cloudflared da PoC (preview + tagging)
# e atualiza as URLs no .env automaticamente.
#
# Uso:
#   ./tunnels.sh start    # sobe os 2 tuneis, espera conectar e grava as URLs no .env
#   ./tunnels.sh stop     # encerra os tuneis
#   ./tunnels.sh status   # mostra se estao no ar e as URLs atuais
#
# Requisitos: cloudflared no PATH e a stack local no ar (make start).
# Os tuneis trycloudflare sao efemeros: cada `start` gera URLs novas.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DIR/.env"
TUNNEL_DIR="$DIR/.tunnel"
PREVIEW_LOG="$TUNNEL_DIR/preview_tunnel.log"
TAGGING_LOG="$TUNNEL_DIR/tagging_tunnel.log"

# Protocolo: http2 e mais robusto quando UDP/QUIC (porta 7844) esta bloqueado.
PROTOCOL="${PROTOCOL:-http2}"

# Grava/atualiza uma chave no .env (cria se nao existir). Usa | como delimitador
# do sed pois as URLs contem / (mas nunca |).
set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

# Extrai a primeira URL trycloudflare de um log.
url_from_log() {
  grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$1" 2>/dev/null | head -1
}

cmd_stop() {
  if pgrep -x cloudflared >/dev/null 2>&1; then
    pkill cloudflared 2>/dev/null || true
    sleep 1
    if pgrep -x cloudflared >/dev/null 2>&1; then
      pkill -9 cloudflared 2>/dev/null || true
      sleep 1
    fi
    echo "tuneis encerrados."
  else
    echo "nenhum tunel cloudflared rodando."
  fi
}

cmd_status() {
  echo "=== processos cloudflared ==="
  pgrep -a cloudflared || echo "  nenhum rodando"
  echo ""
  echo "=== URLs no .env ==="
  grep -E '^(PREVIEW_SERVER_URL|TAGGING_SERVER_URL)=' "$ENV_FILE" 2>/dev/null || echo "  (nenhuma definida)"
  echo ""
  local prev tag
  prev="$(grep '^PREVIEW_SERVER_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  tag="$(grep '^TAGGING_SERVER_URL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  echo "=== teste de resposta (timeout 10s) ==="
  if [ -n "$prev" ]; then curl -s -m 10 -o /dev/null -w "  preview -> HTTP %{http_code}\n" "$prev/healthy" || true; else echo "  preview -> (sem URL)"; fi
  if [ -n "$tag" ];  then curl -s -m 10 -o /dev/null -w "  tagging -> HTTP %{http_code}\n" "$tag/healthy"  || true; else echo "  tagging -> (sem URL)"; fi
}

cmd_start() {
  command -v cloudflared >/dev/null 2>&1 || { echo "ERRO: cloudflared nao esta no PATH."; exit 1; }
  mkdir -p "$TUNNEL_DIR"

  # A stack local precisa estar no ar para o tunel ter o que servir.
  if ! curl -s -m 5 -o /dev/null -w '%{http_code}' http://localhost:8080/healthy | grep -q 200; then
    echo "AVISO: tagging server (8080) nao respondeu 200. Rode 'make start' antes." >&2
  fi

  # Estado limpo.
  pkill cloudflared 2>/dev/null || true
  sleep 1

  # --- Descoberta de edge IPs (contorno p/ DNS bloqueado) ---
  # O cloudflared resolve region{1,2}.v2.argotunnel.com para achar a borda.
  # Em ambientes onde o resolver local (127.0.0.53) nao responde nem por UDP nem
  # por TCP, resolvemos nos mesmos os IPs consultando um upstream direto via TCP
  # e passamos com --edge, pulando a resolucao problematica. Se a descoberta
  # falhar, seguimos sem --edge (ambiente com DNS normal).
  local edge_args="" edge_ips=""
  local upstream
  upstream=$(resolvectl status 2>/dev/null | awk '/DNS Servers:/{print $3; exit}' || true)
  if [ -n "$upstream" ]; then
    # subshell isolado: pipefail desligado e || true para nao abortar (set -e)
    # se a descoberta falhar — ela e opcional, ha fallback sem --edge.
    edge_ips=$(set +o pipefail; { for r in region1 region2; do
        dig +tcp +short +time=4 +tries=1 "A" "$r.v2.argotunnel.com" "@$upstream" 2>/dev/null || true
      done; } | grep -E '^[0-9]+\.' | sort -u || true)
  fi
  if [ -n "$edge_ips" ]; then
    while read -r ip; do
      [ -n "$ip" ] && edge_args="$edge_args --edge ${ip}:7844"
    done <<< "$edge_ips"
    echo "Edge IPs descobertos via ${upstream} (TCP):" $(echo "$edge_ips" | tr '\n' ' ')
  fi

  echo "Subindo tunel do preview (8081) e tagging (8080) via protocolo ${PROTOCOL}..."
  # RES_OPTIONS=use-vc forca o resolver a usar DNS via TCP (para os lookups
  # auxiliares do cloudflared). O --edge (acima) evita depender da resolucao do
  # SRV, que e o que costuma falhar quando o DNS/UDP esta bloqueado.
  RES_OPTIONS="${RES_OPTIONS:-use-vc}" \
    nohup cloudflared tunnel --protocol "$PROTOCOL" $edge_args --url http://localhost:8081 > "$PREVIEW_LOG" 2>&1 &
  local preview_pid=$!
  RES_OPTIONS="${RES_OPTIONS:-use-vc}" \
    nohup cloudflared tunnel --protocol "$PROTOCOL" $edge_args --url http://localhost:8080 > "$TAGGING_LOG" 2>&1 &
  local tagging_pid=$!

  # Espera as conexoes serem registradas na borda da Cloudflare (ate ~60s).
  echo -n "Aguardando os tuneis conectarem"
  local connected=0 i
  for i in $(seq 1 30); do
    sleep 2; echo -n "."
    local pc tc
    pc=$(grep -c "Registered tunnel connection" "$PREVIEW_LOG" 2>/dev/null; true)
    tc=$(grep -c "Registered tunnel connection" "$TAGGING_LOG" 2>/dev/null; true)
    pc=${pc:-0}; tc=${tc:-0}
    if [ "$pc" -ge 1 ] && [ "$tc" -ge 1 ]; then connected=1; break; fi
    # se ambos os processos morreram, aborta cedo
    pgrep -x cloudflared >/dev/null 2>&1 || break
  done
  echo ""

  local preview_url tagging_url
  preview_url="$(url_from_log "$PREVIEW_LOG")"
  tagging_url="$(url_from_log "$TAGGING_LOG")"

  if [ "$connected" != "1" ]; then
    echo "" >&2
    echo "FALHA: os tuneis nao estabeleceram conexao com a Cloudflare." >&2
    echo "Causa provavel: DNS/saida de rede bloqueada neste ambiente." >&2
    echo "(este script ja tenta DNS via TCP com RES_OPTIONS=use-vc)" >&2
    echo "Diagnostico rapido:" >&2
    echo "  dig +tcp SRV _v2-origintunneld._tcp.argotunnel.com   # deve responder" >&2
    echo "  e a porta 7844/TCP do IP retornado deve ser alcancavel." >&2
    echo "Ultimos erros do log tagging:" >&2
    grep -iE 'ERR|timeout|hard_fail|resolve' "$TAGGING_LOG" 2>/dev/null | tail -4 | sed 's/^/    /' >&2
    echo "" >&2
    echo "Nao atualizei o .env (as URLs nao respondem). Encerrando os processos." >&2
    kill "$preview_pid" "$tagging_pid" 2>/dev/null || true
    pkill cloudflared 2>/dev/null || true
    sleep 1
    # fallback: se algum sobreviveu, forca com -9
    if pgrep -x cloudflared >/dev/null 2>&1; then
      pkill -9 cloudflared 2>/dev/null || true
    fi
    exit 1
  fi

  # Sucesso: grava as URLs no .env.
  [ -n "$preview_url" ] && set_env "PREVIEW_SERVER_URL" "$preview_url"
  [ -n "$tagging_url" ] && set_env "TAGGING_SERVER_URL" "$tagging_url"

  echo "Tuneis no ar e URLs gravadas no .env:"
  echo "  PREVIEW_SERVER_URL = $preview_url   (porta 8081)"
  echo "  TAGGING_SERVER_URL = $tagging_url   (porta 8080)"
  echo ""
  echo "Proximos passos:"
  echo "  1. Recrie o tagging com a nova URL de preview:  make start"
  echo "  2. No GTM, cole a URL do TAGGING como 'URL do container servidor':"
  echo "       $tagging_url"
  echo "  3. Abra o modo Preview no GTM e rode:  make set-preview HEADER=<valor-do-GTM>"
  echo ""
  echo "AVISO: enquanto os tuneis estiverem no ar, qualquer pessoa com a URL"
  echo "alcanca seus servidores locais. Aceitavel para PoC; nunca em producao."
}

case "${1:-}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *) echo "Uso: $0 {start|stop|status}"; exit 1 ;;
esac
