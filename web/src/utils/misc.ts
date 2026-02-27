/**
 * Detects if the current environment is a browser or the game (FiveM NUI).
 *
 * @returns {boolean} True if running in a standalone browser.
 */
export const isEnvBrowser = (): boolean => !(window as any).invokeNative;

/**
 * Map of mock data for development mode.
 */
const mockData: Record<string, any> = {
  getSpawns: {
    success: true,
    spawns: [
      {
        label: 'Legion Square',
        coords: { x: 147.16, y: -1035.76, z: 29.34 },
        icon: 'map-pin',
        description: 'O coração da cidade, perto do banco principal.'
      },
      {
        label: 'PD Mission Row',
        coords: { x: 427.56, y: -972.24, z: 30.71 },
        icon: 'shield',
        description: 'Departamento de Polícia de Mission Row.'
      },
      {
        label: 'Hospital Pillbox',
        coords: { x: 299.14, y: -584.62, z: 43.26 },
        icon: 'bed',
        description: 'Hospital Central de Los Santos.'
      },
      {
        label: 'Aeroporto LS',
        coords: { x: -1037.37, y: -2737.52, z: 20.17 },
        icon: 'building',
        description: 'Aeroporto Internacional de Los Santos.'
      },
      {
        label: 'Paleto Bay',
        coords: { x: -449.61, y: 6012.39, z: 31.72 },
        icon: 'leaf',
        description: 'Uma pacata vila ao norte da ilha.'
      },
      {
        label: 'Sandy Shores',
        coords: { x: 1853.79, y: 3687.97, z: 34.27 },
        icon: 'umbrella',
        description: 'O deserto próximo ao Alamo Sea.'
      }
    ],
    title: 'SPAWN SELECTOR (DEV MODE)'
  },
  selectSpawn: {
    success: true
  },
  confirmSpawn: {
    success: true
  },
  close: {
    success: true
  }
};

/**
 * Standard fetch wrapper for NUI callbacks.
 *
 * @param {string} eventName The NUI callback event name.
 * @param {any} data Optional data to send to the game.
 * @param {any} mockDataOverride Optional mock data to return in browser mode.
 * @returns {Promise<T>} The response from the game or mock data.
 */
export async function fetchNui<T = any>(
  eventName: string,
  data: any = {},
  mockDataOverride?: T
): Promise<T> {
  const options = {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
    },
    body: JSON.stringify(data),
  };

  if (isEnvBrowser()) {
    if (mockDataOverride) return mockDataOverride;

    // Check if we have predefined mock data for this event
    if (mockData[eventName]) {
      console.log(`[mri_Qspawn:NUI:Mock] Fetching ${eventName}`, data);
      return mockData[eventName] as T;
    }

    return { success: true } as unknown as T;
  }

  // Improved Resource Name Detection
  // In FiveM, GetParentResourceName is usually available globally.
  const resourceName = (window as any).GetParentResourceName
    ? (window as any).GetParentResourceName()
    : ((window as any).resourceName || 'mri_Qspawn');

  console.log(`[mri_Qspawn:NUI] Request: ${eventName} to resource: ${resourceName}`, data);

  try {
    const resp = await fetch(`https://${resourceName}/${eventName}`, options);

    if (!resp.ok) {
        console.error(`[mri_Qspawn:NUI] HTTP Error: ${resp.status} ${resp.statusText} for ${eventName}`);
        return { success: false, message: `HTTP Error ${resp.status}` } as unknown as T;
    }

    const respFormatted = await resp.json();
    console.log(`[mri_Qspawn:NUI] Response: ${eventName}`, respFormatted);

    return respFormatted;
  } catch (err) {
    console.error(`[mri_Qspawn:NUI] Fetch Error for ${eventName}:`, err);
    return { success: false, message: 'Fetch Error' } as unknown as T;
  }
}

/**
 * Emits a message to the window as if it came from the FiveM client.
 * Use this only for testing in the browser.
 *
 * @param {string} action The action name.
 * @param {any} data The data payload.
 */
export const debugMessage = (action: string, data: any = {}) => {
  if (isEnvBrowser()) {
    window.postMessage({ action, ...data }, '*');
  }
};
