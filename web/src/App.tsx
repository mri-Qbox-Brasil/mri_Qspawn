import { useState, useEffect, useCallback } from 'react'
import { Shield, Leaf, Umbrella, Bed, Home, MapPin, Building, ArrowRight, CheckCircle2 } from 'lucide-react'
import { cn } from './lib/utils'
import {
  MriButton,
  MriCard,
  MriBadge,
} from '@mriqbox/ui-kit'

import { fetchNui } from './utils/misc'

console.log('[mri_Qspawn:DEBUG] JS Bundle carregado (Top Level)')

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
  console.log('[mri_Qspawn:DEBUG] Componente App inicializando')
  const [isOpen, setIsOpen] = useState(false)
  const [spawns, setSpawns] = useState<SpawnLocation[]>([])
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [isReadyToSpawn, setIsReadyToSpawn] = useState(false)
  const [hasAutoSelected, setHasAutoSelected] = useState(false)
  const [mapIcons, setMapIcons] = useState<Array<{ x: number, y: number, icon: string, label: string, iconColor: string }>>([])
  const [title, setTitle] = useState('SPAWN SELECTOR')

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
      const data = await fetchNui('confirmSpawn')
      if (data.success) {
        setIsReadyToSpawn(false)
        setIsOpen(false)
      }
    } catch (error) {
      console.error('Erro ao confirmar spawn:', error)
    }
  }, [isReadyToSpawn, setIsReadyToSpawn, setIsOpen])

  const handleClose = useCallback(async () => {
    try {
      await fetchNui('close', { returnToMultichar: true })
      setIsOpen(false)
      setIsReadyToSpawn(false)
      setSelectedIndex(0)
    } catch (error) {
      console.error('Erro ao fechar:', error)
    }
  }, [])

  const loadSpawns = useCallback(async () => {
    try {
      const data = await fetchNui('getSpawns')
      console.log('[mri_Qspawn] Resposta do getSpawns:', data)

      if (data.success && data.spawns && Array.isArray(data.spawns) && data.spawns.length > 0) {
        console.log(`[mri_Qspawn] ${data.spawns.length} spawns carregados`)
        setSpawns(data.spawns)
        setSelectedIndex(0)
      } else {
        console.error('[mri_Qspawn] Nenhum spawn encontrado. Resposta:', JSON.stringify(data, null, 2))
      }
    } catch (error) {
      console.error('[mri_Qspawn] Erro ao carregar spawns:', error)
    }
  }, [])

  useEffect(() => {
    const handleMessage = (event: MessageEvent) => {
      const data = event.data
      console.log(`[mri_Qspawn:NUI] Mensagem recebida: ${data?.action}`, JSON.stringify(data));

      if (data && data.action === 'open') {
        console.log('[mri_Qspawn:NUI] Abrindo Painel de Spawn...');
        setIsOpen(true)
        setHasAutoSelected(false)
        if (data.title) {
          setTitle(data.title)
        }
        if (data.spawns && Array.isArray(data.spawns) && data.spawns.length > 0) {
          console.log(`[mri_Qspawn:NUI] ${data.spawns.length} spawns recebidos na abertura`);
          setSpawns(data.spawns)
          setSelectedIndex(0)
        } else {
          console.log('[mri_Qspawn:NUI] Spawns vazios no "open", buscando via callback...');
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
          console.log(`[mri_Qspawn:NUI] Atualizando ${data.allIcons.length} ícones`);
          setMapIcons(data.allIcons)
        }
      }
    }

    window.addEventListener('message', handleMessage)

    return () => {
      window.removeEventListener('message', handleMessage)
    }
  }, [loadSpawns])

  // Sinalizar pronto separadamente com delay para garantir estabilidade da ponte NUI
  useEffect(() => {
    console.log('[mri_Qspawn:NUI] JS Montado. Aguardando 1s para enviar nuiReady...');
    const timer = setTimeout(() => {
      console.log('[mri_Qspawn:NUI] Enviando sinal de pronto (nuiReady) agora...');
      fetchNui('nuiReady', {}).catch(err => {
          console.error('[mri_Qspawn:NUI] Falha ao enviar nuiReady:', err);
      });
    }, 1000);
    return () => clearTimeout(timer);
  }, []);

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
      const data = await fetchNui('selectSpawn', { index: index })
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
        <div className="absolute top-10 left-1/2 -translate-x-1/2 z-10">
          <div className="flex flex-col items-center gap-2">
            <div className="bg-black/60 border border-primary/20 p-3 rounded-full mb-2">
              <MapPin className="w-8 h-8 text-primary drop-shadow-[0_0_10px_rgba(160,255,115,0.5)]" />
            </div>
            <h1 className="text-4xl font-black tracking-tighter text-white drop-shadow-2xl italic uppercase">
              {title}
            </h1>
            <div className="h-1 w-24 bg-primary" />
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
        <div className="absolute bottom-10 left-1/2 -translate-x-1/2 z-10 flex items-center gap-6">
          {isReadyToSpawn && (
            <MriButton
              onClick={handleConfirmSpawn}
              variant="default"
              size="lg"
              className="px-8 py-6 text-lg font-bold uppercase italic group shadow-[0_0_20px_rgba(160,255,115,0.3)] hover:shadow-[0_0_30px_rgba(160,255,115,0.5)] transition-all duration-300"
            >
              <div className="flex items-center gap-3">
                <ArrowRight className="w-6 h-6 animate-pulse" />
                <span>Confirmar Spawn</span>
                <MriBadge variant="secondary" className="ml-2 bg-black/20 text-white border-none text-[10px]">ENTER</MriBadge>
              </div>
            </MriButton>
          )}
        </div>

        {/* Lista de spawns à direita - Estilo Premium MRI */}
        <div className="absolute top-1/2 right-12 -translate-y-1/2 z-10 w-[450px] pointer-events-auto">
          <MriCard className="bg-black/90 border-white/10 shadow-2xl overflow-hidden rounded-3xl">
            <div className="p-6 border-b border-white/5 bg-gradient-to-br from-white/5 to-transparent">
              <div className="flex items-center justify-between mb-1">
                <span className="text-xs font-bold text-primary tracking-[0.2em] uppercase italic">Destinos Disponíveis</span>
                <MriBadge variant="default" className="bg-primary/20 text-primary border-primary/30 text-[10px]">{spawns.length}</MriBadge>
              </div>
              <p className="text-white/40 text-[10px] uppercase tracking-widest font-medium">Selecione seu local de início</p>
            </div>

            <div className="p-4 space-y-3 max-h-[75vh] overflow-y-auto custom-scrollbar">
              {spawns.length > 0 ? (
                spawns.map((spawn, index) => {
                  const isSelected = selectedIndex === index
                  const displayLabel = spawn.label

                  return (
                    <button
                      key={index}
                      onClick={() => handleSelectSpawn(index)}
                      className={cn(
                        "w-full flex items-center gap-4 p-4 rounded-2xl transition-all duration-300 text-left relative group overflow-hidden border",
                        isSelected
                          ? "bg-primary/10 border-primary/40 shadow-[0_0_20px_rgba(160,255,115,0.15)]"
                          : "bg-white/[0.02] border-white/5 hover:bg-white/[0.05] hover:border-white/10"
                      )}
                    >
                      {/* Efeito de brilho lateral quando selecionado */}
                      {isSelected && (
                        <div className="absolute left-0 top-0 bottom-0 w-1 bg-primary shadow-[0_0_10px_rgba(160,255,115,0.8)]" />
                      )}

                      {/* Ícone */}
                      <div className={cn(
                        "flex-shrink-0 p-3 rounded-xl transition-all duration-300",
                        isSelected ? "bg-primary text-black scale-110" : "bg-white/5 text-white/40"
                      )}>
                        {getIcon(spawn.icon, 'w-6 h-6', isSelected)}
                      </div>

                      {/* Conteúdo */}
                      <div className="flex-1 min-w-0">
                        <div className="flex items-center justify-between mb-0.5">
                          <h3 className={cn(
                            "font-black text-lg tracking-tight transition-colors duration-300 uppercase italic",
                            isSelected ? "text-white" : "text-white/60 group-hover:text-white/80"
                          )}>
                            {displayLabel}
                          </h3>
                        </div>
                        <p className={cn(
                          "text-[11px] leading-tight transition-colors duration-300 font-medium uppercase tracking-wide",
                          isSelected ? "text-primary/80" : "text-white/30"
                        )}>
                          {spawn.description || `Ponto de início em ${displayLabel}`}
                        </p>
                      </div>

                      {/* Indicador de Selecionado */}
                      {isSelected && (
                        <div className="flex-shrink-0">
                          <div className="bg-primary/20 p-1.5 rounded-full border border-primary/30">
                            <CheckCircle2 className="w-4 h-4 text-primary" />
                          </div>
                        </div>
                      )}
                    </button>
                  )
                })
              ) : (
                <div className="text-center py-20">
                  <div className="inline-block animate-spin rounded-full h-8 w-8 border-2 border-primary border-t-transparent mb-4" />
                  <p className="text-white/40 text-xs font-bold uppercase tracking-widest">Carregando locais...</p>
                </div>
              )}
            </div>
          </MriCard>
        </div>


      </div>
    </div>
  )
}

export default App

