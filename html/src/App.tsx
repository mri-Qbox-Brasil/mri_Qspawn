import { useState, useEffect, useCallback } from 'react'
import { Shield, Leaf, Umbrella, Bed, Home, MapPin, Building, ArrowRight, CheckCircle2 } from 'lucide-react'
import { cn } from './lib/utils'

declare function GetParentResourceName(): string

interface SpawnLocation {
  label: string
  coords: { x: number; y: number; z: number; w?: number }
  icon?: string
  description?: string
  propertyId?: string
  first_time?: boolean
}

// Configuração de cores vibrantes para cada tipo de ícone (estilo GTA V)
const iconConfig: Record<string, { icon: any; color: string; iconColor: string; glowColor: string }> = {
  shield: {
    icon: Shield,
    color: 'text-blue-400',
    iconColor: '#60A5FA', // blue-400
    glowColor: 'rgba(96, 165, 250, 0.3)'
  },
  leaf: {
    icon: Leaf,
    color: 'text-emerald-400',
    iconColor: '#34D399', // emerald-400
    glowColor: 'rgba(52, 211, 153, 0.3)'
  },
  umbrella: {
    icon: Umbrella,
    color: 'text-amber-400',
    iconColor: '#FBBF24', // amber-400
    glowColor: 'rgba(251, 191, 36, 0.3)'
  },
  bed: {
    icon: Bed,
    color: 'text-violet-400',
    iconColor: '#A78BFA', // violet-400
    glowColor: 'rgba(167, 139, 250, 0.3)'
  },
  home: {
    icon: Home,
    color: 'text-orange-400',
    iconColor: '#FB923C', // orange-400
    glowColor: 'rgba(251, 146, 60, 0.3)'
  },
  building: {
    icon: Building,
    color: 'text-cyan-400',
    iconColor: '#22D3EE', // cyan-400
    glowColor: 'rgba(34, 211, 238, 0.3)'
  },
  'map-pin': {
    icon: MapPin,
    color: 'text-rose-400',
    iconColor: '#FB7185', // rose-400
    glowColor: 'rgba(251, 113, 133, 0.3)'
  },
}

function App() {
  const [isOpen, setIsOpen] = useState(false)
  const [spawns, setSpawns] = useState<SpawnLocation[]>([])
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [isReadyToSpawn, setIsReadyToSpawn] = useState(false)
  const [hasAutoSelected, setHasAutoSelected] = useState(false)
  const [mapIcons, setMapIcons] = useState<Array<{ x: number, y: number, icon: string, label: string, iconColor: string }>>([])

  // Icon mapping com cores vibrantes
  const getIcon = (iconName?: string, size: string = 'w-6 h-6', isSelected: boolean = false) => {
    const config = iconConfig[iconName || 'map-pin'] || iconConfig['map-pin']
    const IconComponent = config.icon
    return (
      <IconComponent
        className={cn(size, config.color, 'transition-all duration-300', isSelected && 'drop-shadow-lg')}
        style={{
          filter: isSelected ? `drop-shadow(0 0 8px ${config.glowColor})` : 'none',
          color: config.iconColor
        }}
      />
    )
  }

  const handleConfirmSpawn = useCallback(async () => {
    if (!isReadyToSpawn) return

    try {
      const response = await fetch(`https://${GetParentResourceName()}/confirmSpawn`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({}),
      })

      const data = await response.json()
      if (data.success) {
        setIsReadyToSpawn(false)
        setIsOpen(false)
      }
    } catch (error) {
      console.error('Erro ao confirmar spawn:', error)
    }
  }, [isReadyToSpawn])

  const handleClose = useCallback(async () => {
    try {
      await fetch(`https://${GetParentResourceName()}/close`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ returnToMultichar: true }),
      })
      setIsOpen(false)
      setIsReadyToSpawn(false)
      setSelectedIndex(0)
    } catch (error) {
      console.error('Erro ao fechar:', error)
    }
  }, [])

  const loadSpawns = useCallback(async () => {
    try {
      const response = await fetch(`https://${GetParentResourceName()}/getSpawns`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({}),
      })

      const data = await response.json()
      console.log('[mri_Qspawn] Resposta do getSpawns:', data)

      if (data.success && data.spawns && Array.isArray(data.spawns) && data.spawns.length > 0) {
        console.log(`[mri_Qspawn] ${data.spawns.length} spawns carregados`)
        setSpawns(data.spawns)
        setSelectedIndex(0)
      } else {
        console.error('[mri_Qspawn] Nenhum spawn encontrado. Resposta:', JSON.stringify(data, null, 2))
        console.error('[mri_Qspawn] success:', data.success, 'spawns:', data.spawns, 'length:', data.spawns?.length)
      }
    } catch (error) {
      console.error('[mri_Qspawn] Erro ao carregar spawns:', error)
    }
  }, [])

  useEffect(() => {
    const handleMessage = (event: MessageEvent) => {
      const data = event.data
      console.log('[mri_Qspawn] Mensagem recebida:', data)

      if (data && data.action === 'open') {
        console.log('[mri_Qspawn] Ação: open. Spawns recebidos:', data.spawns)
        setIsOpen(true)
        setHasAutoSelected(false)
        if (data.spawns && Array.isArray(data.spawns) && data.spawns.length > 0) {
          console.log(`[mri_Qspawn] ${data.spawns.length} spawns recebidos via mensagem`)
          setSpawns(data.spawns)
          setSelectedIndex(0)
        } else {
          console.log('[mri_Qspawn] Nenhum spawn na mensagem, tentando carregar via callback')
          loadSpawns()
        }
      } else if (data && data.action === 'close') {
        setIsOpen(false)
        setSelectedIndex(0)
        setIsReadyToSpawn(false)
        setHasAutoSelected(false)
        setMapIcons([])
      } else if (data && data.action === 'updateMapIcon') {
        if (data.allIcons && Array.isArray(data.allIcons)) {
          // Atualizar todos os ícones de uma vez
          setMapIcons(data.allIcons)
        }
      }
    }

    window.addEventListener('message', handleMessage)

    return () => {
      window.removeEventListener('message', handleMessage)
    }
  }, [isOpen, loadSpawns])

  // Selecionar automaticamente o last_location quando spawns são carregados e UI está aberta
  useEffect(() => {
    if (isOpen && spawns.length > 0 && !hasAutoSelected && !isReadyToSpawn) {
      const timer = setTimeout(() => {
        handleSelectSpawn(0)
        setHasAutoSelected(true)
      }, 400)
      return () => clearTimeout(timer)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, spawns.length, hasAutoSelected])

  // Handle keyboard input para ESC e ENTER (separado para ter acesso aos estados atualizados)
  useEffect(() => {
    if (!isOpen) return

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        handleClose()
      } else if (event.key === 'Enter' && isReadyToSpawn) {
        event.preventDefault()
        handleConfirmSpawn()
      }
    }

    window.addEventListener('keydown', handleKeyDown)

    return () => {
      window.removeEventListener('keydown', handleKeyDown)
    }
  }, [isOpen, isReadyToSpawn, handleConfirmSpawn, handleClose])

  const handleSelectSpawn = useCallback(async (index: number) => {
    if (index < 0 || index >= spawns.length) return

    setSelectedIndex(index)
    try {
      const response = await fetch(`https://${GetParentResourceName()}/selectSpawn`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ index: index }), // Enviar índice 0-based, será convertido no Lua
      })

      const data = await response.json()
      if (data.success) {
        setIsReadyToSpawn(true)
      }
    } catch (error) {
      console.error('Erro ao selecionar spawn:', error)
    }
  }, [spawns.length])

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center pointer-events-none">
      {/* Background overlay mínimo */}
      <div className="absolute inset-0 bg-black/20 pointer-events-none" />

      {/* Conteúdo principal */}
      <div className="relative w-full h-full flex pointer-events-auto">
        {/* Título Spawn Selector - Centralizado no topo */}
        <div className="absolute top-6 left-1/2 -translate-x-1/2 z-10">
          <div className="flex items-center gap-2 text-white text-lg font-semibold">
            <MapPin className="w-5 h-5" />
            <span>SPAWN SELECTOR</span>
          </div>
        </div>

        {/* Todos os ícones React renderizados no mapa (sobreposto nas coordenadas 3D) */}
        {mapIcons.map((mapIcon, index) => (
          mapIcon && (
            <div
              key={index}
              className="fixed pointer-events-none z-50 flex flex-col items-center justify-center transition-all duration-75"
              style={{
                left: `${mapIcon.x * 100}%`,
                top: `${mapIcon.y * 100}%`,
                transform: 'translate(-50%, -50%)',
              }}
            >
              {/* Ícone React do menu - idêntico ao que aparece na lista */}
              <div className="flex flex-col items-center gap-2">
                {/* Ícone */}
                <div
                  style={{
                    color: `rgb(${mapIcon.iconColor})`,
                    filter: `drop-shadow(0 0 15px rgba(${mapIcon.iconColor}, 0.8))`,
                  }}
                  className="flex-shrink-0"
                >
                  {getIcon(mapIcon.icon, 'w-8 h-8', true)}
                </div>
                {/* Nome - SEM FUNDO, apenas texto */}
                <span
                  className="text-white font-semibold text-base whitespace-nowrap drop-shadow-lg"
                  style={{
                    textShadow: '2px 2px 4px rgba(0, 0, 0, 0.8), 0 0 8px rgba(0, 0, 0, 0.8)'
                  }}
                >
                  {mapIcon.label}
                </span>
              </div>
            </div>
          )
        ))}

        {/* Instruções de teclado - Centralizado embaixo */}
        <div className="absolute bottom-6 left-1/2 -translate-x-1/2 z-10 flex items-center gap-4">
          {isReadyToSpawn ? (
            <div
              onClick={handleConfirmSpawn}
              className="flex items-center gap-2 px-4 py-2 border border-emerald-500/40 rounded-lg cursor-pointer hover:bg-emerald-500/30 transition-all active:scale-95"
              style={{ backgroundColor: 'rgba(16, 185, 129, 0.2)' }}
            >
              <ArrowRight className="w-4 h-4 text-emerald-400" />
              <span className="text-emerald-300 font-medium text-sm">
                Pressione <span className="text-white font-bold px-1.5 py-0.5 rounded" style={{ backgroundColor: 'rgba(255, 255, 255, 0.2)' }}>ENTER</span> para spawnar
              </span>
            </div>
          ) : (
            <div className="flex items-center gap-2 px-3 py-1.5 border border-white/20 rounded-lg" style={{ backgroundColor: 'rgba(255, 255, 255, 0.1)' }}>
              <span className="text-white/70 font-medium text-sm">
                Pressione <span className="text-white font-bold px-1.5 py-0.5 rounded" style={{ backgroundColor: 'rgba(255, 255, 255, 0.2)' }}>E</span> para selecionar
              </span>
            </div>
          )}
          <div className="flex items-center gap-2 px-3 py-1.5 border border-white/20 rounded-lg" style={{ backgroundColor: 'rgba(255, 255, 255, 0.1)' }}>
            <span className="text-white/70 font-medium text-sm">
              Pressione <span className="text-white font-bold px-1.5 py-0.5 rounded" style={{ backgroundColor: 'rgba(255, 255, 255, 0.2)' }}>ESC</span> para voltar
            </span>
          </div>
        </div>

        {/* Lista de spawns à direita - SEM FUNDO, estilo minimalista como GTA V */}
        <div className="absolute top-1/2 right-8 -translate-y-1/2 z-10 w-[420px] pointer-events-auto">
          <div className="space-y-2 max-h-[75vh] overflow-y-auto pr-3 custom-scrollbar">
            {spawns.length > 0 ? (
              spawns.map((spawn, index) => {
                const isSelected = selectedIndex === index
                const displayLabel = spawn.label === 'last_location' ? 'Last Location' : spawn.label

                return (
                  <button
                    key={index}
                    onClick={() => {
                      handleSelectSpawn(index)
                    }}
                    className="w-full flex items-start gap-3 py-3 px-2 rounded-lg transition-all duration-200 text-left cursor-pointer group relative spawn-item"
                    style={{
                      backgroundColor: isSelected ? 'rgba(255, 255, 255, 0.05)' : 'transparent'
                    }}
                    onMouseEnter={(e) => {
                      if (!isSelected) {
                        setSelectedIndex(index)
                        e.currentTarget.style.backgroundColor = 'rgba(255, 255, 255, 0.02)'
                      }
                    }}
                    onMouseLeave={(e) => {
                      if (!isSelected) {
                        e.currentTarget.style.backgroundColor = 'transparent'
                      }
                    }}
                  >

                    {/* Ícone colorido antes do nome */}
                    <div className={cn(
                      "flex-shrink-0 mt-0.5 transition-all duration-200",
                      isSelected ? "scale-110" : "scale-100"
                    )}>
                      {getIcon(spawn.icon, 'w-5 h-5', isSelected)}
                    </div>

                    {/* Texto - nome e descrição */}
                    <div className="flex-1 min-w-0">
                      {/* Nome do spawn */}
                      <div className="flex items-center gap-2 flex-wrap">
                        <p className={cn(
                          "font-semibold text-lg leading-tight transition-all duration-200",
                          isSelected ? "text-white" : "text-white/80 group-hover:text-white/90"
                        )}>
                          {displayLabel}
                        </p>

                        {/* Indicador de seleção */}
                        {isSelected && (
                          <div className="ml-auto flex-shrink-0">
                            <CheckCircle2 className="w-4 h-4 text-white/70" />
                          </div>
                        )}
                      </div>

                      {/* Descrição abaixo */}
                      <p className={cn(
                        "text-xs mt-0.5 leading-relaxed transition-colors duration-200",
                        isSelected ? "text-white/70" : "text-white/50 group-hover:text-white/60"
                      )}>
                        {spawn.description || `Start at ${displayLabel.toLowerCase()}`}
                      </p>
                    </div>
                  </button>
                )
              })
            ) : (
              <div className="text-center text-white/60 py-12">
                <div className="animate-spin w-6 h-6 border-2 border-white/20 border-t-white/60 rounded-full mx-auto mb-3" />
                <p className="text-sm">Carregando locais...</p>
              </div>
            )}
          </div>
        </div>


      </div>
    </div>
  )
}

export default App

