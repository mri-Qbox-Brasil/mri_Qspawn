# mri_Qspawn

Sistema de seleção de spawn moderno para Qbox Framework com interface NUI baseada em React, shadcn/ui e Vite.

## Características

- ✨ Interface moderna e responsiva com shadcn/ui e React
- 🗺️ Visualização aérea do mapa durante seleção
- 🎥 Animação de zoom suave da câmera até o local de spawn
- 🎨 Design elegante similar ao GTA V
- 🔄 Integração completa com qbx_spawn (usa todas as funções originais)
- ⚡ Performance otimizada com Vite

## Instalação

1. Coloque a pasta `mri_Qspawn` na sua pasta `resources`

2. **IMPORTANTE**: Entre na pasta `html` para instalar as dependências:
   ```bash
   cd html
   npm install
   ```

3. Compile o frontend:
   ```bash
   npm run build
   ```
   Isso criará a pasta `dist/` com os arquivos compilados.

4. Adicione ao seu `server.cfg`:
   ```
   ensure mri_Qspawn
   ```

5. **IMPORTANTE**: Certifique-se de que o `qbx_spawn` também está no seu `server.cfg`, pois este recurso usa as mesmas funções do servidor.

## Configuração

Edite o arquivo `config/client.lua` para personalizar:

```lua
return {
    spawns = {
        {
            label = 'Police Department',
            coords = vec4(441.4, -981.9, 30.7, 90.0),
            icon = 'shield',
            description = 'Start at police department'
        },
        -- Adicione mais spawns aqui
    },
    clouds = false, -- Enable clouds load in with wake up animation
    aerialViewHeight = 1000.0, -- Altura da câmera para visualização aérea
    zoomDuration = 3000, -- Duração do zoom até o jogador em ms
}
```

### Ícones Disponíveis

- `shield` - Escudo (para delegacias)
- `leaf` - Folha (para cidades/povoados)
- `umbrella` - Guarda-sol (para praias)
- `bed` - Cama (para motéis)
- `home` - Casa (para propriedades)
- `map-pin` - Marcador de mapa (padrão)

## Como Funciona

1. Quando um jogador precisa escolher um local de spawn, a interface NUI abre automaticamente
2. A câmera posiciona-se em uma vista aérea do mapa
3. O jogador pode navegar pela lista de spawns usando as setas (↑/↓) ou o mouse
4. Ao selecionar um spawn (ENTER ou clique):
   - A câmera faz zoom suave até o local selecionado
   - Após o zoom, o jogador é spawnado no local escolhido
   - A interface fecha automaticamente

## Estrutura

```
mri_Qspawn/
├── client/
│   ├── main.lua          # Lógica principal do cliente
│   └── camera.lua        # (Vazio - lógica em main.lua)
├── server/
│   └── main.lua          # Callbacks do servidor (usando funções do qbx_spawn)
├── html/
│   ├── src/
│   │   ├── App.tsx       # Componente principal React
│   │   ├── components/
│   │   │   └── ui/       # Componentes shadcn/ui
│   │   └── lib/
│   │       └── utils.ts  # Utilitários
│   ├── dist/             # Arquivos compilados (gerados após build)
│   └── package.json      # Dependências do frontend
├── config/
│   ├── client.lua        # Configurações do cliente
│   └── server.lua        # Configurações do servidor
├── locales/
│   └── pt.json           # Traduções
└── fxmanifest.lua        # Manifesto do recurso
```

## Desenvolvimento

Para desenvolver/modificar a interface:

1. Entre na pasta `html`:
   ```bash
   cd html
   ```

2. Instale as dependências (se ainda não instalou):
   ```bash
   npm install
   ```

3. Inicie o servidor de desenvolvimento:
   ```bash
   npm run dev
   ```
   Isso iniciará um servidor Vite na porta 5173 (não será usado pelo FiveM, apenas para desenvolvimento).

4. Para compilar para produção:
   ```bash
   npm run build
   ```

## Compatibilidade

Este recurso é totalmente compatível com o `qbx_spawn` original e usa exatamente as mesmas funções do servidor. Apenas a interface NUI foi substituída por uma versão moderna.

## Dependências

- `qbx_core` - Framework principal
- `ox_lib` - Biblioteca utilitária
- `oxmysql` - Gerenciamento de banco de dados
- `qbx_spawn` (opcional mas recomendado) - Para compatibilidade completa

## Licença

Este recurso é baseado no qbx_spawn mas com interface NUI completamente reescrita.

