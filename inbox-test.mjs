// 验证桥梁：用户在窗口里打的字，能不能自动投进会话把我叫醒。
//
// 这是本项目最关键的一条测试：没有它，窗口就是单向的 —— 用户说话没人应。
// 用假 ctx 跑真插件代码，只替换"会话投递"那一层的假 agent。
//
// 用法：node inbox-test.mjs

// 🔴 必须在 import index.js **之前**把数据目录指到临时目录。
//   否则这个测试会往**用户真实的** inbox.jsonl 里写"你在吗？我按了发送"这类
//   测试文案，而正在运行的插件会把它当成用户留言投进会话 ——
//   2026-10-11 实际发生过：用户在窗口里收到"这是第二句"这种莫名其妙的话。
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
const TEST_HOME = mkdtempSync(join(tmpdir(), 'petw-inbox-'))
process.env.DSH_HOME = TEST_HOME

import { appendFileSync, mkdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { apply } from './index.js'

const DATA = join(TEST_HOME, 'pet-window')
const INBOX = join(DATA, 'inbox.jsonl')
const HOST_LOG = join(DATA, 'host.log')

let pass = 0
let fail = 0
const check = (what, ok, detail = '') => {
  if (ok) { pass += 1; console.log(`  [OK ] ${what}${detail ? '  ' + detail : ''}`) }
  else { fail += 1; console.log(`  [FAIL] ${what}${detail ? '  ' + detail : ''}`) }
}

const delivered = []
const got = {
  get(name) {
    if (name !== 'agents') return undefined
    return {
      get(sessionId) {
        return {
          sessionId,
          agent: {
            followup(message) {
              delivered.push({ sessionId, message })
            },
          },
        }
      },
    }
  },
}

const effects = []

/** 造一个假 ctx。要在"重启"场景里再造一个，所以抽成工厂。 */
function makeCtx() {
  const instance = {
    logger: { warn: () => { }, error: () => { }, debug: () => { } },
    effect: (setup, label) => { effects.push(label ?? 'effect'); const d = setup(); if (typeof d === 'function') instance._dispose = d },
    get: got.get,
  }
  return instance
}

const ctx = makeCtx()

console.log(`数据目录：${DATA}\n`)
mkdirSync(DATA, { recursive: true })

console.log('--- 启动插件 ---')
try {
  apply(ctx)
  check('apply() 没有抛错（含 inbox 监听）', true)
} catch (error) {
  check('apply() 没有抛错（含 inbox 监听）', false, error.message)
}
check('提供了清理函数', typeof ctx._dispose === 'function')

// 等窗口进程起来（本测试不关心它，但别让它干扰）
await new Promise((r) => setTimeout(r, 2500))

console.log('\n--- 模拟：用户在窗口里打了一句话 ---')
const before = statSync(INBOX).size
const userLine = JSON.stringify({ ts: Date.now(), text: '你在吗？我按了发送', local: new Date().toISOString().slice(0, 19) })
appendFileSync(INBOX, userLine + '\n', 'utf8')
console.log(`  已追加到 inbox.jsonl（偏移 ${before}）：${userLine}`)

// 等投递（轮询 1 秒 + 节流余量）
const deadline = Date.now() + 8000
while (delivered.length === 0 && Date.now() < deadline) {
  await new Promise((r) => setTimeout(r, 250))
}

check('用户的留言被投进了会话', delivered.length > 0, `投递 ${delivered.length} 次`)
if (delivered.length > 0) {
  const text = delivered[0].message.content?.[0]?.text ?? ''
  check('投递内容包含用户原话', text.includes('我按了发送'), text.slice(0, 60).replace(/\n/g, ' '))
  check('投递内容提示我该去哪回话', text.includes('queue.jsonl'))
  check('source 是 kind:user（照抄 selfwake 验过的写法）', delivered[0].message.source?.kind === 'user')
  check('role 是 user', delivered[0].message.role === 'user')
  check('投到了真实会话 id', String(delivered[0].sessionId).startsWith('session-'), delivered[0].sessionId)
}

console.log('\n--- 不应重复投递同一条 ---')
const countAfterFirst = delivered.length
await new Promise((r) => setTimeout(r, 3000))
check('等待 3 秒后没有重复投递', delivered.length === countAfterFirst, `${countAfterFirst} → ${delivered.length}`)

console.log('\n--- 坏行与标记行不应触发投递 ---')
appendFileSync(INBOX, '{这不是合法JSON\n', 'utf8')
appendFileSync(INBOX, JSON.stringify({ ts: Date.now(), marker: 'pet-window-start' }) + '\n', 'utf8')
await new Promise((r) => setTimeout(r, 2500))
check('坏行和标记行没有产生投递', delivered.length === countAfterFirst, `${countAfterFirst} → ${delivered.length}`)

console.log('\n--- 第二条正常留言仍能投递 ---')
appendFileSync(INBOX, JSON.stringify({ ts: Date.now(), text: '这是第二句' }) + '\n', 'utf8')
const deadline2 = Date.now() + 8000
while (delivered.length === countAfterFirst && Date.now() < deadline2) {
  await new Promise((r) => setTimeout(r, 250))
}
check('第二条留言也被投递', delivered.length > countAfterFirst, `投递 ${delivered.length} 次`)

console.log('\n--- 宿主日志里应有投递记录 ---')
let hostLog = ''
try { hostLog = readFileSync(HOST_LOG, 'utf8') } catch { }
check('host.log 记录了监听启动', /开始监听用户留言/.test(hostLog))
check('host.log 记录了投递成功', /已把用户留言投进会话/.test(hostLog))

console.log('\n--- 插件重启后不能重复投递同一段留言 ---')
// 这一条是 2026-10-11 用户实测反馈出来的：他在小窗里收到同一句话两遍。
// 根因是读取位置只存在内存里 —— 文件一被重写（我当时为了排障撑长过它），
// 位置线相对后退，同一段留言就被再投一次。现在位置落盘了，重启应当接着上次读。
try { ctx._dispose?.() } catch { }
await new Promise((r) => setTimeout(r, 800))

const beforeRestart = delivered.length
const restartCtx = makeCtx()
apply(restartCtx)
await new Promise((r) => setTimeout(r, 4000))     // 给监听几轮时间
check('重启后没有重复投递旧留言', delivered.length === beforeRestart, `${beforeRestart} → ${delivered.length}`)

// 重启后**新**留言仍要能投递（别把功能修没了）
appendFileSync(INBOX, JSON.stringify({ ts: Date.now(), text: '重启之后的新一句' }) + '\n', 'utf8')
const deadline3 = Date.now() + 8000
while (delivered.length === beforeRestart && Date.now() < deadline3) {
  await new Promise((r) => setTimeout(r, 250))
}
check('重启后新留言照常投递', delivered.length > beforeRestart, `投递 ${delivered.length} 次`)
try { restartCtx._dispose?.() } catch { }

console.log('\n--- 收尾 ---')
await new Promise((r) => setTimeout(r, 1200))
check('监听已停止', true)

console.log(`\n=== 桥梁测试：${pass} 通过 / ${fail} 失败 ===`)
process.exit(fail > 0 ? 1 : 0)
