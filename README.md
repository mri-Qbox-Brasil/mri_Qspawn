# mri_Qspawn

Sistema de spawn com NUI cinemática + markers 3D no mundo. Plug-and-play em servidores QBox/QBCore.

## Instalação

1. Coloque a pasta em `resources/`.
2. Build da UI:
   ```sh
   cd web
   npm install
   npm run build
   ```
3. `ensure mri_Qspawn` no `server.cfg`. Remova/desabilite o `qbx_spawn` original — os dois registram os mesmos callbacks e não podem rodar juntos.

## Entrypoints

- `exports.mri_Qspawn:chooseSpawn(citizenid)` — chamado pelo qbx_core multichar quando o jogador clica "Play".
- Evento legacy `qb-spawn:client:setupSpawns` — compat com o fluxo antigo do qb-spawn.

## Painel admin (`/adminspawn`)

CRUD de spawns em runtime — adiciona, edita, remove, e usa "minha posição" pra preencher coords. Persistido em [data/spawns.json](data/spawns.json).

Permissão via Ace: adicione no `server.cfg`:

```
add_ace group.admin mri_Qspawn.admin allow
```

(Ou qualquer grupo/identifier — o callback `mri_Qspawn:server:isAdmin` checa `mri_Qspawn.admin` ou `command` como fallback.)

O `data/spawns.json` é a fonte da verdade — se você quer fazer seed inicial, edite o JSON e dê restart. O config Lua não tem mais a tabela `spawns`.

## Cor de destaque

Resolvida em [config/client.lua](config/client.lua) via `accentColor = GetConvar('mri:color', '#00E699')`:

- **Convar global** `setr mri:color "#hex"` — compartilhada com a suite MRI; se definida, ganha.
- **Default** `#00E699` (cor do tema mri-ui-kit) — usado se a convar não estiver setada.

Aceita `#RRGGBB` ou `#RRGGBBAA` (alpha é ignorado pra theming HSL — alphas dos shadows ficam fixos no CSS).

## Configuração

Tudo fica em `config/client.lua`:

```lua
spawns = {
    {
        label = 'MRPD',
        coords = vec4(411.63, -966.19, 28.47, 226.55),
        icon  = 'shield',     -- nome de https://lucide.dev/icons
        color = '#60A5FA',    -- opcional; sem isso usa defaultSpawnIconColor
        description = 'Estação de polícia central.',
    },
    -- ...
},

defaultSpawnIconColor = '#a0ff73', -- usado quando `color` não é definido no spawn

cinematicDuration      = 6000, -- duração do shot cinemático no spawn (ms)
zoomDuration           = 3000, -- pan da câmera ao confirmar (ms)
transitionFadeDuration = 250,  -- fade entre spawns ao trocar de seleção (ms)
```

## Adicionar um ícone novo

Os ícones vêm do [Lucide](https://lucide.dev/icons) (kebab-case: `shield`, `map-pin`, `tree-pine`, etc.).

Basta editar `config/client.lua`:

```lua
{ label = 'Floresta', icon = 'tree-pine', color = '#4ADE80', ... }
```

Sem build, sem imports — a UI carrega o Lucide UMD via CDN (em [`web/index.html`](web/index.html)) e renderiza qualquer iconKey via `data-lucide` em runtime. O marker 3D no mundo (`web/marker/`) só renderiza texto + cor, então também não precisa do ícone lá.

## Estrutura

- `client/main.lua` — fluxo principal: NUI, câmera cinemática, fades, eventos de spawn.
- `client/waypoints.lua` — markers 3D via DUI + DrawTexturedPoly.
- `web/src/` — UI React (lista de spawns à direita).
- `web/marker/` — página HTML standalone que vira textura DUI dos markers no mundo.
- `config/client.lua` — locais, cores, durações.
- `server/main.lua` — callbacks de last_location e houses.
- `locales/` — traduções.

## Dependências

- `qbx_core` (framework)
- `ox_lib` (DUI helper, callbacks, locale)
- `oxmysql`
- `mri_Qmultichar` (opcional) — se presente, o jogador é movido pro bucket 0 ao spawnar.
