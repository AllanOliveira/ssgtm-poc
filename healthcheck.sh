#!/usr/bin/env bash
# Valida se os dois servidores da PoC estão saudáveis.
# Ambos expõem /healthy e devem retornar HTTP 200.
set -euo pipefail

check() {
  local name="$1" url="$2"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || echo "000")
  if [ "$code" = "200" ]; then
    echo "OK   $name -> $url (200)"
  else
    echo "FALHA $name -> $url (recebido: $code)"
    return 1
  fi
}

echo "Verificando saude dos servidores SSGTM..."
check "tagging server" "http://localhost:8080/healthy"
check "preview server " "http://localhost:8081/healthy"
echo "Tudo saudavel. Agora configure a 'URL do container servidor' no GTM como http://localhost:8080"
