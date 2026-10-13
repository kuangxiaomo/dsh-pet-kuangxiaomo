// 验证窗口互斥的判据：不是 pid 存活，而是**心跳够不够新 + 心跳有没有在往前走**。
//
// 为什么不用 pid 存活：本机实测 process.kill(pid, 0) 对任何 pid 都抛 ESRCH
// （连探测自己的 pid 都失败），拿它当判据会让互斥永远失灵。
//
// ⚠ 2026-10-11 改成在**临时目录**里测：以前这个测试直接改真窗口的 window.lock.json，
//   而真窗口每 3 秒又把它写回去 —— 两边抢同一个文件，测试既可能假失败，
//   也可能在插件恰好检查的那一瞬间被读到假心跳（那本身就是"多起一个窗口"的来源之一）。
//
// 用法：node lock-test.mjs

import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { __test } from './index.js'

const DATA = join(
  process.env.TEMP || join(process.env.USERPROFILE, 'AppData', 'Local', 'Temp'),
  'petw-locktest-' + process.pid,
)
mkdirSync(DATA, { recursive: true })
const LOCK = join(DATA, 'window.lock.json')

let pass = 0
let fail = 0
const check = (what, ok, detail = '') => {
  if (ok) { pass += 1; console.log(`  [OK ] ${what}${detail ? '  ' + detail : ''}`) }
  else { fail += 1; console.log(`  [FAIL] ${what}${detail ? '  ' + detail : ''}`) }
}

const probe = __test?.isWindowLockLive
const probeAlive = __test?.isWindowAliveByHeartbeat
if (typeof probe !== 'function' || typeof probeAlive !== 'function') {
  console.log('index.js 没导出需要的判据函数，无法测试')
  process.exit(1)
}

const writeLock = (value) => writeFileSync(LOCK, value, 'utf8')
const lockJson = (at) => JSON.stringify({ pid: 1234, at })

console.log(`测试目录（隔离，不碰真窗口）：${DATA}\n`)

console.log('--- 没有锁文件 ---')
rmSync(LOCK, { force: true })
check('无锁 → 没有窗口在跑', probe(DATA) === false)

console.log('\n--- 心跳很新（刚刚写的）---')
writeLock(lockJson(Date.now()))
check('心跳 0 秒 → 窗口在跑', probe(DATA) === true)

console.log('\n--- 心跳 10 秒前 ---')
writeLock(lockJson(Date.now() - 10_000))
check('心跳 10 秒 → 仍算在跑（阈值 30 秒）', probe(DATA) === true)

console.log('\n--- 心跳 31 秒前（超过阈值）---')
writeLock(lockJson(Date.now() - 31_000))
check('心跳 31 秒 → 判定为没了', probe(DATA) === false)

console.log('\n--- 心跳 5 分钟前（典型"窗口被关了"）---')
writeLock(lockJson(Date.now() - 300_000))
check('心跳 5 分钟 → 判定为没了', probe(DATA) === false)

console.log('\n--- 带 UTF-8 BOM 的 lock（PowerShell `Set-Content -Encoding UTF8` 的默认行为）---')
// ⚠ 2026-10-11 的实战教训：helper 以前就是用 Set-Content 写 lock 的，文件开头是 EF BB BF，
//   Node 的 JSON.parse 直接抛 → 插件判定"没有窗口" → 退避重启一到就再起一个，
//   桌面上出现两个大肥鱼、同一条消息被读两遍。helper 已改成不带 BOM 写，这里再兜一层。
writeLock('\uFEFF' + lockJson(Date.now()))
check('带 BOM 的心跳仍然算"窗口在跑"', probe(DATA) === true)

console.log('\n--- 坏数据不该让插件崩 ---')
writeLock('{这不是合法JSON')
check('坏 JSON → 判定为没了，且不抛错', probe(DATA) === false)
writeLock(JSON.stringify({ pid: 1234 }))
check('缺 at 字段 → 判定为没了', probe(DATA) === false)
writeLock('null')
check('null → 判定为没了', probe(DATA) === false)

console.log('\n--- 🔴 心跳"停住"的锁：窗口其实早被杀了（DSH 重启后最常见的假活）---')
writeLock(lockJson(Date.now() - 2_000))   // 够新，但再也不会变
check('心跳够新 → 只看 isWindowLockLive 会说"在跑"（这就是骗人的那一步）', probe(DATA) === true)
const stuckAlive = await probeAlive(DATA, 1_600, 300)
check('观察 1.6 秒心跳没动 → 判定窗口已死', stuckAlive === false)

console.log('\n--- 心跳在推进的锁：窗口真的活着 ---')
const ticker = setInterval(() => {
  try { writeLock(lockJson(Date.now())) } catch { }
}, 200)
const tickingAlive = await probeAlive(DATA, 2_000, 300)
clearInterval(ticker)
check('心跳在往前走 → 判定窗口活着', tickingAlive === true)

rmSync(DATA, { recursive: true, force: true })

console.log(`\n=== 互斥判据测试：${pass} 通过 / ${fail} 失败 ===`)
process.exit(fail > 0 ? 1 : 0)
