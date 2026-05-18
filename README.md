# mri_Qspawn — Manual

Sistema de spawn com NUI cinemática e markers 3D no mundo. Plug-and-play em servidores QBox/QBCore.

---

## Sumário

1. [Dependências](#dependências)
2. [Instalação](#instalação)
3. [Permissões (ACE)](#permissões-ace)
4. [Spawns — gerenciamento](#spawns--gerenciamento)
5. [Painel admin (`/adminspawn`)](#painel-admin-adminspawn)
6. [Configurações de comportamento](#configurações-de-comportamento)
7. [Cor de destaque](#cor-de-destaque)
8. [Ícones](#ícones)
9. [Integrações](#integrações)
10. [Entrypoints para outros recursos](#entrypoints-para-outros-recursos)
11. [Localização](#localização)
12. [Estrutura de arquivos](#estrutura-de-arquivos)

---

## Dependências

| Recurso | Obrigatório | Observação |
|---|---|---|
| `qbx_core` | Sim | Framework base |
| `ox_lib` | Sim | Callbacks, locale, DUI helper |
| `oxmysql` | Sim | Leitura de `last_location` e casas |
| `ps-housing` | Não | Spawn em propriedades e apartamentos |
| `mri_Qmultichar` | Não | Move o jogador para o bucket global ao spawnar |
| `mri_Qadmin` | Não | Registra o painel como plugin do painel admin MRI |

---

## Instalação

1. Copie a pasta `mri_Qspawn` para `resources/`.
2. Adicione ao `server.cfg`:
   ```
   ensure mri_Qspawn
   ```
3. **Remova ou desabilite o `qbx_spawn`** — os dois recursos registram os mesmos callbacks (`qbx_spawn:server:getLastLocation`, `qbx_spawn:server:getHouses`, `qbx_spawn:server:alreadySpawned`) e não podem rodar juntos.

---

## Permissões (ACE)

O painel admin e as operações de CRUD de spawns são protegidas por ACE. Adicione no `server.cfg`:

```
add_ace group.admin mri_Qspawn.admin allow
```

Qualquer grupo ou identifier pode ser usado no lugar de `group.admin`. O gate interno verifica `mri_Qspawn.admin` **ou** o ACE `command` como fallback (cobre console e superadmin).

---

## Spawns — gerenciamento

A lista de spawns fica em `data/spawns.json`. Esse arquivo é a fonte da verdade: alterações feitas via painel admin são persistidas aqui em tempo real, sem necessidade de restart.

### Formato de um spawn

```json
{
    "label": "MRPD",
    "coords": { "x": 411.63, "y": -966.19, "z": 28.47, "w": 226.55 },
    "icon": "shield",
    "color": "#60A5FA",
    "description": "Estação de polícia central."
}
```

| Campo | Tipo | Obrigatório | Descrição |
|---|---|---|---|
| `label` | string | Sim | Nome exibido na UI e nos markers 3D |
| `coords` | objeto `{x,y,z,w}` | Sim | Coordenadas e heading (`w`) do ponto de spawn |
| `icon` | string | Não | Nome do ícone Lucide (kebab-case). Padrão: `map-pin` |
| `color` | string hex | Não | Cor do ícone no marker 3D. Se omitido, usa `defaultSpawnIconColor` da configuração |
| `description` | string | Não | Texto exibido no card de seleção da UI |

### Seed manual

Para definir a lista inicial sem usar o painel, edite `data/spawns.json` diretamente e dê restart no recurso. As alterações são carregadas na inicialização.

---

## Painel admin (`/adminspawn`)

Interface de CRUD de spawns acessível em runtime. Requer a ACE `mri_Qspawn.admin` ou `command`.

### Abrir o painel

Execute o comando no chat:
```
/adminspawn
```

### Aba "Spawns"

- **Novo spawn** — abre o formulário em branco.
- **Editar** — preenche o formulário com os dados do spawn existente.
- **Usar minha posição** — preenche as coordenadas e o heading com a posição atual do personagem no mundo.
- **Apagar** — remove o spawn após confirmação. A operação é irreversível via UI.

Todas as alterações são salvas imediatamente em `data/spawns.json` e aplicadas na próxima abertura da tela de spawn, sem restart.

### Aba "Configurações"

Permite editar os parâmetros de comportamento da UI e da câmera em runtime. As alterações são aplicadas instantaneamente para todos os clientes conectados via broadcast, sem restart.

> O painel também é acessível como plugin do `mri_Qadmin` (se instalado), aparecendo na aba "Spawns" do painel administrativo central.

---

## Configurações de comportamento

As configurações ficam em `data/config.json` e podem ser editadas manualmente ou via aba "Configurações" do painel admin.

```json
{
  "debug": false,
  "defaultSpawnIconColor": "#FFFFFF",
  "transitionFadeDuration": 250,
  "cinematicDuration": 6000,
  "zoomDuration": 1800,
  "cinematicShot": {
    "startOffsetY": 200.0,
    "startOffsetZ": 400.0,
    "startFov": 65.0,
    "endOffsetY": 6.0,
    "endOffsetZ": 2.0,
    "endFov": 40.0
  },
  "spawnAnimations": [
    "WORLD_HUMAN_STAND_IMPATIENT",
    "WORLD_HUMAN_SMOKING",
    "WORLD_HUMAN_HANG_OUT_STREET",
    "WORLD_HUMAN_STAND_MOBILE",
    "WORLD_HUMAN_CLIPBOARD"
  ],
  "spawnAnimationDuration": 3000,
  "selectOnFirstSpawn": false
}
```

| Campo | Tipo | Descrição |
|---|---|---|
| `debug` | bool | Ativa logs de diagnóstico no console F8 (fluxo open/close, fallback timeout) |
| `defaultSpawnIconColor` | hex | Cor usada no marker 3D quando o spawn não define `color` próprio |
| `transitionFadeDuration` | ms | Duração do fade-out/in ao trocar de spawn na seleção |
| `cinematicDuration` | ms | Duração do shot cinemático aéreo ao abrir a tela de spawn |
| `zoomDuration` | ms | Duração do push-in de câmera após confirmar o spawn |
| `cinematicShot` | objeto | Offsets da câmera cinemática relativos ao ponto de spawn. `Y` = distância à frente, `Z` = altura, `Fov` = campo de visão |
| `spawnAnimations` | array de strings | Scenarios do GTA V sorteados aleatoriamente ao chegar no destino. Aceita qualquer `WORLD_HUMAN_*` válido |
| `spawnAnimationDuration` | ms | Tempo que o personagem fica na animação após spawnar |
| `selectOnFirstSpawn` | bool | Quando `true`, a `last_location` é auto-selecionada apenas no primeiro spawn do personagem na sessão. Quando `false` (padrão), sempre auto-seleciona |

### Comportamento do `cinematicShot`

A câmera começa em `startOffsetY` metros à frente do spawn e `startOffsetZ` metros de altura, e se aproxima até `endOffsetY` e `endOffsetZ` durante `cinematicDuration` ms. Pitch e yaw são calculados automaticamente para manter o personagem centralizado durante toda a aproximação.

---

## Cor de destaque

A cor de destaque (botões, bordas e elementos interativos da UI) é resolvida via convar global:

```
setr mri:color "#00E699"
```

- Se a convar estiver definida e for um hex válido (`#RRGGBB`), ela é usada.
- Caso contrário, o padrão é `#00E699` (tema mri-ui-kit).
- A convar é compartilhada com outros recursos da suite MRI — definir uma vez aplica em todos.
- Alterações em runtime (via `setr` ou outro recurso que chame `SetConvar`) são propagadas imediatamente para todos os clientes sem restart.

---

## Ícones

Os ícones vêm da biblioteca [Lucide](https://lucide.dev/icons) e são especificados em kebab-case: `shield`, `map-pin`, `tree-pine`, `building`, `home`, `bed`, `leaf`, etc.

Para usar um ícone em um spawn, defina o campo `icon` no `data/spawns.json` ou no formulário do painel admin:

```json
{ "label": "Floresta", "icon": "tree-pine", "color": "#4ADE80", ... }
```

A UI carrega o Lucide via UMD em runtime, então qualquer ícone do catálogo funciona sem necessidade de rebuild ou modificação de arquivos. O marker 3D no mundo exibe apenas texto e cor, não usa o ícone.

---

## Integrações

### ps-housing

Quando o jogador tem casas ou apartamentos cadastrados no `ps-housing`, eles aparecem automaticamente como opções de spawn. Ao selecionar uma propriedade, o evento `ps-housing:server:enterProperty` é disparado com o `property_id` correspondente.

### mri_Qmultichar

Se o recurso `mri_Qmultichar` estiver rodando no servidor, o jogador é movido automaticamente para o bucket global (`0`) ao completar o spawn, via evento `mri_Qmultichar:server:setBucket`.

### mri_Qadmin

Se o `mri_Qadmin` estiver instalado e iniciado, o `mri_Qspawn` se registra automaticamente como plugin com a aba "Spawns", acessível pelo painel administrativo central. O registro usa `exports['mri_Qadmin']:RegisterPlugin` e não requer configuração manual.

---

## Entrypoints para outros recursos

### Export `chooseSpawn`

Chamado pelo `qbx_core` multichar quando o jogador clica em "Play". Bloqueia até o jogador fechar a tela de spawn (necessário para que o `qbx_core` não destrua a câmera prematuramente).

```lua
exports.mri_Qspawn:chooseSpawn(citizenid)
```

### Evento legacy `qb-spawn:client:setupSpawns`

Mantém compatibilidade com o fluxo antigo do `qb-spawn`. Recebe `cData`, `new` (personagem novo) e `apps` (apartamentos disponíveis para novo personagem).

```lua
TriggerEvent('qb-spawn:client:setupSpawns', cData, new, apps)
```

Quando `new = true`, apenas os apartamentos passados em `apps` são exibidos como opções de spawn.

---

## Localização

As strings da UI são traduzidas via `ox_lib` locale. Os arquivos ficam em `locales/`:

- `en.json` — inglês
- `pt-br.json` — português do Brasil

O locale ativo é definido pela convar `ox:locale` no `server.cfg`:

```
setr ox:locale "pt-br"
```

Para adicionar um novo idioma, crie `locales/<codigo>.json` seguindo a estrutura dos arquivos existentes e reinicie o recurso.

---

## Estrutura de arquivos

```
mri_Qspawn/
├── client/
│   ├── main.lua          — fluxo principal: NUI, câmera cinemática, fades, eventos de spawn
│   └── waypoints.lua     — markers 3D via DUI + DrawTexturedPoly
├── server/
│   ├── config.lua        — leitura/escrita de data/config.json, broadcast de mudanças
│   ├── spawns.lua        — CRUD de data/spawns.json, callbacks de admin
│   └── main.lua          — last_location, casas, integração mri_Qadmin, selectOnFirstSpawn
├── html/
│   ├── index.html        — UI de seleção de spawn e painel admin (build React)
│   ├── assets/           — JS e CSS compilados
│   └── marker/           — página HTML standalone usada como textura DUI dos markers 3D
├── data/
│   ├── spawns.json       — lista de spawns (fonte da verdade, editável pelo painel admin)
│   └── config.json       — configurações de comportamento (editável pelo painel admin)
├── locales/
│   ├── en.json
│   └── pt-br.json
└── fxmanifest.lua
```
