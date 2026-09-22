# PoC — Server-Side Google Tag Manager (SSGTM)

Objetivo: subir um servidor de tags do GTM localmente e validar o fluxo
ponta a ponta usando GA4 (o caso mais simples de validar).

## Como funciona

O SSGTM é um servidor Node.js distribuído pela Google como imagem Docker.
A mesma imagem roda em dois papéis:

- **preview server** — serve o modo debug/preview do GTM (1 instância).
- **tagging server (SST)** — ponto de entrada real dos eventos; recebe as
  requisições do navegador e dispara as tags (ex.: GA4).

Fluxo da PoC:

```
navegador / curl  ->  tagging server (localhost:8080)  ->  GA4 (DebugView)
                          |
                          +-> preview server (localhost:8081) para debug
```

## Pré-requisitos

- Docker + Docker Compose (já validados neste ambiente)
- Uma **conta GTM** com um container do tipo **Servidor** (gratuito).
  Como você ainda nao tem acesso ao GTM da empresa, crie uma conta pessoal
  de teste em https://tagmanager.google.com
- Uma **propriedade GA4** de teste, para obter o Measurement ID (G-XXXXXXXXXX)

## Passo 1 — Obter o CONTAINER_CONFIG no GTM

1. Em https://tagmanager.google.com crie um container do tipo **Servidor**.
2. Abra o container, clique no **ID do container** (canto superior direito).
3. Escolha **"Provisionar servidor de tags manualmente"**.
4. Copie a string **Container Config** (base64 longa).

## Passo 2 — Configurar e subir localmente

```bash
cp .env.example .env
# edite .env e cole o valor real em CONTAINER_CONFIG

docker compose up -d
./healthcheck.sh    # deve mostrar 200 para os dois servidores
```

- Tagging server: http://localhost:8080
- Preview server: http://localhost:8081

## Passo 3 — Conectar o GTM ao servidor local

No GTM, em **Admin > Configuracoes do container**, coloque em
**URL do container servidor**: `http://localhost:8080` e salve.

Clique em **Visualizar (Preview)**. A pagina de debug deve carregar.
Em outra aba, acesse `http://localhost:8080/` — a requisicao deve aparecer
na sessao de preview. Isso confirma que preview + tagging estao integrados.

## Passo 4 — A tag mais simples: GA4

O GA4 ja vem embutido no container servidor (client + tag), sem imports.

1. No container servidor, crie o **Client "GA4"** (aceita requisicoes no
   formato Measurement Protocol) — normalmente ja existe por padrao.
2. Crie uma **Tag do tipo "Google Analytics: GA4"** com o seu Measurement ID.
3. No GA4, abra **Admin > DebugView**.
4. Envie um evento de teste para o servidor local (exemplo abaixo).
5. O evento deve aparecer no DebugView em tempo real.

Exemplo de requisicao de teste (Measurement Protocol para GA4) ao servidor:

```bash
# Substitua G-XXXXXXXXXX pelo seu Measurement ID.
# O tagging server escuta o caminho /g/collect (endpoint do GA4 client).
curl -v "http://localhost:8080/g/collect?v=2&tid=G-XXXXXXXXXX&cid=555.777&en=poc_test&_dbg=1"
```

Se o evento `poc_test` aparecer no DebugView do GA4, a integracao
esta validada de ponta a ponta.

> Atalho: em vez de montar o curl na mao, use `make event-purchase` (ver secao
> "Disparar eventos de teste"). Para o evento aparecer no Tag Assistant, lembre
> de configurar o header com `make set-preview HEADER=<valor-do-GTM>`.

## Encerrar

```bash
make stop
```

## Passo a passo com o Makefile

```bash
make setup   # 1. cria o .env a partir do .env.example (edite e cole o CONTAINER_CONFIG)
make start   # 2. sobe a aplicacao (preview + tagging)
make logs    # 3. acompanha os logs em tempo real (Ctrl+C para sair)
make stop    # 4. derruba a aplicacao
```

## Disparar eventos de teste

Depois de subir a aplicacao, voce pode disparar eventos para o tagging server
sem precisar de um site real, usando o Makefile.

```bash
make event-purchase                     # dispara um evento "purchase" com valores padrao
make event-purchase VALUE=250           # sobrescreve o valor da compra
make event-purchase CID=abc.123 VALUE=9 # sobrescreve cliente e valor
```

Parametros (todos com padrao, sobrescreviveis na linha de comando):

| Var        | Padrao          | O que e                                   |
|------------|-----------------|-------------------------------------------|
| `VALUE`    | `99.90`         | valor da compra                           |
| `CURRENCY` | `BRL`           | moeda                                     |
| `CID`      | `555.777`       | client id (identifica o "usuario")        |
| `TID`      | `G-KK7D6KBG`    | Measurement ID (GA4)                      |
| `TXID`     | `T<timestamp>`  | id da transacao (unico a cada disparo)    |
| `HOST`     | do `.env`       | destino; cai em `localhost:8080` se vazio |

O host vem de `TAGGING_SERVER_URL` no `.env` (a URL publica do tunel do tagging).

### O header de preview (x-gtm-server-preview) — IMPORTANTE

Para o evento **aparecer no Tag Assistant**, a requisicao precisa levar o header
`x-gtm-server-preview`. Esse header contem o **ID da sessao de preview**, que o
GTM **regenera toda vez que voce reinicia o modo Preview**. Ou seja: ao reiniciar
o preview, o header antigo para de funcionar e o evento deixa de aparecer na
interface (embora ainda seja processado — retorna HTTP 200).

Fluxo toda vez que (re)abrir o Preview no GTM:

```bash
# 1. copie o valor do header x-gtm-server-preview no GTM (modo Preview)
# 2. atualize no .env com um comando:
make set-preview HEADER=<valor-copiado-do-GTM>
# 3. dispare o evento:
make event-purchase
```

> Nota: use `HEADER=<valor>` (e nao argumento posicional). O valor do header
> termina em `=` (padding base64) e o Make so interpreta corretamente na forma
> `VAR=valor`, pois corta apenas na primeira `=`. Um argumento posicional
> terminando em `=` e tratado pelo Make como atribuicao de variavel e descartado.

Sem o `PREVIEW_HEADER` definido, o `make event-purchase` ainda dispara o evento,
mas avisa que ele nao aparecera no Tag Assistant.

## Modo Preview do GTM com cloudflared (interface de debug)

O SSGTM **nao tem interface web propria**. A tela de debug (Tag Assistant)
vive dentro do proprio GTM (tagmanager.google.com) e precisa alcancar o seu
servidor local. Como o GTM roda na nuvem, ele nao enxerga `localhost` e exige
**URLs HTTPS publicas**. Usamos o **cloudflared** para criar tuneis HTTPS
temporarios (gratuitos, sem cadastro) apontando para os servidores locais.

Arquitetura:

```
GTM (nuvem) --preview--> https://<tunel-preview>.trycloudflare.com --> preview server (8081)
GTM (nuvem) --eventos--> https://<tunel-tagging>.trycloudflare.com --> tagging server (8080)
                                                     ^
                       PREVIEW_SERVER_URL no tagging aponta para o tunel do preview
```

### 1. Instalar o cloudflared

```bash
# Linux amd64 — binario oficial, sem sudo (instala em ~/.local/bin)
mkdir -p "$HOME/.local/bin"
curl -fsSL -o "$HOME/.local/bin/cloudflared" \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x "$HOME/.local/bin/cloudflared"
export PATH="$HOME/.local/bin:$PATH"   # garanta isso no seu shell
cloudflared --version
```

(Para arm64, troque `amd64` por `arm64` na URL.)

### 2. Subir a aplicacao local

```bash
make setup    # cria o .env (cole o CONTAINER_CONFIG do GTM)
make start
make health   # os dois /healthy devem retornar 200
```

### 3. Abrir o tunel do PREVIEW server (porta 8081)

```bash
cloudflared tunnel --url http://localhost:8081
```

Copie a URL `https://<algo>.trycloudflare.com` que aparecer. Deixe esse
processo rodando (abra um terminal dedicado ou rode em background com `nohup`).

### 4. Injetar a URL do preview no tagging server

O tagging server precisa saber a URL HTTPS do preview via `PREVIEW_SERVER_URL`.
Adicione/atualize no `.env`:

```bash
PREVIEW_SERVER_URL=https://<url-do-tunel-preview>.trycloudflare.com
```

O `docker-compose.yml` ja le essa variavel. Recrie o tagging server:

```bash
make start    # recria o tagging com a nova variavel
make health   # confirme 200 novamente
```

> Sem `PREVIEW_SERVER_URL` (ou com URL nao-HTTPS) o tagging server sobe mas o
> modo preview do GTM nao funciona. Uma URL HTTP local como `http://preview:8080`
> e rejeitada com "Invalid preview server URL".

### 5. Abrir o tunel do TAGGING server (porta 8080)

```bash
cloudflared tunnel --url http://localhost:8080
```

Copie a URL — **esta e a URL que vai no GTM** como "URL do container servidor".

### 6. Configurar o GTM e abrir o Preview

1. Em https://tagmanager.google.com, abra seu container **Servidor**.
2. **Admin > Configuracoes do container**.
3. Em **URL do container servidor**, cole a URL do tunel do **tagging** (passo 5).
4. **Salvar**.
5. Clique em **Visualizar (Preview)** no canto superior direito.
6. A interface **Tag Assistant** abre dentro do GTM e deve mostrar "Connected".

Para gerar trafego e ver eventos na interface, em outra aba:

```bash
curl "https://<url-do-tunel-tagging>.trycloudflare.com/g/collect?v=2&tid=G-XXXXXXXXXX&cid=555.777&en=poc_test&_dbg=1"
```

O evento `poc_test` deve aparecer no Tag Assistant.

### Encerrar os tuneis

```bash
pkill cloudflared
```

### Avisos importantes

- As URLs `trycloudflare.com` sao **temporarias** e mudam a cada reinicio do
  cloudflared. Ao gerar novas URLs, atualize o `PREVIEW_SERVER_URL` no `.env`
  (passo 4) e a URL do container no GTM (passo 6).
- Enquanto os tuneis estiverem ativos, **qualquer pessoa com a URL alcanca seus
  servidores locais**. Aceitavel para PoC; nunca use tuneis efemeros assim em
  producao.
- A raiz das URLs (`/`) retorna 400/404 de proposito — o SSGTM e um endpoint de
  coleta, nao um site. Use `/healthy` para checar se esta no ar.

## Proximos passos (depois da PoC)

- **Enriquecer eventos com BigQuery**: como o datalake da empresa esta no
  BigQuery (GCP), o SSGTM pode consultar o BQ dentro de uma tag/variavel
  antes de enviar o evento. Isso exige uma service account com o papel
  **BigQuery Data Editor** e as variaveis GOOGLE_APPLICATION_CREDENTIALS /
  GOOGLE_CLOUD_PROJECT (ver manual de setup da Google).
- **Deploy real**: Cloud Run no GCP e o caminho recomendado (mesma cloud do
  datalake, provisionamento automatico, escalavel).
- **Dominio first-party**: subdominio tipo metrics.suaempresa.com.
- **Consent Mode / LGPD** antes de ir a producao.
