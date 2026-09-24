#!/usr/bin/env bash
#
# seed-users.sh — insere os usuarios de users.json no Firestore Emulator.
#
# Le users.json (30 usuarios com name, email, id e objeto device) e grava cada
# um como documento na colecao `users`, usando o campo `id` (uuid) como ID do
# documento. Converte os tipos para o formato REST do Firestore, incluindo o
# objeto `device` aninhado como mapValue.
#
# Uso:
#   ./seed-users.sh
#   FS_HOST=localhost:8082 PROJECT_ID=poc-sgtm ./seed-users.sh
#
# Requisitos: emulador no ar (make start) e users.json no mesmo diretorio.

set -euo pipefail

FS_HOST="${FS_HOST:-localhost:8082}"
PROJECT_ID="${PROJECT_ID:-poc-sgtm}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERS_JSON="${SCRIPT_DIR}/users.json"

if [ ! -f "$USERS_JSON" ]; then
  echo "ERRO: nao encontrei users.json em ${USERS_JSON}" >&2
  exit 1
fi

# Verifica se o emulador esta acessivel antes de tentar escrever.
if ! curl -s -o /dev/null -w '%{http_code}' "http://${FS_HOST}/" | grep -q '200'; then
  echo "ERRO: emulador nao respondeu em http://${FS_HOST}/ — rode 'make start' primeiro." >&2
  exit 1
fi

echo "Inserindo usuarios de users.json no Firestore (${FS_HOST}, projeto ${PROJECT_ID})..."

# A conversao JSON -> formato REST do Firestore (com device como mapValue) e a
# insercao via PATCH (ID fixo = id do usuario) sao feitas em Python: mais robusto
# que montar o payload no shell, e ja disponivel no ambiente.
FS_HOST="$FS_HOST" PROJECT_ID="$PROJECT_ID" USERS_JSON="$USERS_JSON" python3 - <<'PY'
import json, os, urllib.request, urllib.error

fs_host   = os.environ["FS_HOST"]
project   = os.environ["PROJECT_ID"]
users_path= os.environ["USERS_JSON"]
base = f"http://{fs_host}/v1/projects/{project}/databases/(default)/documents"

with open(users_path, encoding="utf-8") as f:
    users = json.load(f)

def to_fs_value(v):
    # Converte um valor Python para o formato tipado do Firestore REST.
    if isinstance(v, bool):
        return {"booleanValue": v}
    if isinstance(v, int):
        return {"integerValue": str(v)}
    if isinstance(v, float):
        return {"doubleValue": v}
    if isinstance(v, str):
        return {"stringValue": v}
    if isinstance(v, dict):
        return {"mapValue": {"fields": {k: to_fs_value(val) for k, val in v.items()}}}
    raise TypeError(f"tipo nao suportado: {type(v)}")

ok = 0
for u in users:
    doc_id = u["id"]  # usa o uuid do usuario como ID do documento
    fields = {k: to_fs_value(v) for k, v in u.items()}
    payload = json.dumps({"fields": fields}).encode("utf-8")
    url = f"{base}/users/{doc_id}"
    req = urllib.request.Request(url, data=payload, method="PATCH",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            if resp.status == 200:
                ok += 1
    except urllib.error.HTTPError as e:
        print(f"  FALHA {doc_id}: HTTP {e.code} {e.read().decode()[:120]}")

print(f"  inseridos {ok}/{len(users)} usuarios na colecao users/")
PY

echo "Pronto. Liste com: curl -s \"http://${FS_HOST}/v1/projects/${PROJECT_ID}/databases/(default)/documents/users\""
