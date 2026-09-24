# PoC — Server-Side Google Tag Manager (SSGTM)

Objetivo: subir um servidor de tags do GTM localmente e validar o fluxo
ponta a ponta usando GA4 (o caso mais simples de validar).

## Como funciona

O SSGTM é um servidor Node.js distribuído pela Google como imagem Docker.
A mesma imagem roda em dois papéis:

- **preview server** — serve o modo debug/preview do GTM (1 instância).
- **tagging server (SST)** — ponto de entrada real dos eventos; recebe as
  requisições do navegador e dispara as tags (ex.: GA4).

Além disso, a PoC sobe um **Firestore Emulator** local para enriquecer eventos
(ver a seção "Enriquecimento de eventos com Firestore"):

- **firestore (emulador)** — banco NoSQL local; o tagging server le documentos
  aqui (ex.: `users/{cid}`) e anexa dados ao evento antes de dispara-lo.

Fluxo da PoC:

```
navegador / curl  ->  tagging server (localhost:8080)  ->  GA4 (DebugView)
                          |         |
                          |         +-> firestore emulator (enriquecimento)
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

### Atalho: `make tunnels` (recomendado)

Se o `cloudflared` ja estiver instalado, o Makefile automatiza os dois tuneis
e ja grava as URLs no `.env`:

```bash
make tunnels          # sobe os 2 tuneis, espera conectar e grava as URLs no .env
make tunnels-status   # mostra se estao no ar e testa as URLs do .env
make tunnels-stop     # encerra os tuneis
```

Depois de `make tunnels` com sucesso:

```bash
make start            # recria o tagging com a nova PREVIEW_SERVER_URL
# cole a TAGGING_SERVER_URL (impressa pelo comando) no GTM como
# "URL do container servidor" e abra o modo Preview
```

> Requer resolucao de DNS de saida (o cloudflared resolve `*.argotunnel.com` e
> conecta na porta 7844). Se o ambiente bloquear isso, o `make tunnels` falha
> com um diagnostico claro e **nao** altera o `.env`. Nesse caso, rode num
> ambiente com internet plena. Para so validar o enriquecimento Firestore voce
> nao precisa de tunel — use `make event-purchase ... HOST=http://localhost:8080`.
>
> **DNS via UDP bloqueado?** Alguns ambientes bloqueiam DNS na porta 53/UDP (o
> precheck do cloudflared faz lookup SRV via UDP e falha com `i/o timeout` /
> `hard_fail`). O `make tunnels` ja contorna isso definindo
> `RES_OPTIONS=use-vc`, que forca o resolver a usar **DNS via TCP**. Se ainda
> assim falhar, confirme que a saida TCP para a borda da Cloudflare esta liberada:
> `dig +tcp SRV _v2-origintunneld._tcp.argotunnel.com` deve responder, e a porta
> 7844/TCP do IP retornado deve ser alcancavel.

O passo a passo manual abaixo faz exatamente o que o `make tunnels` automatiza,
e serve de referencia caso queira controlar cada etapa.

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

## Enriquecimento de eventos com Firestore (emulador local)

O que e o Firestore: um banco NoSQL de documentos do Google Cloud, otimizado
para **leitura por chave com baixa latencia**. E o componente ideal para
enriquecer um evento em tempo real no meio do request — diferente do BigQuery,
que e um data warehouse para analytics em lote (latencia de segundos).

Padrao de uso: dado o `cid` (client id) que chega no evento, o tagging server
busca `users/{cid}` no Firestore e anexa campos (ex.: `segment`, `customer_ltv`,
`plan`) ao evento antes de dispara-lo para GA4/Ads.

Nesta PoC usamos o **Firestore Emulator** — 100% local, sem GCP, sem
credenciais, sem custo. Fica no `docker-compose.yml` como o servico `firestore`.

```
navegador / curl -> tagging server -> [Firestore.read users/{cid}] -> GA4
                          |                     |
                          |               firestore (emulator, local)
                          +-> preview server (debug)
```

### Como funciona na PoC

O `docker-compose.yml` sobe o emulador e injeta duas env vars no tagging server:

- `GOOGLE_CLOUD_PROJECT` — id do projeto (default `poc-sgtm`). Deve casar com o
  `FIRESTORE_PROJECT_ID` do emulador.
- `FIRESTORE_EMULATOR_HOST=firestore:8080` — faz o SDK do Firestore (usado pela
  sandbox do GTM em `Firestore.read`) apontar para o emulador local em vez do
  Firestore de producao.

> Viabilidade verificada nesta PoC: a imagem oficial `gtm-cloud-image` respeita
> `FIRESTORE_EMULATOR_HOST` e le documentos do emulador (HTTP 200) de dentro do
> container. Nenhuma credencial e necessaria localmente.

### 1. Subir a stack e popular o emulador

```bash
make start          # sobe preview + tagging + firestore
make health         # os tres devem responder 200
make seed           # insere os 30 usuarios de users.json na colecao users
```

> O emulador nao persiste dados entre reinicios. Rode `make seed` sempre que
> subir a stack (apos `make start`) para ter os usuarios no Firestore.

O `make seed` le o arquivo **`users.json`** (30 usuarios aleatorios) e insere
cada um na colecao `users`, via `seed-users.sh`. Cada documento usa o `id`
(uuid) do usuario como ID do documento e tem a estrutura:

```json
{
  "id": "115a0836-a249-43b3-b363-33795e7f36ca",
  "name": "Vera Rocha",
  "email": "vera.rocha58@exemplo.com",
  "device": {
    "id": "e6f5f1b2-63a2-4647-9154-e9f6251bcd02",
    "family": "android",
    "version": 12.6
  }
}
```

No Firestore, `name`/`email`/`id` viram `stringValue`, o `device` vira um
`mapValue` aninhado e `device.version` um `doubleValue` (float).

Para regenerar o `users.json` com 30 novos usuarios aleatorios, rode o gerador
(veja o comando python em `users.json` — os UUIDs mudam a cada geracao).

Comandos uteis:

```bash
make firestore-list                # lista os IDs dos documentos em users/
make firestore-get CID=<uuid>      # mostra um documento especifico
```

> Alem do `make seed`, existe o `make seed-sample`: insere 3 usuarios simples
> (`555.777`, `111.222`, `abc.123`) alinhados ao `CID` padrao do
> `make event-purchase`, uteis para testar o enriquecimento de ponta a ponta
> sem precisar copiar um uuid.

### 2. Criar a Variable Template no GTM

O SSGTM tem um tipo de variavel nativo para ler do Firestore (nao precisa de
template externo para leitura por chave):


1. No container **Servidor**, va em **Variables > New > Firestore Lookup**
   (nome pode aparecer como "Firestore" na lista de tipos de variavel).
2. Configure:
   - **Document Path**: `users/{{cid}}` — onde `{{cid}}` e uma variavel que
     extrai o client id do evento (ex.: uma Query Parameter variable lendo `cid`,
     ou um Event Data lendo `client_id`).
   - **Key Path (field)**: o campo que voce quer, ex.: `customer_ltv`.
   - **Project ID**: `poc-sgtm` (o mesmo do `GOOGLE_CLOUD_PROJECT`).
3. Salve como, por exemplo, **`fs.customer_ltv`**.

> Leitura por atributo vs documento inteiro: a variavel nativa do Firestore
> retorna **um campo** do documento. Se precisar do documento inteiro e fazer
> parse de varios campos, existem templates da comunidade (ex.: "Artemis" do
> google-marketing-solutions) — fora do escopo desta PoC.

### 3. Usar o valor enriquecido numa tag

Na sua tag GA4 (ou Ads), referencie a variavel:

- Adicione um parametro do evento, ex.: `customer_ltv` = `{{fs.customer_ltv}}`.
- Agora o valor lido do Firestore viaja junto com o evento para o GA4.

### 4. Validar end-to-end

```bash
# garante os dados no emulador
make seed

# dispara um evento para o cid 555.777 (usuario "vip", ltv 4820.50)
make event-purchase CID=555.777
```

No **Tag Assistant** (modo Preview do GTM, ver secao cloudflared), abra o
evento e confira:

- a variavel `fs.customer_ltv` resolveu para `4820.5` (valor vindo do Firestore);
- a tag GA4 enviou o parametro enriquecido.

Compare com um usuario diferente para ver o enriquecimento mudando:

```bash
make event-purchase CID=111.222   # usuario "regular", ltv 320.00
make event-purchase CID=999.999   # cid sem documento -> variavel resolve vazia
```

> Sem o header de preview (`make set-preview HEADER=...`) o evento ainda e
> processado (HTTP 200) e o enriquecimento acontece, mas nao aparece no Tag
> Assistant. Ver a secao do header de preview acima.

### Limitacoes do emulador (PoC)

- **Dados nao persistem**: ao rodar `make stop`/`make clean` o emulador zera.
  Rode `make seed` de novo apos subir. (Persistencia exigiria montar um volume
  e habilitar export/import do emulador — fora do escopo da PoC.)
- **Sem credenciais/regras de seguranca**: o emulador aceita qualquer leitura;
  em producao o Firestore real exige service account e Security Rules.

## Proximos passos (depois da PoC)

- **Trocar o emulador pelo Firestore real**: em producao, remova
  `FIRESTORE_EMULATOR_HOST` e forneca credenciais via
  `GOOGLE_APPLICATION_CREDENTIALS` (service account com acesso de leitura ao
  Firestore) + `GOOGLE_CLOUD_PROJECT`. O template de variavel no GTM nao muda.
- **Popular o Firestore a partir do BigQuery**: o datalake (BQ) processa em
  lote e exporta agregados por usuario para o Firestore, que serve as leituras
  de baixa latencia no request. Esse e o papel de cada um: BQ = analytics em
  lote; Firestore = lookup em tempo real.
- **Deploy real**: Cloud Run no GCP e o caminho recomendado (mesma cloud do
  datalake, provisionamento automatico, escalavel).
- **Dominio first-party**: subdominio tipo metrics.suaempresa.com.
- **Consent Mode / LGPD** antes de ir a producao.
