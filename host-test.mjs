// dsh-pet-window 宿主侧测试：用假 ctx 直接跑真插件代码，**不动用户的 DSH profile**。
//
// 覆盖两种场景（互斥就是做这个测试时才补上的，两种都必须验）：
//   A. 桌面上没有窗口 → 插件应当自己拉起一个；
//   B. 桌面上已有活着的窗口（心跳够新）→ 插件**不能**再起第二个。
//      B 是 2026-10-11 实测踩到的坑：没有互斥时手动重启和插件重启会各起一个，
//      两个窗口共用一个 queue 文件、各记各的行号，看起来像"有的窗口不读新消息"。
//
// 用法：node host-test.mjs

// 🔴 必须**在 import index.js 之前**把数据目录指到临时目录。
//   否则测试会和"你 DSH 里正在跑的那个插件"抢同一个数据目录和互斥锁：
//   我在这里杀掉窗口，宿主插件立刻按崩溃退避重新拉一个，
//   于是"清理后没有窗口了""没有起新进程"这类断言就会假失败（2026-10-11 实测）。
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
const TEST_HOME = mkdtempSync(join(tmpdir(), 'petw-host-'))
process.env.DSH_HOME = TEST_HOME

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { apply } from './index.js'

const DATA = join(TEST_HOME, 'pet-window')
const HOST_LOG = join(DATA, 'host.log')
const WINDOW_LOG = join(DATA, 'window.log')
const LOCK = join(DATA, 'window.lock.json')

let pass = 0
let fail = 0
const check = (what, ok, detail = '') => {
  if (ok) { pass += 1; console.log(`  [OK ] ${what}${detail ? '  ' + detail : ''}`) }
  else { fail += 1; console.log(`  [FAIL] ${what}${detail ? '  ' + detail : ''}`) }
}

const readLog = () => { try { return readFileSync(HOST_LOG, 'utf8') } catch { return '' } }
const readWindowLog = () => { try { return readFileSync(WINDOW_LOG, 'utf8') } catch { return '' } }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function waitFor(predicate, { timeoutMs = 25_000, stepMs = 300, label = '' } = {}) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    let value
    try { value = predicate() } catch { value = false }
    if (value) return value
    await sleep(stepMs)
  }
  if (label) console.log(`    （等待超时：${label}）`)
  return false
}

/** 起一个只实现插件真正用到那两个成员的假 ctx。 */
function makeCtx() {
  const disposers = []
  const ctx = {
    logger: { warn: () => { }, error: () => { }, debug: () => { } },
    effect: (setup) => { const d = setup(); if (typeof d === 'function') disposers.push(d) },
    get: () => undefined,   // 没有 agents 服务：inbox 投递会失败，但监听照跑
  }
  return { ctx, disposers }
}

/**
 * 只找**本次测试**起的窗口进程。
 *
 * ⚠ 两个坑都踩过（2026-10-11）：
 *   ① 不能用"命令行含 pet-window.ps1"来筛 —— 会连你 DSH 里那个真实窗口一起算进来；
 *   ② 光加 `-DataDir` + 测试路径还不够 —— **诊断用的 powershell 子进程自己**
 *      命令行里也带着这些字符串，会自匹配。
 *   所以要求命令行同时含 `-File`（真实窗口有，我的诊断命令没有）和本次数据目录。
 */
function findWindowPids() {
  const out = spawnSync('powershell.exe', ['-NoProfile', '-Command',
    `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '-File' -and $_.CommandLine -like '*${DATA}*' } | ForEach-Object { $_.ProcessId }`],
    { encoding: 'utf8' })
  return (out.stdout || '').split(/\r?\n/).map((s) => Number(s.trim())).filter((n) => Number.isInteger(n) && n > 0)
}

function killAllWindows() {
  spawnSync('powershell.exe', ['-NoProfile', '-Command',
    `Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match '-File' -and $_.CommandLine -like '*${DATA}*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`],
    { encoding: 'utf8' })
}

console.log(`数据目录：${DATA}\n`)
mkdirSync(DATA, { recursive: true })

// ---------------------------------------------------------------- 场景 A
console.log('=== 场景 A：桌上没有窗口，插件应当自己拉起一个 ===')
killAllWindows()
await sleep(1200)
rmSync(LOCK, { force: true })
rmSync(HOST_LOG, { force: true })
rmSync(WINDOW_LOG, { force: true })

const a = makeCtx()
try {
  apply(a.ctx)
  check('apply() 没有抛错', true)
} catch (error) {
  check('apply() 没有抛错', false, error.message)
}
check('注册了清理函数', a.disposers.length > 0)

const spawned = await waitFor(() => /窗口进程已启动/.test(readLog()), { label: '插件拉起窗口' })
check('插件拉起了窗口进程', Boolean(spawned))
const pidMatch = /pid=(\d+)/.exec(readLog())
check('日志里有 pid', pidMatch !== null, pidMatch ? `pid=${pidMatch[1]}` : '')
if (pidMatch) {
  const info = spawnSync('powershell.exe', ['-NoProfile', '-Command',
    `(Get-CimInstance Win32_Process -Filter "ProcessId=${pidMatch[1]}").CommandLine`], { encoding: 'utf8' })
  const cmd = (info.stdout || '').trim()
  console.log(`    该 pid 的命令行：${cmd || '(取不到，进程可能已退出)'}`)
  check('这个窗口用的数据目录是本次测试目录', cmd.includes(DATA), cmd ? '' : '进程不在')
}
check('窗口进程确实在跑', findWindowPids().length > 0, `pids=${findWindowPids().join(',')}`)

const litUp = await waitFor(() => /窗口已显示/.test(readWindowLog()), { label: '窗口完成初始化' })
check('窗口完成初始化（写了「窗口已显示」）', Boolean(litUp))

const heartbeat = await waitFor(() => existsSync(LOCK), { timeoutMs: 6000, label: '窗口写下心跳' })
check('窗口写下了心跳锁', Boolean(heartbeat))

// 队列读取**不在这里测**。
// 它由 e2e.ps1（真窗口 + 真文件）和 read-probe.ps1（隔离验证 helper 的读取写法）覆盖，
// 两份都是确定性、全绿的。放在这里会引入"测试自己写文件"的时序耦合，
// 而且已经单独验证过 helper 的读取逻辑没问题（73 字节 / 1 行 / 解析成功）。
//
// 这里只测插件自己的职责：**拉起窗口、窗口真在跑、已有窗口时不重复拉、卸载能收干净**。

console.log('\n--- 走插件清理路径 ---')
for (const d of a.disposers) { try { d() } catch (error) { check('清理不抛错', false, error.message) } }
check('清理函数已执行，没有抛错', true)

// ---------------------------------------------------------------- 场景 B
console.log('\n=== 场景 B：已有活着的窗口（心跳在推进），插件不能再起第二个 ===')
rmSync(HOST_LOG, { force: true })

// 伪造"活着的窗口"：**心跳必须一直在往前走**。
// ⚠ 2026-10-11 判据改过：只看"at 够新"会被"被杀掉但心跳还新"的锁骗到
//   （用户原话："怎么这次还没启动对话框模组"，干等五分钟）。
//   所以静态写一次 at 已经**不算**活着了 —— 那种情况反而应该起窗口（见场景 C）。
const ticker = setInterval(() => {
  try { writeFileSync(LOCK, JSON.stringify({ pid: process.pid, at: Date.now() }), 'utf8') } catch { }
}, 300)
writeFileSync(LOCK, JSON.stringify({ pid: process.pid, at: Date.now() }), 'utf8')

const b = makeCtx()
try {
  apply(b.ctx)
  check('apply() 没有抛错', true)
} catch (error) {
  check('apply() 没有抛错', false, error.message)
}

const deferred = await waitFor(() => /不重复拉起/.test(readLog()), { label: '插件识别到已有窗口' })
check('插件识别出"已有窗口（心跳在走）"，选择不拉起', Boolean(deferred))
check('日志里没有"窗口进程已启动"', !/窗口进程已启动/.test(readLog()))
check('插件没有记录任何 spawn 错误', !/spawn 抛错|spawn 失败/.test(readLog()))

for (const d of b.disposers) { try { d() } catch { } }
clearInterval(ticker)

// ---------------------------------------------------------------- 场景 C
console.log('\n=== 场景 C：锁够新但心跳停住（窗口是被杀掉的）→ 应当照常起窗口 ===')
// 这就是 2026-10-11 22:05 用户遇到的那次：DSH 重启把窗口一起带走，
// 而它的最后一拍心跳才过去几秒，旧判据（只看"够新"）让插件干等了 5 分钟。
rmSync(HOST_LOG, { force: true })
writeFileSync(LOCK, JSON.stringify({ pid: process.pid, at: Date.now() }), 'utf8')   // 写一次就不再动

const c = makeCtx()
try {
  apply(c.ctx)
  check('apply() 没有抛错', true)
} catch (error) {
  check('apply() 没有抛错', false, error.message)
}

const revived = await waitFor(() => /窗口进程已启动/.test(readLog()), { timeoutMs: 35_000, label: '插件看穿假活、起新窗口' })
check('心跳停住 → 照常拉起新窗口（不再干等 5 分钟）', Boolean(revived))
check('日志里点明了原因是"心跳停住"', /心跳停住/.test(readLog()))
for (const d of c.disposers) { try { d() } catch { } }

// ---------------------------------------------------------------- 恢复现场
console.log('\n=== 收尾 ===')
killAllWindows()
await sleep(1500)
rmSync(LOCK, { force: true })
check('锁已清理（不影响你自己起窗口）', !existsSync(LOCK))

console.log('\n注：不做"进程数"断言。本机很难干净隔离 —— ① 你 DSH 里那个真实插件\n' +
  '    会实时补窗口进程；② 我自己的诊断命令命令行里也含同样的路径片段，会自匹配。\n' +
  '    "不会重复起窗口"这件事由上面场景 B 的 defer 断言直接覆盖。')

console.log(`\n=== 宿主侧测试：${pass} 通过 / ${fail} 失败 ===`)
process.exit(fail > 0 ? 1 : 0)
