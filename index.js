// dsh-pet-window —— 桌面立绘对话窗（Host 侧）
//
// 这个插件做四件事，别的什么都不做：
//   ① DSH 启动时把原生窗口进程拉起来（PowerShell + WPF，零依赖）；
//   ② 进程**意外**退出就重启；用户主动关掉则安静一段时间，免得关不掉；
//   ③ **盯 inbox.jsonl**：用户在窗口里说的话，自动投进当前活跃会话，
//      这样我才会被叫醒去回他 —— 没有这一步，窗口只是单向文件，用户说话没人应；
//   ④ 把每一步都记进 host.log，方便排查。
//
// 为什么窗口不在这里实现：Electron 的 dshPlatform.open() 只接受 "usage"/"top-up"
// 两个页面（宿主硬校验），拿不到自定义窗口；而要让立绘出现在**桌面**上而不是页面内，
// 必须是一个独立的操作系统窗口 —— 那只能由独立进程去画。
//
// 数据流：
//   我说的话   → queue.jsonl  → 窗口显示
//   用户打的字 → inbox.jsonl  → 本文件监听 → 投进会话 → 我回话
//
// 投递方式照抄 dsh-selfwake 真机验过的写法（kind:'user' + followup），
// 那条路上踩过坑的记录在对方源码里，不要改。

import { spawn } from 'node:child_process'
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-pet-window'

const HERE = dirname(fileURLToPath(import.meta.url))
const PACKAGE_ROOT = resolve(HERE, '..')

/** 活过这个时长才算是"用户主动关的"，而不是启动即崩。 */
const HEALTHY_RUN_MS = 20_000
/** 用户关掉后安静多久再自己回来。 */
const USER_CLOSE_COOLDOWN_MS = 5 * 60_000
/** 启动即崩时的退避上限。 */
const CRASH_BACKOFF_MAX_MS = 30_000
/** 两次投递之间的最小间隔，避免用户连打好几句时把会话刷爆。 */
const DELIVER_THROTTLE_MS = 3_000
/** 未读消息最多攒多久后合并投递（0 表示不合并，来一条投一条）。 */
const INBOX_POLL_MS = 1_000

/** 本机只有 Windows PowerShell 5.1，不要假设 pwsh 存在。 */
function powershellCandidates() {
  return process.env.DSH_PET_PS ? [process.env.DSH_PET_PS] : ['powershell.exe', 'pwsh']
}

function resolveHelper() {
  const candidates = [
    join(PACKAGE_ROOT, 'helper', 'pet-window.ps1'),
    join(HERE, 'helper', 'pet-window.ps1'),
  ]
  for (const candidate of candidates) if (existsSync(candidate)) return candidate
  return null
}

function dataHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh')
}

function dataDir() {
  return join(dataHome(), 'pet-window')
}

/** 窗口进程自己写的存活标记：{pid, at}，且由窗口每几秒刷新一次 at。 */
function windowLockPath(dir) {
  return join(dir, 'window.lock.json')
}

/** 心跳超过这个时长没刷新，就认为窗口已经不在了。 */
const WINDOW_HEARTBEAT_STALE_MS = Number(process.env.DSH_PET_STALE_MS) > 0
  ? Number(process.env.DSH_PET_STALE_MS)
  : 30_000

/** 起窗口前等第一个心跳等多久（测试里会调小）。
 *
 * 🔴 2026-10-11 从 12 秒改成 4 秒：实测"插件加载 → 窗口出现"稳定在 12~14 秒，
 *   其中约 12 秒全是耗在这里 —— 用户在 DSH 起来之后要盯着空桌面等十几秒，
 *   会以为插件坏了（用户原话："总是要等一会儿对话框才会自己出来，就怕出错不见了"）。
 *   这个等待本来只是为了躲开"另一个实例正在起窗口"的竞态，4 秒足够覆盖；
 *   真撞上了，launch() 里的 isWindowLockLive 二次判断仍然会拦住重复起窗口。 */
const WINDOW_LOCK_WAIT_MS = Number(process.env.DSH_PET_LOCK_WAIT_MS) > 0
  ? Number(process.env.DSH_PET_LOCK_WAIT_MS)
  : 4_000

/**
 * 已经有窗口在跑吗？
 *
 * 🔴 2026-10-11 实测到的坑一：**谁都能起窗口，没有互斥**。
 *   我手动重启（为了看代码改动）起一个，插件的退避重启也起一个，
 *   于是桌面上出现两个窗口、共用一个 queue 文件但各记各的行号，
 *   看起来就是"有的窗口不读新消息"。
 *
 * 🔴 坑二（同一天，更要命）：**`process.kill(pid, 0)` 在本机不可信**。
 *   沙箱环境下它对任何 pid 都抛 ESRCH —— 连探测自己的 pid 都失败。
 *   拿它当存活判据会让互斥永远失效（要么永远"没窗口"、要么永远"有窗口"）。
 *
 * 所以判据改成**心跳时间**：窗口每 3 秒重写一次 lock 的 at 字段，
 * 这里只看 at 是否够新。不依赖信号、不依赖父子关系，两边都认。
 */
function isWindowLockLive(dir, now = Date.now()) {
  let raw
  try {
    raw = readFileSync(windowLockPath(dir), 'utf8')
  } catch {
    return false          // 文件不存在 = 没有窗口，这是唯一该吞掉的错误
  }
  let lock
  try {
    // ⚠ 兼容带 UTF-8 BOM 的 lock：PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写 BOM，
    //   而 JSON.parse 碰到 BOM 直接抛 → 这里会误判成"没有窗口"，然后多起一个窗口
    //   （2026-10-11 实测：桌面上出现两个大肥鱼，同一条消息被读两遍）。
    //   helper 那边已经改成不带 BOM 写；这里再兜一层，免得旧窗口/旧版本又把它带回来。
    lock = JSON.parse(raw.replace(/^\uFEFF/, ''))
  } catch {
    return false          // 半截 JSON（正好撞上写入瞬间）也算没有
  }
  if (!lock || !Number.isFinite(lock.at)) return false
  return (now - lock.at) < WINDOW_HEARTBEAT_STALE_MS
}

/** 读 lock 里的 at；读不到或坏了返回 NaN。 */
function readLockAt(dir) {
  try {
    const lock = JSON.parse(readFileSync(windowLockPath(dir), 'utf8').replace(/^\uFEFF/, ''))
    return Number.isFinite(lock?.at) ? lock.at : NaN
  } catch { return NaN }
}

/**
 * 真的有窗口在跑吗？——"心跳够新"还不够，得看到**心跳在往前走**。
 *
 * 🔴 2026-10-11 实测踩到（用户原话："怎么这次还没启动对话框模组"）：
 *   DSH 重启时窗口会跟着被杀掉，但它的**最后一拍心跳可能才过去几秒**
 *   （本机实测：DSH 22:05:16 重启，窗口最后一拍写在 22:05:11 → 锁"看起来"还很新）。
 *   于是 launch() 认为已经有窗口、安心等 5 分钟再来，用户就盯着空桌面等五分钟。
 *
 * 死窗口的心跳会**停住**，活窗口每 3 秒写一次。所以观察一小段时间：
 *   - at 变大了          → 活的
 *   - at 过期了          → 死的
 *   - 观察期结束还是原值 → **死的**（这条专治"被杀掉但心跳还新"）
 */
async function isWindowAliveByHeartbeat(dir, observeMs = 8_000, stepMs = 700) {
  if (!isWindowLockLive(dir)) return false
  const first = readLockAt(dir)
  const deadline = Date.now() + observeMs
  while (Date.now() < deadline) {
    // ⚠ 这里**不能** unref：等待期如果只剩这一个定时器，事件循环会直接空掉、
    //   这个 await 永远不返回（lock-test 里实测报 "unsettled top-level await"）。
    //   launch() 只在 DSH 运行时跑，多挂 8 秒无所谓。
    await new Promise((resolve) => setTimeout(resolve, stepMs))
    const now = readLockAt(dir)
    if (Number.isFinite(now) && now > first) return true
    if (!isWindowLockLive(dir)) return false
  }
  return false
}

/**
 * 起窗口之前先等一下：刚起的窗口要过一两秒才会写下第一个心跳。
 * 不等的话，插件重启时可能和手动启动器抢着起第二个窗口。
 */
function waitForWindowLock(dir, timeoutMs = WINDOW_LOCK_WAIT_MS, stepMs = 300) {
  const deadline = Date.now() + timeoutMs
  return new Promise((resolve) => {
    const tick = () => {
      if (isWindowLockLive(dir)) return resolve(true)
      if (Date.now() >= deadline) return resolve(false)
      const timer = setTimeout(tick, stepMs)
      if (typeof timer.unref === 'function') timer.unref()
    }
    tick()
  })
}

function logLine(dir, text) {
  try {
    mkdirSync(dir, { recursive: true })
    const stamp = new Date().toISOString().slice(11, 19)
    writeFileSync(join(dir, 'host.log'), `${stamp} [host] ${text}\n`, { flag: 'a' })
  } catch { /* 日志失败不能影响窗口 */ }
}

function stripElectronNodeEnv(env) {
  const cleaned = { ...env }
  for (const key of Object.keys(cleaned)) {
    if (key.toUpperCase() === 'ELECTRON_RUN_AS_NODE') delete cleaned[key]
  }
  return cleaned
}

// ---------------------------------------------------------------- 窗口进程管理

function createWindowSupervisor({ ctx, dir, helper }) {
  const shells = powershellCandidates()
  let shellIndex = 0
  let stopped = false
  let restartTimer = null
  let startedAt = 0
  let crashCount = 0
  let currentChild = null

  const scheduleRestart = (reason, livedMs) => {
    if (stopped || restartTimer !== null) return
    const userClosed = livedMs >= HEALTHY_RUN_MS
    let delay
    if (userClosed) {
      crashCount = 0
      delay = USER_CLOSE_COOLDOWN_MS
      logLine(dir, `${reason}：窗口是被正常关闭的，${Math.round(delay / 60000)} 分钟后再自己回来`)
    } else {
      crashCount += 1
      delay = Math.min(CRASH_BACKOFF_MAX_MS, 2000 * Math.min(crashCount, 15))
      logLine(dir, `${reason}：启动后 ${Math.round(livedMs / 1000)} 秒就退了（第 ${crashCount} 次），${Math.round(delay / 1000)} 秒后重试`)
    }
    restartTimer = setTimeout(() => { restartTimer = null; void launch() }, delay)
    if (typeof restartTimer.unref === 'function') restartTimer.unref()
  }

  async function launch() {
    if (stopped) return
    // 互斥：桌面上已经有一个活着（心跳够新）的窗口就不要再起第二个。
    // 先等一下再判 —— 刚起来的窗口要一两秒才写下第一个心跳。
    if (await waitForWindowLock(dir)) {
      // ⚠ 心跳够新**还不够**：DSH 重启时窗口会被一起杀掉，而它的最后一拍心跳可能
      //   才过去几秒（本机实测：DSH 22:05:16 重启，窗口最后一拍 22:05:11）。
      //   只看"够新"就会安心地等 5 分钟再来 —— 用户看到的是"这次怎么还没启动对话框模组"。
      //   所以再观察一小会儿，确认 at 真的在往前走（死窗口的心跳是停住的）。
      if (await isWindowAliveByHeartbeat(dir)) {
        logLine(dir, '已经有一个窗口在跑（心跳还在往前走），这次不重复拉起')
        if (restartTimer === null && !stopped) {
          restartTimer = setTimeout(() => { restartTimer = null; void launch() }, USER_CLOSE_COOLDOWN_MS)
          if (typeof restartTimer.unref === 'function') restartTimer.unref()
        }
        return
      }
      logLine(dir, '锁上的心跳停住了（窗口是被杀掉的，不是被关的），照常起一个新窗口')
    }
    if (stopped) return
    const shell = shells[shellIndex % shells.length]
    // 显式把数据目录传下去，不靠 DSH_HOME 环境变量传递。
    // 两个原因：① 语义明确，窗口读写哪个目录一眼可见；
    //          ② 命令行里带上它，排查/测试时才能区分"这是哪个实例的窗口"。
    const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', helper, '-DataDir', dir]
    let child
    try {
      child = spawn(shell, args, {
        windowsHide: true,
        stdio: 'ignore',
        detached: false,
        env: stripElectronNodeEnv(process.env),
      })
    } catch (error) {
      logLine(dir, `spawn 抛错（${shell}）：${error.message}`)
      shellIndex += 1
      scheduleRestart('spawn-threw', 0)
      return
    }
    startedAt = Date.now()
    currentChild = child
    logLine(dir, `窗口进程已启动：${shell} (pid=${child.pid ?? '?'})`)
    child.on('error', (error) => {
      logLine(dir, `进程错误：${error.message}`)
      shellIndex += 1
      scheduleRestart('spawn-error', Date.now() - startedAt)
    })
    child.on('exit', (code, signal) => {
      logLine(dir, `窗口进程退出 code=${String(code)} signal=${String(signal)} 存活 ${Math.round((Date.now() - startedAt) / 1000)} 秒`)
      if (!stopped) scheduleRestart('exited', Date.now() - startedAt)
    })
  }

  launch()

  return () => {
    stopped = true
    if (restartTimer !== null) clearTimeout(restartTimer)
    try { currentChild?.kill() } catch { }
    logLine(dir, '插件卸载，窗口不再自动重启')
  }
}

// ---------------------------------------------------------------- 会话投递

/**
 * 会话目录：优先 $DSH_HOME/sessions；本机早期布局是 profiles/<名>/sessions。
 * 找出"最近有写入"的会话目录，和 dsh-selfwake 的判据一致。
 */
function findLatestSessionId(root) {
  let newest = { id: '', mtime: 0 }
  const walk = (dir, depth) => {
    if (depth > 2) return
    let entries
    try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      const p = join(dir, entry.name)
      if (entry.name.startsWith('session-')) {
        let m = 0
        try {
          for (const f of readdirSync(p)) {
            try {
              const s = statSync(join(p, f))
              if (s.mtimeMs > m) m = s.mtimeMs
            } catch { }
          }
        } catch { }
        if (m > newest.mtime) newest = { id: entry.name, mtime: m }
      } else {
        walk(p, depth + 1)
      }
    }
  }
  try { walk(root, 0) } catch { }
  return newest.id
}

function candidateSessionRoots() {
  const home = dataHome()
  const roots = [
    join(home, 'sessions'),
    join(home, 'profiles', process.env.DSH_PROFILE || 'desktop', 'sessions'),
  ]
  // 兜底：数据目录被指到别处时（典型是测试为了不污染用户的 inbox 而改了 DSH_HOME），
  // 会话目录往往还在真实家目录下。不兜这一下，测试就找不到会话、投递全失败，
  // 而那是测试环境的差异、不是插件的问题。
  const realHome = join(homedir(), '.dsh')
  if (resolve(realHome) !== resolve(home)) {
    roots.push(join(realHome, 'sessions'))
    roots.push(join(realHome, 'profiles', process.env.DSH_PROFILE || 'desktop', 'sessions'))
  }
  return roots
}

function resolveSessionsRoot() {
  for (const root of candidateSessionRoots()) {
    if (existsSync(root)) return root
  }
  return candidateSessionRoots()[0]
}

/**
 * 把一句用户的话投进当前活跃会话。
 * 写法照抄 dsh-selfwake 里真机验过的那份：source 必须是 kind:'user'，
 * 投递必须是 followup()。别"优化"这两处。
 */
function deliverToSession(ctx, sessionsRoot, text) {
  const agents = ctx.get?.('agents')
  if (agents === undefined || typeof agents.get !== 'function') {
    return { ok: false, why: '拿不到 agents 服务' }
  }
  const sessionId = findLatestSessionId(sessionsRoot)
  if (sessionId === '') return { ok: false, why: `找不到会话目录（${sessionsRoot}）` }
  let handle
  try { handle = agents.get(sessionId) } catch (error) {
    return { ok: false, why: 'agents.get 抛错：' + String(error?.message ?? error) }
  }
  if (handle === undefined || handle === null) {
    return { ok: false, why: `会话 ${sessionId.slice(0, 20)}… 不在活跃列表（窗口没开？）` }
  }
  const agent = handle.agent ?? handle
  const message = {
    id: `petwindow-${Date.now()}`,
    role: 'user',
    content: [{ type: 'text', text }],
    source: { kind: 'user' },
  }
  const used = []
  try {
    if (typeof agent.followup === 'function') { agent.followup(message); used.push('followup') }
    else if (typeof agent.send === 'function') { agent.send(message, 'next-turn', true); used.push('send') }
    else return { ok: false, why: '这个句柄没有 followup / send 投递口' }
  } catch (error) {
    return { ok: false, why: used.join('+') + ' 抛错：' + String(error?.message ?? error) }
  }
  return { ok: true, sessionId, via: used.join('+') }
}

// ---------------------------------------------------------------- inbox 监听

/**
 * 追加一个"起点标记"并返回它的字节偏移。
 *
 * 为什么要这个：插件重启后如果从 0 开始读，会把历史留言**重投一遍**，
 * 会话里就会突然冒出一堆旧话。标记之后才是我该处理的新消息。
 */
function markInboxStart(inboxPath) {
  try {
    mkdirSync(dirname(inboxPath), { recursive: true })
    const marker = JSON.stringify({ ts: Date.now(), marker: 'pet-window-start' }) + '\n'
    writeFileSync(inboxPath, marker, { flag: 'a' })
    return statSync(inboxPath).size
  } catch {
    return 0
  }
}

function readFrom(inboxPath, offset) {
  let fd
  try {
    const size = statSync(inboxPath).size
    if (size <= offset) return { text: '', offset }
    fd = openSync(inboxPath, 'r')
    const length = size - offset
    const buffer = Buffer.allocUnsafe(length)
    const read = readSync(fd, buffer, 0, length, offset)
    return { text: buffer.subarray(0, read).toString('utf8'), offset: offset + read }
  } catch {
    return { text: '', offset }
  } finally {
    try { if (fd !== undefined) closeSync(fd) } catch { }
  }
}

/**
 * 读取位置的持久化文件。
 *
 * 🔴 2026-10-11 连续踩了两次坑之后加的：
 *   位置只存在内存里时，任何一次文件变动都会错位 ——
 *   ① 文件被**截短** → 位置线跑到末尾之后 → 静默跳过，用户说话没人应；
 *   ② 文件被**撑长**（我当时为了绕开 ① 干的事）→ 位置线相对后退 →
 *      同一段留言被**重复投递**（用户连收两遍"我喜欢你"）。
 *   把位置落盘之后，重启也不丢，也不会因为文件变动而重复或跳过。
 */
function inboxOffsetPath(dir) {
  return join(dir, 'inbox.offset')
}

function readPersistedOffset(dir) {
  try {
    const value = Number(readFileSync(inboxOffsetPath(dir), 'utf8').trim())
    return Number.isInteger(value) && value >= 0 ? value : null
  } catch {
    return null
  }
}

function persistOffset(dir, offset) {
  try {
    writeFileSync(inboxOffsetPath(dir), String(offset), 'utf8')
  } catch { /* 落盘失败不致命：内存里的位置这一轮仍然有效 */ }
}

function createInboxWatcher({ ctx, dir, sessionsRoot }) {
  const inboxPath = join(dir, 'inbox.jsonl')

  // 优先用上次记住的位置；没有（首次运行）或文件被截短过，才重新打起点标记。
  let size = 0
  try { size = statSync(inboxPath).size } catch { size = 0 }
  const remembered = readPersistedOffset(dir)
  let offset
  if (remembered !== null && remembered <= size) {
    offset = remembered
    logLine(dir, `沿用上次记住的读取位置：${offset} 字节（文件 ${size} 字节）`)
  } else {
    if (remembered !== null) {
      logLine(dir, `记的位置 ${remembered} 字节超过文件长度 ${size} 字节（文件被重写过），重新打起点标记`)
    }
    offset = markInboxStart(inboxPath)
  }
  persistOffset(dir, offset)

  let lastDeliveredAt = 0
  let stopped = false
  logLine(dir, `开始监听用户留言：${inboxPath}（从字节 ${offset} 起）`)

  const tick = () => {
    if (stopped) return
    try {
      // 🔴 2026-10-11 实测踩到：inbox 被**重写变短**时（我清理过测试垃圾，
      //   从 1010 字节缩到 161 字节），内存里的 offset 已经超过文件长度，
      //   于是每次只读到空内容、**静默跳过** —— 用户在小窗里说话再也没人应。
      //   queue 那边我修过同一个坑，inbox 这侧当时漏了。
      //   判据：文件比 offset 短 → 认定被重写，从头读。
      let size = 0
      try { size = statSync(inboxPath).size } catch { size = 0 }
      if (size < offset) {
        logLine(dir, `收件箱被重写了（${offset} → ${size} 字节），重置读取位置`)
        offset = 0
        persistOffset(dir, 0)
      }

      const { text, offset: next } = readFrom(inboxPath, offset)
      offset = next
      persistOffset(dir, offset)
      if (text === '') return

      const messages = []
      for (const raw of text.split('\n')) {
        const line = raw.trim()
        if (line === '') continue
        let parsed
        try { parsed = JSON.parse(line) } catch { continue }   // 半行/坏行跳过
        if (parsed?.marker) continue
        if (typeof parsed?.text === 'string' && parsed.text.trim() !== '') messages.push(parsed)
      }
      if (messages.length === 0) return

      const text2 = messages.map((m) => m.text.trim()).join('\n')
      const since = Date.now() - lastDeliveredAt
      if (since < DELIVER_THROTTLE_MS) {
        // 用户打得太快：留到下一轮再投，避免刷爆会话
        logLine(dir, `用户连发了 ${messages.length} 条，节流中（距上次 ${since}ms），下一轮再投`)
        offset -= Buffer.byteLength(text, 'utf8')   // 回退，下一轮重新解析这段
        persistOffset(dir, offset)
        return
      }

      const notice = `【桌面小窗里的留言】${text2}\n（在上面那个窗口里回我一句就说回给你的话：往 queue.jsonl 追加一行 JSON，越短越好，别放代码和清单。）`
      const result = deliverToSession(ctx, sessionsRoot, notice)
      if (result.ok) {
        lastDeliveredAt = Date.now()
        logLine(dir, `已把用户留言投进会话（${result.via} ${String(result.sessionId).slice(0, 20)}…）：${text2.slice(0, 30)}`)
      } else {
        logLine(dir, `投递失败：${result.why}`)
      }
    } catch (error) {
      logLine(dir, `监听失败：${String(error?.message ?? error)}`)
    }
  }

  const timer = setInterval(tick, INBOX_POLL_MS)
  if (typeof timer.unref === 'function') timer.unref()

  return () => { stopped = true; clearInterval(timer); logLine(dir, '停止监听用户留言') }
}

// ---------------------------------------------------------------- 插件入口

export function apply(ctx) {
  const dir = dataDir()
  const helper = resolveHelper()

  if (helper === null) {
    logLine(dir, '找不到 helper/pet-window.ps1，窗口不会启动')
    ctx.logger?.warn?.('dsh-pet-window: helper/pet-window.ps1 不存在')
    return
  }

  try { mkdirSync(dir, { recursive: true }) } catch { }

  const sessionsRoot = resolveSessionsRoot()
  logLine(dir, `会话目录：${sessionsRoot}`)

  const stopWindow = createWindowSupervisor({ ctx, dir, helper })
  const stopInbox = createInboxWatcher({ ctx, dir, sessionsRoot })

  ctx.effect(() => () => {
    try { stopInbox() } catch { }
    try { stopWindow() } catch { }
  }, 'dsh-pet-window: native window + inbox bridge')
}

export default { name, apply }

// 供测试使用的内部出口
export const __test = { findLatestSessionId, deliverToSession, markInboxStart, readFrom, isWindowLockLive, isWindowAliveByHeartbeat, readLockAt }
