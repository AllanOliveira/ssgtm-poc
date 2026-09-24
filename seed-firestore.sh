#!/usr/bin/env bash
#
# seed-firestore.sh — popula o Firestore Emulator local com dados de exemplo
# para validar o enriquecimento de eventos no ssGTM.
#
# Cria documentos na colecao `users`, indexados pelo client id (cid) que chega
# no evento. Assim uma Variable Template no GTM pode fazer Firestore.read em
# `users/{cid}` e anexar campos (segment, customer_ltv, plan) ao evento.
#
# Uso:
#   ./seed-firestore.sh                 # usa os padroes
#   FS_HOST=localhost:8082 ./seed-firestore.sh
#   PROJECT_ID=poc-sgtm ./seed-firestore.sh
#
# Requisitos: emulador no ar (make start). Ele expoe a REST na porta 8082 do host.

set -euo pipefail

# Host REST do emulador (porta publicada no host pelo docker-compose).
FS_HOST="${FS_HOST:-localhost:8082}"
# Projeto simulado pelo emulador. DEVE casar com GOOGLE_CLOUD_PROJECT / FIRESTORE_PROJECT_ID.
PROJECT_ID="${PROJECT_ID:-poc-sgtm}"

BASE="http://${FS_HOST}/v1/projects/${PROJECT_ID}/databases/(default)/documents"

# Escreve um documento com ID fixo. No emulador, o ID so e respeitado via PATCH
# no path (POST com ?documentId= gera ID aleatorio). Recebe: colecao, id, json_fields.
upsert() {
  local collection="$1" id="$2" fields="$3"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
    "${BASE}/${collection}/${id}" \
    -H 'Content-Type: application/json' \
    -d "{\"fields\": ${fields}}")
  if [ "$code" = "200" ]; then
    echo "  ok   ${collection}/${id}"
  else
    echo "  FALHA (${code}) ${collection}/${id}" >&2
    return 1
  fi
}

echo "Semeando Firestore emulator em ${BASE}"

# --- Verifica se o emulador esta acessivel antes de tentar escrever ---
if ! curl -s -o /dev/null -w '%{http_code}' "http://${FS_HOST}/" | grep -q '200'; then
  echo "ERRO: emulador nao respondeu em http://${FS_HOST}/ — rode 'make start' primeiro." >&2
  exit 1
fi

# --- Documentos de exemplo na colecao users, indexados por cid ---

# cid 555.777: e o CID padrao usado pelo `make event-purchase`.
upsert users "555.777" '{
  "segment":      { "stringValue": "vip" },
  "customer_ltv": { "doubleValue": 4820.50 },
  "plan":         { "stringValue": "gold" }
}'

upsert users "111.222" '{
  "segment":      { "stringValue": "regular" },
  "customer_ltv": { "doubleValue": 320.00 },
  "plan":         { "stringValue": "free" }
}'

upsert users "abc.123" '{
  "segment":      { "stringValue": "new" },
  "customer_ltv": { "doubleValue": 0 },
  "plan":         { "stringValue": "free" }
}'

echo "Seed concluido. Verifique com:"
echo "  curl \"${BASE}/users/555.777\""
