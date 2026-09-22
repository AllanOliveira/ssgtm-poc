#!/usr/bin/env bash
# Atualiza o PREVIEW_HEADER no .env com o header x-gtm-server-preview do GTM.
# Uso: ./set-preview.sh <valor-do-header>
set -euo pipefail

HEADER="${1:-}"
ENV_FILE="$(dirname "$0")/.env"

if [ -z "$HEADER" ]; then
  echo "Faltou o header. Uso: ./set-preview.sh <valor-copiado-do-GTM>"
  exit 1
fi

if grep -q '^PREVIEW_HEADER=' "$ENV_FILE" 2>/dev/null; then
  # usa | como delimitador do sed (o header nao contem |, mas contem = e /)
  sed -i "s|^PREVIEW_HEADER=.*|PREVIEW_HEADER=$HEADER|" "$ENV_FILE"
else
  echo "PREVIEW_HEADER=$HEADER" >> "$ENV_FILE"
fi

echo "PREVIEW_HEADER atualizado no .env."
SESSION="$(echo "$HEADER" | base64 -d 2>/dev/null | cut -d'|' -f3 || true)"
[ -n "$SESSION" ] && echo "Sessao de preview: $SESSION"
