/**
 * dsh-pc-guard — Host half.
 *
 * Registers the `pc_guard` tool, which delegates to the bundled
 * assets/PcGuard.ps1 Windows script:
 *   - lock     : lock the workstation (keeps every background program, never sleeps)
 *   - status   : sample current total CPU usage and idle time
 *   - ui       : open the PC Guard panel (CPU gauge, one-click lock, auto pause)
 *   - shortcut : (re)create the "锁屏管家" desktop shortcut that opens that panel
 *
 * The script is intentionally shipped as plain PowerShell so the repo stays
 * dependency-free: no build step, no native modules, no install scripts.
 */
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))
const scriptPath = path.join(here, 'assets', 'PcGuard.ps1')
const TIMEOUT_MS = 25_000

function psArgs(args) {
  return ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, ...args]
}

function runScript(args) {
  return new Promise((resolve, reject) => {
    const child = spawn('powershell.exe', psArgs(args), { windowsHide: true })
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => {
      child.kill()
      reject(new Error('pc_guard: PcGuard.ps1 timed out'))
    }, TIMEOUT_MS)

    child.stdout.on('data', (chunk) => { stdout += String(chunk) })
    child.stderr.on('data', (chunk) => { stderr += String(chunk) })
    child.on('error', (error) => { clearTimeout(timer); reject(error) })
    child.on('close', (code) => {
      clearTimeout(timer)
      if (code !== 0) {
        reject(new Error(`pc_guard: PcGuard.ps1 exited with ${code}${stderr ? `: ${stderr.trim()}` : ''}`))
        return
      }
      resolve(stdout.trim())
    })
  })
}

/** Start the panel detached: it stays open on its own, so never await it. */
function launchPanel() {
  const child = spawn('powershell.exe', psArgs(['-Action', 'ui']), {
    detached: true,
    stdio: 'ignore',
    windowsHide: true,
  })
  child.unref()
  return child.pid
}

/** The script prints a single JSON line; tolerate banner noise before it. */
function parseLastJson(text) {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (!lines[i].startsWith('{')) continue
    try {
      return JSON.parse(lines[i])
    } catch {
      // keep looking
    }
  }
  return { ok: false, message: text || 'pc_guard: empty output' }
}

function describe(value) {
  if (value.action === 'lock') return 'Workstation locked; background programs keep running and the machine does not sleep.'
  if (value.action === 'ui') return 'PC Guard panel opened. It keeps running after this conversation.'
  if (value.action === 'shortcut') return `Desktop shortcut ready: ${value.path ?? '锁屏管家.lnk'}`
  if (typeof value.cpu === 'number') {
    return `CPU ${value.cpu}% · idle ${Math.round(value.idleSec ?? 0)}s · ${value.targets ?? 0} guard target(s)`
  }
  return 'pc_guard finished.'
}

const ACTIONS = ['lock', 'status', 'ui', 'shortcut']

export const inject = ['tools']

export function apply(ctx) {
  ctx.effect(() =>
    ctx.tools.register({
      name: 'pc_guard',
      description:
        'Windows-only power helper for this machine. '
        + 'action="lock" immediately locks the workstation (same effect as Win+L: every background program keeps running, '
        + 'nothing sleeps or shuts down). '
        + 'action="status" samples total CPU usage and user idle time so you can judge machine load before starting heavy work. '
        + 'action="ui" opens the PC Guard panel: a small window with a live CPU gauge, a one-click lock button, '
        + 'and switches that pause OCR/DSH processes above 90% CPU and resume them below 40%. '
        + 'action="shortcut" (re)creates the "锁屏管家" desktop shortcut that opens that panel. '
        + 'Call this when the user asks to lock the screen, open the PC Guard panel, put a PC Guard icon on the desktop, '
        + 'or asks how loaded the machine currently is.',
      parameters: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ACTIONS,
            description: 'lock = lock now; status = sample CPU/idle; ui = open the panel; shortcut = create desktop shortcut.',
          },
        },
        required: ['action'],
        additionalProperties: false,
      },
      output: {
        schema: {
          type: 'object',
          properties: {
            ok: { type: 'boolean' },
            action: { type: 'string' },
            cpu: { type: 'number' },
            idleSec: { type: 'number' },
            targets: { type: 'number' },
            path: { type: 'string' },
            message: { type: 'string' },
          },
          additionalProperties: true,
        },
        render: (_args, value) => [{ type: 'text', text: describe(value ?? {}) }],
      },
      async execute(args) {
        if (process.platform !== 'win32') {
          throw new Error('pc_guard: only Windows is supported')
        }
        const input = args && typeof args === 'object' ? args : {}
        const action = ACTIONS.includes(input.action) ? input.action : 'status'

        if (action === 'ui') {
          const pid = launchPanel()
          return { ok: true, action, pid }
        }

        const value = parseLastJson(await runScript(['-Action', action]))
        return { ...value, action }
      },
    }),
  )
}
