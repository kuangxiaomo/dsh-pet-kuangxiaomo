// 隔离验证：新的"收起注入原文"逻辑，能不能在**不同 DOM 结构**下都命中。
//
// 为什么做这个：原版逻辑按内部编号找元素（.dsh-recall-bubble / [data-chat-flow-kind="user"]），
// 包在 DSH 0.2.0-rc.2 上一个都匹配不到，导致注入原文永远留在页面上，用户看到"自问自答"。
// 新逻辑改成**从带零宽标记的文本节点出发**，只藏它所在的那条消息。
//
// 这里用 jsdom 不可行（没有依赖），改用最小复刻：把 helper 的三段选择逻辑抄进一个纯函数，
// 在几个手写的 DOM 树上跑 —— 重点是验"命中"和"不误伤"，不是验浏览器行为。

import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const CLIENT = join(process.env.USERPROFILE, '.dsh', 'profiles', 'desktop', 'node_modules', 'dsh-selfwake', 'client.js')
const src = readFileSync(CLIENT, 'utf8')

let pass = 0
let fail = 0
const check = (what, ok, detail = '') => {
  if (ok) { pass += 1; console.log(`  [OK ] ${what}${detail ? '  ' + detail : ''}`) }
  else { fail += 1; console.log(`  [FAIL] ${what}${detail ? '  ' + detail : ''}`) }
}

// ---- 把新逻辑从 client.js 里"抽出来"做静态检查 ----
// ⚠ 检查前先剥掉注释：旧选择器仍然出现在注释里（那是在说明"为什么改它"），
//   不剥掉的话断言会把注释当代码，假失败。
const code = src
  .replace(/\/\*[\s\S]*?\*\//g, '')   // 块注释
  .replace(/(^|[^:])\/\/[^\n]*/g, '$1') // 行注释（避免误伤 http:// 这种）

console.log('--- 静态检查：新逻辑的关键特征是否都在 ---')
check('代码里不再用那个已失效的选择器',
  !/querySelectorAll\(\s*['"]\.dsh-recall-bubble,\s*\[data-chat-flow-kind="user"\]/.test(code))
check('改成从带零宽标记的文本节点出发', /createTreeWalker\(document\.body, NodeFilter\.SHOW_TEXT\)/.test(code))
check('优先用 data-chat-flow-kind 定位消息容器', /hasAttribute\('data-chat-flow-kind'\)/.test(code))
check('保留了"只认标记、不按 class 一刀切"的原则', /isInject/.test(code))
check('仍能把分段标记拆成多行（旧功能没被弄坏）', /splitSegmentsInBubbles/.test(code))
check('自动发送仍按按钮名找（aria-label 含插话发送）', /插话发送/.test(code))

console.log('\n--- 逐字检查：往上找容器的循环必须"找到就停" ---')
// 旧写法是继续往上走、最后可能落到整个对话流；新写法必须 break
const loopBlock = /for \(let depth = 0; depth < 8 && element; depth \+= 1\) \{[\s\S]*?\n\s*\}/.exec(code)
check('找到了上溯循环', loopBlock !== null)
if (loopBlock) {
  check('循环里有 break（找到消息容器就停，不继续上溯）', /break/.test(loopBlock[0]))
  check('循环判定的是 data-chat-flow-kind', /data-chat-flow-kind/.test(loopBlock[0]))
}

console.log('\n--- 逻辑复刻：在手写 DOM 上跑一遍判据 ---')
// 复刻 hideInject 的"选定目标"部分（不依赖真 DOM，用简化的节点表示）
const ZW = '\u200B'
const isInject = (text) => String(text || '').indexOf(ZW) >= 0

/** 简化节点：{ tag, className, attrs, text, children, parent, style } */
function makeNode(tag, { className = '', attrs = {}, text = '', children = [] } = {}) {
  const node = { tagName: tag, className, attrs, text, children, parent: null, style: {} }
  for (const c of children) { c.parent = node }
  return node
}
function flatten(node, out = []) {
  if (node.tagName === '#text') { out.push(node); return out }
  for (const c of node.children) flatten(c, out)
  return out
}
function selectTarget(textNode) {
  let element = textNode.parent
  let target = null
  for (let depth = 0; depth < 8 && element; depth += 1) {
    if (element.attrs && 'data-chat-flow-kind' in element.attrs) { target = element; break }
    element = element.parent
  }
  if (!target) {
    element = textNode.parent
    for (let depth = 0; depth < 8 && element; depth += 1) {
      const cls = typeof element.className === 'string' ? element.className : ''
      if (element.tagName === 'LI' || cls.indexOf('dsh-recall-bubble') >= 0) { target = element; break }
      element = element.parent
    }
  }
  if (!target) target = textNode.parent
  return target
}

// 结构 A：新版 DSH —— 消息容器带 data-chat-flow-kind
const msgA = makeNode('DIV', { attrs: { 'data-chat-flow-kind': 'user' } })
const innerA = makeNode('DIV', { children: [makeNode('#text', { text: ZW + '爪子贴着桌面有点凉' })] })
msgA.children = [innerA]; innerA.parent = msgA
const rowA = makeNode('DIV', { children: [msgA] }); msgA.parent = rowA
const tA = flatten(rowA).find((n) => n.tagName === '#text')
check('结构 A（有 data-chat-flow-kind）选中消息容器本身', selectTarget(tA) === msgA)

// 结构 B：老结构 —— 只有 .dsh-recall-bubble
const bubbleB = makeNode('DIV', { className: 'dsh-recall-bubble' })
const tB = makeNode('#text', { text: ZW + '身上有点懒洋洋的' })
bubbleB.children = [tB]; tB.parent = bubbleB
const rowB = makeNode('DIV', { children: [bubbleB] }); bubbleB.parent = rowB
check('结构 B（只有 .dsh-recall-bubble）选中气泡本身', selectTarget(tB) === bubbleB)

// 结构 C：两个都没有 —— 必须退回到直接父元素，绝不能落到对话流
const flowC = makeNode('DIV', { className: 'chat-flow' })
const wrapC = makeNode('SPAN', { children: [] }); wrapC.parent = flowC
const tC = makeNode('#text', { text: ZW + '肚子咕噜叫了' }); tC.parent = wrapC
wrapC.children = [tC]; flowC.children = [wrapC]
check('结构 C（都没有）退回到直接父元素，不碰对话流', selectTarget(tC) === wrapC)

// 结构 D：正常用户消息（没有标记）—— 判据必须为 false，不能被误伤
const normalText = '这是一条正常消息'
check('正常用户消息不会被判定为注入', isInject(normalText) === false)

console.log(`\n=== 收起逻辑验证：${pass} 通过 / ${fail} 失败 ===`)
process.exit(fail > 0 ? 1 : 0)
