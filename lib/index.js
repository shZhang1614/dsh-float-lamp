/**
 * dsh-float-lamp — host half.
 *
 * Folds the live session event stream into one aggregate status and writes it
 * to ~/.dsh/float-lamp/state.json for the floating lamp widget (widget/lamp.ps1)
 * to render. Never throws into the host: every listener is guarded.
 *
 * States (priority order):
 *   approval  橙 orange — a session is waiting for user approval
 *   question  蓝 blue   — a session is waiting for interactive input
 *                          (ask_user_question / exit_plan_mode pending)
 *   running   绿 green  — a turn is open, nothing pending from the user
 *   idle      灰 gray   — no live session has an open turn
 */

import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import cp from 'node:child_process'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-float-lamp'

export const inject = ['sessions']

/** Plugin root (lib/ -> package root). */
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)))

/** Shared state directory + file the widget polls. */
export const STATE_DIR = path.join(os.homedir(), '.dsh', 'float-lamp')
export const STATE_FILE = path.join(STATE_DIR, 'state.json')

/** Tool calls that mean "the agent wants an interactive answer from the user". */
const INTERACTIVE_TOOLS = new Set(['ask_user_question', 'exit_plan_mode'])

/** Per-session fold state. */
const sessions = new Map()

/** Debug log for diagnosing event wiring (append-only, timestamped). */
let dbgCount = 0
function dbg(msg) {
	try {
		fs.mkdirSync(STATE_DIR, { recursive: true })
		fs.appendFileSync(path.join(STATE_DIR, 'debug.log'), `${new Date().toISOString()} ${msg}\n`)
	} catch {
		/* ignore */
	}
}

function ensure(id) {
	let st = sessions.get(id)
	if (!st) sessions.set(id, (st = { openTurn: false, turnStartedAt: 0, approvals: new Set(), interactive: new Set(), lastSeq: -1, lastMsg: '', toolQueue: [] }))
	return st
}

/** First non-empty text block of a message record (user/message data IS the record). */
function firstText(data) {
	const content = Array.isArray(data?.content) ? data.content : []
	for (const block of content) {
		if (block && block.type === 'text' && typeof block.text === 'string' && block.text.trim()) return block.text.trim()
	}
	return ''
}

/** One-line, length-capped task title for the hover tooltip. */
function title(text) {
	const oneLine = String(text ?? '').replace(/\s+/g, ' ').trim()
	return oneLine.length > 60 ? `${oneLine.slice(0, 60)}…` : oneLine
}

/** Harness-injected pseudo user messages (runtime context, reminders) — not real task text. */
function isHarnessNoise(text) {
	return /^<|^(Time sampled|Current runtime context|The approval policy changed|\[Compressed conversation section\])/.test(text)
}

/**
 * Apply one session event to the fold state for `id`.
 * @param id - session id.
 * @param ev - { type, data } session event.
 */
export function applyEvent(id, ev) {
	if (!ev || typeof ev.type !== 'string') return
	const st = ensure(id)
	// Dedup by envelope seq: guards against double delivery when both the
	// direct listener and the internal/dispatch tap fire for one event.
	if (typeof ev.seq === 'number') {
		if (ev.seq <= st.lastSeq) return
		st.lastSeq = ev.seq
	}
	const data = ev.data ?? {}
	switch (ev.type) {
		case 'turn/start':
			st.openTurn = true
			// Event envelopes carry no timestamp (SessionEventMap data is {turn}),
			// so wall-clock start is sampled at fold time. Seeded replays start
			// the clock at seed time — an acceptable approximation.
			st.turnStartedAt = Date.now()
			break
		case 'turn/end':
			st.openTurn = false
			st.turnStartedAt = 0
			st.approvals.clear()
			st.interactive.clear()
			st.toolQueue.length = 0
			break
		case 'user/message': {
			const text = firstText(data)
			if (text && !isHarnessNoise(text)) st.lastMsg = text
			break
		}
		case 'approval/asked':
			st.approvals.add(String(data.id ?? `anon-${st.approvals.size}`))
			break
		case 'approval/decided':
			st.approvals.delete(String(data.id ?? ''))
			break
		case 'tool/call':
			if (typeof data.name === 'string' && data.name) {
				st.toolQueue.push(data.name)
				if (st.toolQueue.length > 32) st.toolQueue.shift()
			}
			if (INTERACTIVE_TOOLS.has(data.name)) st.interactive.add(String(data.callId ?? `anon-${st.interactive.size}`))
			break
		case 'tool/result':
			// tool/result carries no callId in its data envelope; FIFO pairing
			// is sufficient for lamp semantics (one pending interactive call
			// per step in practice).
			if (st.interactive.size > 0) st.interactive.delete(st.interactive.values().next().value)
			if (st.toolQueue.length > 0) st.toolQueue.shift()
			break
	}
}

/** Replay a whole event log (used to seed sessions that attached before us). */
export function foldEvents(id, events) {
	for (const ev of events ?? []) applyEvent(id, ev)
}

/** Aggregate all sessions into the lamp state. */
export function aggregate() {
	let approval = 0
	let question = 0
	let running = 0
	let runningSince = 0
	const tasks = []
	const rank = { approval: 0, question: 1, running: 2, idle: 3 }
	for (const st of sessions.values()) {
		let state = 'idle'
		if (st.approvals.size > 0) {
			approval++
			state = 'approval'
		} else if (st.interactive.size > 0) {
			question++
			state = 'question'
		} else if (st.openTurn) {
			running++
			state = 'running'
			if (st.turnStartedAt > 0 && (runningSince === 0 || st.turnStartedAt < runningSince)) runningSince = st.turnStartedAt
		}
		const t = title(st.lastMsg)
		if (state !== 'idle' || t) {
			tasks.push({ state, title: t, tool: st.toolQueue.length > 0 ? st.toolQueue[st.toolQueue.length - 1] : '' })
		}
	}
	tasks.sort((a, b) => rank[a.state] - rank[b.state])
	if (tasks.length > 8) tasks.length = 8
	const state = approval > 0 ? 'approval' : question > 0 ? 'question' : running > 0 ? 'running' : 'idle'
	return { v: 1, state, counts: { approval, question, running }, runningSince: running > 0 ? runningSince : 0, tasks, updatedAt: Date.now(), pid: process.pid }
}

/** Atomic write so the widget never reads a half-written file. */
export function writeState(snapshot) {
	fs.mkdirSync(STATE_DIR, { recursive: true })
	const tmp = STATE_FILE + '.tmp'
	fs.writeFileSync(tmp, JSON.stringify(snapshot, null, 2))
	fs.renameSync(tmp, STATE_FILE)
}

/** Coalesced write: bursts of events collapse into one file update. */
let pending = null
/** True while the plugin-manager switch has us disabled: no state writes. */
let lampStopped = false
function schedule() {
	if (pending || lampStopped) return
	pending = setTimeout(() => {
		pending = null
		try {
			writeState(aggregate())
		} catch {
			/* never crash the host over the lamp */
		}
	}, 50)
	if (pending.unref) pending.unref()
}

/** The lamp child spawned by this process (module-level: survives fiber remounts). */
let lampChild = null

/** Is a lamp window already alive (our child, or the pid the widget recorded)? */
function lampAlive() {
	// Heartbeat written by the widget's render loop: a zombie lamp (process alive,
	// window gone, loop stopped) stops beating, so heartbeat freshness wins over
	// process existence. No heartbeat file = older widget, fall back to pid probe.
	try {
		const hb = parseInt(fs.readFileSync(path.join(STATE_DIR, 'lamp-alive'), 'utf8'), 10)
		if (hb) return Date.now() - hb < 6000
	} catch {
		/* fall through to pid probe */
	}
	if (lampChild && lampChild.exitCode === null) return true
	try {
		const pid = parseInt(fs.readFileSync(path.join(STATE_DIR, 'lamp.pid'), 'utf8'), 10)
		if (pid && pid !== process.pid) {
			process.kill(pid, 0) // throws ESRCH when dead; EPERM means alive
			return true
		}
	} catch (error) {
		if (error && error.code !== 'ESRCH' && error.code !== 'ENOENT') return true
	}
	return false
}

/** Kill a stale lamp process (zombie or leftover) so the mutex is free for respawn. */
function reapStaleLamp() {
	try {
		const pid = parseInt(fs.readFileSync(path.join(STATE_DIR, 'lamp.pid'), 'utf8'), 10)
		if (pid && pid !== process.pid) {
			process.kill(pid)
			dbg(`reaped stale lamp pid=${pid}`)
		}
	} catch {
		/* already gone */
	}
}

/**
 * Has the user switched this plugin off in the plugin manager? dshmarket writes
 * `disabled: true` into the profile patch layer (cordis.patch.yml) but does NOT
 * unload the running fiber, so we watch our own patch entry and stop ourselves.
 * @returns true when the profile patch layer disables the dsh-float-lamp entry.
 */
function patchDisabled() {
	try {
		const profile = process.env.DSH_PROFILE || 'desktop'
		const file = path.join(os.homedir(), '.dsh', 'profiles', profile, 'cordis.patch.yml')
		const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/)
		for (let i = 0; i < lines.length; i++) {
			if (!/^\s*-\s*id:\s*dsh-float-lamp\s*(#.*)?$/.test(lines[i])) continue
			for (let j = i + 1; j < lines.length; j++) {
				if (/^\s*-\s/.test(lines[j])) break
				if (/disabled:\s*true/.test(lines[j])) return true
			}
			return false
		}
	} catch {
		/* no patch file / unreadable = not disabled */
	}
	return false
}

/** Spawn the always-on-top lamp window (one instance — the widget self-locks). */
function spawnLamp(ctx) {
	if (process.env.DSH_FLOAT_LAMP_NO_WIDGET === '1') {
		dbg('spawn skipped: DSH_FLOAT_LAMP_NO_WIDGET=1')
		return null
	}
	if (lampAlive()) {
		dbg('spawn skipped: lamp already alive (no window rebuild)')
		return lampChild
	}
	// heartbeat stale but process may linger (zombie): kill it so the single-instance
	// mutex is free and the new lamp can take over.
	reapStaleLamp()
	const script = path.join(ROOT, 'widget', 'lamp.ps1')
	if (!fs.existsSync(script)) {
		dbg(`spawn skipped: script missing at ${script}`)
		return null
	}
	const pwsh = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
	try {
		// NOTE: do NOT use detached:true here. On Windows, detached + stdio:'ignore'
		// makes powershell.exe exit(0) within ~150ms without running the script
		// (measured). stdio:'ignore' + windowsHide + unref() is enough: the child
		// survives host exit on Windows, and dispose() kills it deliberately.
		const child = cp.spawn(pwsh, ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script], {
			stdio: 'ignore',
			windowsHide: true,
		})
		child.unref()
		child.on('exit', (code, signal) => dbg(`lamp exited code=${code} signal=${signal}`))
		lampChild = child
		dbg(`spawned lamp pid=${child.pid}`)
		return child
	} catch (error) {
		ctx.logger?.warn?.(`dsh-float-lamp: failed to spawn lamp widget: ${String(error)}`)
		dbg(`spawn error: ${String(error)}`)
		return null
	}
}

/**
 * Register against the host context.
 * @param ctx - host cordis context.
 */
export function apply(ctx) {
	dbg(`apply v6: pid=${process.pid} root=${ROOT} argv=${process.argv.join(' ').slice(0, 120)}`)
	// Capture the sessions service instance NOW, while this fiber is active.
	// Later (inside timers) `ctx.sessions` goes through the context proxy, which
	// throws "cannot get required service" if the fiber ever unloads; the captured
	// store object itself stays valid (it is owned by the sessions plugin, not us).
	let svc = null
	try {
		svc = ctx.sessions ?? null
	} catch (error) {
		dbg(`capture sessions service failed: ${String(error)}`)
	}
	// Seed sessions that attached before this plugin loaded (live sessions only).
	try {
		const live = svc?.list?.() ?? []
		dbg(`seed: ${live.length} live sessions`)
		for (const session of live) foldEvents(session.id, session.log ?? session.snapshotEvents?.())
	} catch (error) {
		ctx.logger?.warn?.(`dsh-float-lamp: seed failed: ${String(error)}`)
		dbg(`seed failed: ${String(error)}`)
	}

	const created = (session) => {
		try {
			dbg(`created: id=${session?.id}`)
			foldEvents(session.id, session.log ?? session.snapshotEvents?.())
			schedule()
		} catch (error) {
			dbg(`created error: ${String(error)}`)
		}
	}
	const event = (session, ev) => {
		try {
			if (dbgCount < 300) dbg(`event: sid=${session?.id} type=${ev?.type} name=${ev?.data?.name ?? ''}`)
			dbgCount++
			applyEvent(session.id, ev)
			schedule()
		} catch (error) {
			dbg(`event error: ${String(error)}`)
		}
	}
	// The internal/dispatch tap is the pattern every core invariant uses; it sees
	// every scoped dispatch regardless of how the session carrier is scoped.
	const dispatch = (mode, eventName, args) => {
		try {
			if (eventName === 'session/created') created(args?.[0])
			else if (eventName === 'session/event') event(args?.[0], args?.[1])
			else if (eventName === 'float-lamp-probe') dbg('probe: dispatch tap RECEIVED float-lamp-probe (bus + our global hook are live)')
		} catch (error) {
			dbg(`dispatch error: ${String(error)}`)
		}
	}
	ctx.on('internal/dispatch', dispatch, { global: true })
	// Plain (non-global) registration — the pattern billion-context uses in this
	// host and that is proven to receive session events from a plugin ctx.
	ctx.on('session/created', created)
	ctx.on('session/event', event)
	dbg('apply v6: listeners registered (dispatch global + plain created/event) + poll loop')

	// Poll the session store directly. This is the authoritative path: it does
	// not depend on the event bus reaching this plugin at all. Every ~800ms we
	// diff each live session's frozen event snapshot against our fold cursor.
	const poll = () => {
		try {
			const live = svc?.list?.() ?? []
			const ids = new Set()
			let advanced = false
			for (const session of live) {
				ids.add(session.id)
				const st = ensure(session.id)
				const events = session.log ?? session.snapshotEvents?.()
				if (!Array.isArray(events) || events.length === 0) continue
				// seq is monotonic inside the log; scan back to the first event
				// newer than our cursor (seq may not equal log index on forks).
				let from = events.length
				while (from > 0 && typeof events[from - 1]?.seq === 'number' && events[from - 1].seq > st.lastSeq) from--
				if (from < events.length) {
					for (let i = from; i < events.length; i++) applyEvent(session.id, events[i])
					advanced = true
					if (pollDbg < 60) {
						dbg(`poll: sid=${session.id} applied ${from}..${events.length - 1} lastType=${events[events.length - 1]?.type}`)
						pollDbg++
					}
				}
			}
			// Sessions that left the store (disposed/closed) must not pin state.
			for (const id of sessions.keys()) if (!ids.has(id)) sessions.delete(id)
			if (advanced) schedule()
			if (ids.size !== pollLastCount) {
				dbg(`poll: live sessions ${pollLastCount} -> ${ids.size}`)
				pollLastCount = ids.size
			}
		} catch (error) {
			if (pollErrDbg < 20) dbg(`poll error: ${String(error)}`)
			pollErrDbg++
		}
	}
	let pollDbg = 0
	let pollErrDbg = 0
	let pollLastCount = -1
	const pollTimer = setInterval(poll, 800)
	if (pollTimer.unref) pollTimer.unref()

	// One-shot bus probe: proves whether OUR hooks are live on the bus at all.
	// If the probe line appears but no session/event lines do, the session
	// store dispatches on a different bus; if the probe line is missing, our
	// registrations were dropped (fiber disposed).
	setTimeout(() => {
		try {
			const hooks = ctx.events?._hooks ?? {}
			const count = (name) => (hooks[name] || []).length
			dbg(`probe: fiber.state=${ctx.fiber?.state} hooks.session/event=${count('session/event')} hooks.session/created=${count('session/created')} hooks.internal/dispatch=${count('internal/dispatch')} hookKeys=${Object.keys(hooks).length}`)
			ctx.events?.emit?.('float-lamp-probe', process.pid)
			dbg('probe: self-emit float-lamp-probe dispatched')
		} catch (error) {
			dbg(`probe error: ${String(error)}`)
		}
	}, 5000)

	// Initial state + heartbeat. The heartbeat also watches the plugin-manager
	// switch (patch layer `disabled: true`): toggling off kills the lamp within
	// ~5s without a restart; toggling back on relights it just as fast.
	try {
		writeState(aggregate())
	} catch {
		/* ignore */
	}
	let off = patchDisabled()
	lampStopped = off
	if (off) dbg('apply: profile patch says disabled — staying off')
	const beat = setInterval(() => {
		try {
			if (off) {
				if (!patchDisabled()) {
					off = false
					lampStopped = false
					dbg('heartbeat: re-enabled — relighting lamp')
					spawnLamp(ctx)
				}
				return
			}
			if (patchDisabled()) {
				off = true
				lampStopped = true
				dbg('heartbeat: disable detected — killing lamp, stopping state writes')
				try {
					writeState({ ...aggregate(), hostDown: true })
				} catch {
					/* ignore */
				}
				try {
					lampChild?.kill()
				} catch {
					/* ignore */
				}
				lampChild = null
				return
			}
			if (!lampAlive()) spawnLamp(ctx)
			writeState(aggregate())
		} catch {
			/* ignore */
		}
	}, 5000)
	if (beat.unref) beat.unref()

	const child = off ? null : spawnLamp(ctx)

	// Cordis collects a function returned from apply() as the fiber's disposable
	// (cordis/lib/index.js:1142-1143). Do NOT touch `ctx.dispose` — Context has no
	// such member and the proxy get trap throws, which used to poison the whole
	// fiber (state=3, all listeners silently removed).
	return () => {
		clearInterval(beat)
		clearInterval(pollTimer)
		if (pending) clearTimeout(pending)
		try {
			writeState({ ...aggregate(), hostDown: true })
		} catch {
			/* ignore */
		}
		try {
			child?.kill()
		} catch {
			/* ignore */
		}
		lampChild = null
	}
}
