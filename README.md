# mri_Qspawn — Manual

Sistema de spawn com NUI cinemática em 1ª pessoa. Plug-and-play em servidores QBox/QBCore.

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
| `ox_lib` | Sim | Callbacks, locale, /uiconfig |
| `oxmysql` | Sim | Configurações e locais de spawn (tabelas próprias), `last_location` e casas |
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
3. **Remova ou desabilite o `qbx_spawn`** — os dois recursos registram os mesmos callbacks (`qbx_spawn:server:getLastLocation`, `qbx_spawn:server:getHouses`, `qbx_spawn:server:alreadySpawned`) e o mesmo evento `qbx_spawn:server:spawn`, então não podem rodar juntos. O `fxmanifest.lua` declara `provide 'qbx_spawn'` para assumir essa identidade.

---

## Permissões (ACE)

O painel admin e as operações de CRUD de spawns são protegidas por ACE. Adicione no `server.cfg`:

```
add_ace group.admin mri_Qspawn.admin allow
```

Qualquer grupo ou identifier pode ser usado no lugar de `group.admin`. O gate interno verifica `mri_Qspawn.admin` **ou** o ACE `command` como fallback (cobre console e superadmin).

---

## Spawns — gerenciamento

Os locais de spawn ficam no banco, na tabela `mri_qspawn_locations`, que o resource cria sozinho na primeira subida. O painel admin grava direto nela, sem restart, e atualizar o resource não mexe nos locais cadastrados.

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
| `label` | string | Sim | Nome exibido na UI |
| `coords` | objeto `{x,y,z,w}` | Sim | Coordenadas e heading (`w`) do ponto de spawn |
| `icon` | string | Não | Nome do ícone Lucide (kebab-case). Padrão: `map-pin` |
| `color` | string hex | Não | Cor do ponto do spawn na seleção e do ícone no painel admin. Se omitido, segue a cor de destaque da suíte (`mri:color`) |
| `description` | string | Não | Anotação exibida no painel admin (`/adminspawn`) |

### Locais iniciais

Na primeira subida, a tabela recebe os locais de `data/spawns.default.json`. Isso acontece uma vez só: depois, os locais se gerenciam pelo painel.

### Vindo de uma versão com `data/spawns.json` e `data/config.json`

Na primeira subida da versão com banco, o resource importa sozinho o que estiver nesses arquivos: os locais vão para `mri_qspawn_locations` (na mesma ordem) e, do config, só o que difere do padrão vai para `mri_qspawn_settings`. A importação roda uma vez só. Depois disso os dois arquivos não são mais lidos e podem ser apagados. Quem atualiza substituindo a pasta precisa manter esses dois arquivos na primeira subida para a importação acontecer.

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

Todas as alterações são salvas imediatamente no banco e aplicadas na próxima abertura da tela de spawn, sem restart.

### Aba "Configurações"

Permite editar os parâmetros de comportamento da UI e da câmera em runtime. As alterações são aplicadas instantaneamente para todos os clientes conectados via broadcast, sem restart.

> O painel também é acessível como plugin do `mri_Qadmin` (se instalado), aparecendo na aba "Spawns" do painel administrativo central.

---

## Configurações de comportamento

Os valores padrão ficam em `data/config.default.json`, que vem com o resource. O que o admin muda na aba "Configurações" do painel vai para o banco (tabela `mri_qspawn_settings`), só o que difere do padrão, e é aplicado por cima dele. Assim, uma atualização traz os campos novos sozinha e não apaga nada que foi ajustado. Não edite o `config.default.json` para personalizar: ele é sobrescrito a cada atualização. Use o painel.

O exemplo abaixo é o `data/config.default.json`:

```json
{
  "debug": false,
  "selectOnFirstSpawn": false,

  "presence": { "eyeHeight": 1.6, "fov": 50.0, "sway": 1.0, "pitch": 0.0 },
  "blink": { "out": 90, "in": 150, "stream": 1500 },
  "confirm": { "fade": 500 },
  "emerge": {
    "settle": 900, "duration": 1500, "distance": 4.0,
    "height": 0.6, "pitch": -3.0, "blend": 800
  },

  "sound": { "enabled": true },
  "letterbox": { "enabled": false, "size": 11.0 },
  "postfx": { "dof": false, "grain": true, "vignette": true },
  "arrival": { "enabled": true }
}
```

### Geral

| Campo | Tipo | Descrição |
|---|---|---|
| `debug` | bool | Ativa logs de diagnóstico no console F8 (fluxo open/close, timeouts) |
| `selectOnFirstSpawn` | bool | Quando `true`, a seleção aparece só no primeiro spawn do personagem desde que o servidor subiu; nos seguintes ele nasce direto na última localização (dentro do imóvel, se deslogou num). O controle fica em memória e zera ao reiniciar o `mri_Qspawn`. Quando `false` (padrão), a seleção aparece sempre |

### Câmera

O seletor não usa câmera aérea: o jogador **está** no local, em primeira pessoa.
Trocar de spawn é um "piscar" (fade rápido, reposiciona, volta), e confirmar faz
a câmera recuar dos olhos para a terceira pessoa antes de devolver o controle.

| Bloco | Campo | Tipo | Descrição |
|---|---|---|---|
| `presence` | `eyeHeight` | m | Altura da câmera acima do chão (olhos do personagem) |
| | `fov` | graus | Campo de visão durante a seleção |
| | `sway` | mult. | Intensidade do balanço idle (respiração). `0` deixa a câmera estática |
| | `pitch` | graus | Inclinação vertical base |
| `blink` | `out` | ms | Fade-out ao trocar de spawn |
| | `in` | ms | Fade-in depois de reposicionar |
| | `stream` | ms | Tempo máximo esperando o cenário carregar antes de revelar |
| `confirm` | `fade` | ms | Fade usado quando o spawn cai dentro de casa/apartamento (o housing assume a câmera) |
| `emerge` | `settle` | ms | Espera após o spawn antes de devolver o controle |
| | `duration` | ms | Duração do recuo da câmera (1ª → 3ª pessoa) |
| | `distance` | m | Distância final da câmera ao personagem |
| | `height` | m | Altura final acima da linha dos olhos |
| | `pitch` | graus | Inclinação final |
| | `blend` | ms | Transição de volta para a câmera do jogo |

### Chegada

Ao nascer, o personagem se materializa e um sonar na cor da suíte (`mri:color`) sai dos pés dele.
Primeiro a energia se junta nos pés (anéis encolhendo e uma luz crescendo); então ele estoura:
uma onda principal com som, clarão e efeito de tela, e outras mais fracas acompanhando logo atrás.
As ondas saem rápido e desaceleram, com anel no chão e ecos atrás, uma parede de luz baixa e
luzes na frente que iluminam o que a onda atravessa. Pessoas e veículos
alcançados viram "contatos" (pulsos pequenos e curtos no chão embaixo deles e um marcador gira em cima), e
os objetos ganham um contorno em holograma quando a onda principal chega, com o brilho subindo a
cada onda e caindo aos poucos. O contorno não é usado em pessoas
nem veículos: o native (`SetEntityDrawOutline`) derruba o jogo nesses casos. Vale para o "nascimento" depois da
seleção e para o spawn direto do `selectOnFirstSpawn`; dentro de imóvel não roda (o housing
assume a câmera).

| Campo | Tipo | Descrição |
|---|---|---|
| `enabled` | bool | Liga o efeito. Desligado, o personagem só aparece |

O efeito em si (tempos, raio, som, cores e intensidade) é fixo no `client/arrival.lua`: não é configuração.


### Apresentação

| Bloco | Campo | Tipo | Descrição |
|---|---|---|---|
| `sound` | `enabled` | bool | Sons de UI (frontend nativo do GTA, sem asset) |
| `letterbox` | `enabled` | bool | Barras cinematográficas na tela de seleção |
| | `size` | % | Altura de cada barra, em porcentagem da tela |
| `postfx` | `dof` | bool | Profundidade de campo (desfoca o fundo) |
| | `grain` | bool | Granulação de filme |
| | `vignette` | bool | Escurecimento nas bordas |

---

## Cor de destaque

A cor de destaque (botões, bordas e elementos interativos da UI) é resolvida via convar global:

```
setr mri:color "#00E699"
```

- Se a convar estiver definida e for um hex válido (`#RRGGBB` ou `#RRGGBBAA`), ela é usada. O alpha é aceito mas ignorado no theming.
- Caso contrário, o padrão é `#00E699` (tema mri-ui-kit).
- A convar é compartilhada com outros recursos da suite MRI — definir uma vez aplica em todos.
- Alterações em runtime (via `setr` ou outro recurso que chame `SetConvar`) são propagadas imediatamente para todos os clientes sem restart.

Há também `mri:backgroundColor`, opcional, que tinge o fundo da UI. Segue as
mesmas regras; sem ela, o fundo fica no padrão do tema.

---

## Ícones

Os ícones vêm da biblioteca [Lucide](https://lucide.dev/icons) e são especificados em kebab-case: `shield`, `map-pin`, `tree-pine`, `building`, `home`, `bed`, `leaf`, etc.

Para usar um ícone em um spawn, defina o campo `icon` no formulário do painel admin:

```json
{ "label": "Floresta", "icon": "tree-pine", "color": "#4ADE80", ... }
```

A UI carrega o Lucide via UMD em runtime, então qualquer ícone do catálogo funciona sem necessidade de rebuild ou modificação de arquivos.

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
│   └── main.lua          — fluxo principal: NUI, câmera cinemática, fades, eventos de spawn
├── server/
│   ├── storage.lua       : tabelas no banco, importação única dos arquivos antigos
│   ├── config.lua        : padrão + ajustes do banco, broadcast de mudanças
│   ├── spawns.lua        : CRUD dos locais no banco, callbacks de admin
│   └── main.lua          — last_location, casas, integração mri_Qadmin, selectOnFirstSpawn
├── html/
│   ├── index.html        — UI de seleção de spawn e painel admin (build React)
│   └── assets/           — JS e CSS compilados
├── data/
│   ├── spawns.default.json : locais da primeira instalação
│   └── config.default.json : valores padrão das configurações
├── locales/
│   ├── en.json
│   └── pt-br.json
└── fxmanifest.lua
```
