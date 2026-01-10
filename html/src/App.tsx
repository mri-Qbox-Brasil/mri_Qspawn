import { useState, useEffect, useCallback } from 'react'
import { Shield, Leaf, Umbrella, Bed, Home, MapPin, Building } from 'lucide-react'
import { Card } from './components/ui/card'
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

function App() {
  const [isOpen, setIsOpen] = useState(false)
  const [spawns, setSpawns] = useState<SpawnLocation[]>([])
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [isReadyToSpawn, setIsReadyToSpawn] = useState(false)

  // Icon mapping
  const getIcon = (iconName?: string) => {
    switch (iconName) {
      case 'shield':
        return <Shield className="w-5 h-5" />
      case 'leaf':
        return <Leaf className="w-5 h-5" />
      case 'umbrella':
        return <Umbrella className="w-5 h-5" />
      case 'bed':
        return <Bed className="w-5 h-5" />
      case 'home':
        return <Home className="w-5 h-5" />
      case 'building':
        return <Building className="w-5 h-5" />
      case 'map-pin':
        return <MapPin className="w-5 h-5" />
      default:
        return <MapPin className="w-5 h-5" />
    }
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
        body: JSON.stringify({}),
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
      }
    }

    window.addEventListener('message', handleMessage)

    return () => {
      window.removeEventListener('message', handleMessage)
    }
  }, [isOpen, loadSpawns])

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

  const handleSelectSpawn = async (index: number) => {
    if (index < 0 || index >= spawns.length) return

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
  }

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center">
      {/* Background overlay com visualização do mapa (opcional - será renderizado pelo jogo) */}
      <div className="absolute inset-0 bg-black/50" />
      
      {/* Conteúdo principal */}
      <div className="relative w-full h-full flex">
        {/* Área esquerda - Instruções */}
        <div className="absolute top-8 left-8 z-10 text-white">
          <h1 className="text-4xl font-bold mb-2">SPAWN LOCATION</h1>
          <p className="text-lg text-gray-300 mb-4">Select where you want to start</p>
          <div className="space-y-1 text-sm text-gray-400">
            <p>Click on a location to view it on the map</p>
            {isReadyToSpawn ? (
              <p className="text-green-400 font-bold">
                Press <span className="text-white">ENTER</span> to spawn at selected location
              </p>
            ) : (
              <p>Press <span className="font-bold text-white">ESC</span> to cancel</p>
            )}
          </div>
        </div>

        {/* Lista de spawns à direita */}
        <div className="absolute top-1/2 right-8 -translate-y-1/2 z-10">
          <Card className="w-80 bg-gray-900/90 border-gray-700 backdrop-blur-md">
            <div className="p-4 max-h-[600px] overflow-y-auto">
              <div className="space-y-2">
                {spawns.length > 0 ? (
                  spawns.map((spawn, index) => (
                    <button
                      key={index}
                      onClick={() => {
                        setSelectedIndex(index)
                        handleSelectSpawn(index)
                      }}
                      onMouseEnter={() => setSelectedIndex(index)}
                      className={cn(
                        "w-full flex items-center gap-3 p-3 rounded-lg transition-all text-left cursor-pointer",
                        selectedIndex === index
                          ? "bg-white/20 text-white"
                          : "bg-white/5 text-gray-300 hover:bg-white/10"
                      )}
                    >
                      <div className="flex-shrink-0 text-white">
                        {getIcon(spawn.icon)}
                      </div>
                      <div className="flex-1 min-w-0">
                        <p className="font-semibold text-white truncate">
                          {spawn.label === 'last_location' ? 'Last Location' : spawn.label}
                        </p>
                        <p className="text-xs text-gray-400 truncate">
                          {spawn.description || `Start at ${spawn.label}`}
                        </p>
                      </div>
                    </button>
                  ))
                ) : (
                  <div className="text-center text-gray-400 py-4">
                    <p>Carregando locais...</p>
                  </div>
                )}
              </div>
            </div>
          </Card>
        </div>
      </div>
    </div>
  )
}

export default App

