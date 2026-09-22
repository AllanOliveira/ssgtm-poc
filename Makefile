# Makefile — PoC do Server-Side Google Tag Manager (SSGTM)
#
# Uso: make <comando>. Rode `make help` para ver todos os comandos.

COMPOSE := docker compose

.DEFAULT_GOAL := help

.PHONY: help start stop restart logs ps health pull clean setup event-purchase set-preview

# --- Parametros do `make event` (podem ser sobrescritos na linha de comando) ---
# Carrega variaveis do .env (TAGGING_SERVER_URL, CONTAINER_CONFIG, etc.)
-include .env
export

# Host de destino: usa TAGGING_SERVER_URL do .env; se vazio, cai no localhost.
HOST     ?= $(if $(TAGGING_SERVER_URL),$(TAGGING_SERVER_URL),http://localhost:8080)
# Measurement ID (GA4). Ajuste para o seu, ou sobrescreva: make event TID=G-XXXX
TID      ?= G-KK7D6KBG
EVENT    ?= purchase
CID      ?= 555.777
VALUE    ?= 99.90
CURRENCY ?= BRL
TXID     ?= T$(shell date +%s)
# Header que vincula o evento a sessao de preview do GTM (Tag Assistant).
# Pegue o valor no GTM: modo Preview > menu (3 pontos) > "Send requests manually"
# ou copie de um request de exemplo. Guarde em PREVIEW_HEADER no .env.
# Sem ele o evento e processado, mas NAO aparece no Tag Assistant.
PREVIEW_HEADER ?=

help: ## Lista os comandos disponiveis
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

setup: ## Cria o .env a partir do .env.example (se ainda nao existir)
	@test -f .env || (cp .env.example .env && echo "Criado .env — edite e cole o CONTAINER_CONFIG do GTM")
	@test -f .env && echo ".env pronto"

start: ## Sobe os servidores (preview + tagging) em background
	$(COMPOSE) up -d

stop: ## Para e remove os containers
	$(COMPOSE) down

restart: ## Reinicia os servidores
	$(COMPOSE) restart

logs: ## Mostra os logs em tempo real (Ctrl+C para sair)
	$(COMPOSE) logs -f

ps: ## Mostra o status dos containers
	$(COMPOSE) ps

health: ## Verifica se os servidores estao saudaveis (/healthy)
	@./healthcheck.sh

pull: ## Atualiza a imagem oficial do GTM para a versao mais recente
	$(COMPOSE) pull

clean: ## Para os containers e remove imagens/volumes orfaos
	$(COMPOSE) down --rmi local --volumes --remove-orphans

event-purchase: ## Dispara um evento purchase de teste (ex: make event-purchase VALUE=250)
	@echo "-> $(EVENT) para $(HOST) (tid=$(TID), cid=$(CID), value=$(VALUE) $(CURRENCY), txid=$(TXID))"
	@if [ -z "$(PREVIEW_HEADER)" ]; then \
		echo "AVISO: PREVIEW_HEADER vazio — o evento nao aparecera no Tag Assistant."; \
	fi
	@curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
		$(if $(PREVIEW_HEADER),-H 'x-gtm-server-preview: $(PREVIEW_HEADER)',) \
		"$(HOST)/g/collect?v=2&tid=$(TID)&cid=$(CID)&en=$(EVENT)&ep.transaction_id=$(TXID)&epn.value=$(VALUE)&ep.currency=$(CURRENCY)"

set-preview: ## Atualiza o PREVIEW_HEADER no .env (uso: make set-preview HEADER=<valor-do-header>)
	@test -n "$(HEADER)" || { echo "Faltou o header. Uso: make set-preview HEADER=<valor-copiado-do-GTM>"; exit 1; }
	@./set-preview.sh "$(HEADER)"
