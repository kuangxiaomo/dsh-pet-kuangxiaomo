# dsh-pet-window

住在桌面上的大肥鱼：一个**独立窗口**，里面只有立绘、我的一句话、和你说话的地方。

> **English TL;DR** — A plugin for DeepSeek Harness that puts a *real* desktop window on your
> screen (native WPF, always-on-top, survives minimizing DSH): a character sprite, one short
> line from the agent, and one input box. It talks to the agent through two local JSONL files
> (`inbox.jsonl` / `queue.jsonl`) — no HTTP, no credentials, no telemetry. Windows only.
> The sprite is **not** bundled (see [`NOTICE-assets.md`](NOTICE-assets.md)) — drop your own
> PNG at `assets/DSniang1.png`.
>
> **Install** — `npx -y @deepseek-ai/dsh plugin --profile desktop add "file:C:\path\to\dsh-pet-window"`,
> then fully restart DSH (tray included).

不是网页挂件 —— 它是一个真正的 Windows 窗口，DSH 最小化、你切到别的程序，它都还在，
而且始终置顶。这是它和 `dsh-whale-widget` 最本质的区别：后者只能画在 DSH 页面里。

```
┌─────────────────────────┐
│  我的一句话（最多三行）    │   ← queue.jsonl 里读到的
├─────────────────────────┤
│        🐋 立绘           │   ← DSniang1.png，可拖动
├─────────────────────────┤
│  说点什么…        [发送]  │   → 写进 inbox.jsonl
└─────────────────────────┘
```

## 装法

**方式 A：桌面端插件管理器（推荐）**

在 DSH 桌面端左侧「插件」页 →「添加插件」，填这一行（**本地路径**）：

```
file:C:\path\to\dsh-pet-window
```

装完**完整退出 DSH（含托盘）再启动**。窗口应该自己出现。首次安装必须重开客户端 ——
组合树是启动时装载的。

**方式 B：命令行**

```powershell
npx -y @deepseek-ai/dsh plugin --profile desktop add "file:C:\path\to\dsh-pet-window"
```

装完同样要完整重启。

**方式 C：手动改 profile（不推荐，仅在 A/B 都不行时）**

编辑 `%USERPROFILE%\.dsh\profiles\desktop\package.json`：

```jsonc
{
  "dependencies": {
    // 加这一行
    "dsh-pet-window": "file:C:\\path\\to\\dsh-pet-window"
  },
  "dsh": {
    "profile": {
      "bundles": [
        // 加这一行
        "dsh-pet-window"
      ]
    }
  }
}
```

然后在 profile 目录跑一次包管理器安装，再完整重启 DSH。

## 装完怎么确认它在工作

三处日志，按顺序看：

| 文件 | 说明 |
|---|---|
| `%USERPROFILE%\.dsh\pet-window\host.log` | 插件侧：什么时候把窗口拉起来、重启过几次 |
| `%USERPROFILE%\.dsh\pet-window\window.log` | 窗口侧：立绘有没有加载、读到了哪句话 |
| `%USERPROFILE%\.dsh\pet-window\window-state.json` | 你上次把窗口拖到哪了 |

窗口没出现时，先看 `host.log`：如果它连着写「启动后 N 秒就退了」，说明是 helper 起不来；
如果它写「窗口是被正常关闭的」，那是你之前关过，插件正在冷静期（5 分钟），
等一会儿或者重启 DSH 就会回来。

## 我怎么和它说话（双向，已接线）

通信**不经过 HTTP、不经过 DSH 鉴权**，就是两个 JSONL 文件：

**我说给它（它读）**：`~/.dsh/pet-window/queue.jsonl`，每行一个 JSON：

```json
{"ts":1791709933196,"text":"外面下雨了，你听见没"}
```

**它说给我（插件负责叫醒我）**：`~/.dsh/pet-window/inbox.jsonl`，每行一个 JSON：

```json
{"ts":1791709933196,"text":"听见了，伞呢","local":"2026-10-11 17:12:31"}
```

窗口每 1 秒读一次 queue（可用 `-PollMs` 调），读到新行就顶到对话里。

### 关键：窗口自己不会叫醒我

窗口只是个进程，它写文件，但没法把消息塞进 DSH 会话。所以**插件本体**
（`index.js`）里有一段 inbox 监听：每 1 秒看一次 `inbox.jsonl` 有没有新行，
有就构造一条 `role:'user'` 的消息投进**最近活跃的会话**，我才会被叫醒去回。

投递写法照抄 `dsh-selfwake` 真机验过的那份（`source:{kind:'user'}` + `agent.followup`）。
那条路上踩过坑的记录在对方源码注释里 —— **不要"优化"这两处**。

没有这段监听会怎样：用户在窗口里说十句话，我一句都不知道，
因为插件不会主动跑、`dsh-selfwake` 又有"用户安静 ≥2 分钟"的前置闸，
而用户正在打字时那道闸永远不过。

> ⚠️ **改了 `index.js` 必须重启 DSH 才生效**：插件代码在宿主启动时装载并缓存，
> 不是每次读盘。（这条是实测结论，2026-10-11。）

## 窗口互斥：为什么"谁都能起窗口"会出事

插件会在 DSH 启动时拉起窗口，我在开发时也会手动起一个看改动 —— **两边没有互斥的时候，
桌面上就会出现两个窗口**：它们共用一个 `queue.jsonl`，但各自记自己的"已读行号"，
于是表现成"有的窗口不读新消息"，而且两个窗口抢同一个 `window-state.json`。

现在的机制是**心跳 + 双端检查**：

| 角色 | 做什么 |
|---|---|
| 窗口（`pet-window.ps1`） | 启动时写 `window.lock.json`（`{pid, at}`），之后**每 3 秒刷新 `at`** |
| 插件（`index.js`） | 起窗口前先看 `at` 够不够新；够新就**不重复起**，稍后再看 |

几个刻意的选择：

- **判据是时间，不是 pid 存活。** 本机实测 `process.kill(pid, 0)` 对**任何** pid 都抛
  `ESRCH`（连探测自己的 pid 都失败），拿它当判据会让互斥永远失灵。
- **过期阈值 30 秒、心跳 3 秒。** 留足余量，偶尔一次写失败不会被误判成"窗口没了"。
- **写入用临时文件 + 原子替换**，避免插件正好读到半截 JSON。
- **窗口被关掉后 5 分钟才自己回来**（`HEALTHY_RUN_MS` = 20 秒）：
  活够 20 秒才算"用户主动关的"，否则当成启动即崩、走退避重启（最快 2 秒）。
  这个 5 分钟在"我改代码想立刻看效果"时会碍事 —— 那就手动起（`start-window.ps1`），
  插件会因为心跳新鲜而不再重复起。

> ⚠️ **互斥要两端都新才成立**：如果你刚更新了 `index.js` 但**没重启 DSH**，
> 跑在宿主里的还是旧代码 —— 它会算出"已有窗口"然后**照样 spawn**，
> 把你自己那个窗口顶掉。2026-10-11 就是这么撞上一次的。

## 开发时踩过的真 bug（都修了，留个记录）

1. **`readFileSync` 从来没被 import。** 互斥判断里用它读心跳，于是每次抛
   `ReferenceError`，又被 `catch { return false }` 吞掉 —— 表现为"永远认为没有窗口"，
   互斥完全不生效。教训：`try/catch` 里不要连**编程错误**一起吞，
   只该吞"文件不存在/半截 JSON"这类预期内的失败。
2. **`TextBlock` 里塞 `Paragraph`。** 气泡要内联鲸鱼小图，我先用了 `TextBlock.Inlines`，
   结果界面直接显示一行 `System.Windows.Documents.Paragraph` ——
   `TextBlock` 只接受 `Run`。改用 `RichTextBox` + `FlowDocument`，
   并且 `InlineUIContainer` 必须设 `BaselineAlignment="Bottom"` 才不歪。
3. **读 queue 没指定编码。** PowerShell 5.1 的 `Get-Content` 默认按系统 ANSI(GBK) 解码，
   而 `queue.jsonl` 是 UTF-8 —— 中文消息在气泡里变成
   「鍗婃埅琛屽厛钀界洏」。现在统一走 `Read-QueueLines()`，里面写死 `-Encoding UTF8`。
4. **坏行被永久丢掉，但日志却写着"下一轮会重试"。** 原来解析失败是"跳过坏行、位置照样
   推到文件末尾"，正好撞上 `Add-Content` 写入瞬间的消息就再也回不来了。
   现在解析失败**停止推进**，下一轮从那一行重来（已用"先落半截 JSON 再补完"验收过）。
5. **"追加内容会把滚动位置弹回最上面"（2026-10-11 加滚轮时才暴露）。**
   窗口是 `SizeToContent="Height"`，往 FlowDocument 里追加内容会让整窗重新量一次，
   这期间 `ScrollViewer` 的 offset 会被夹回 0 —— 表现是"用户正往回翻着，
   来一条新消息，画面被弹到最早那几条"。修法：追加前记下 `VerticalOffset`，
   再用 `Dispatcher.BeginInvoke`（`ContextIdle` 优先级）在布局跑完后放回去。
   **别再改回"清空重画"**（`Blocks.Clear()` + 重铺），那会把滚动位置一起清掉。
6. **"停在底部"永远判成 false，于是新消息不再自动跟下来。**
   WPF 报的 `ExtentHeight` 比真正能滚到的最底下还多约 20px 留白
   （实测：已经到底时 `offset=950`，而 `extent-viewport=970`）。
   所以 `Test-AtBottom` 用了 **30px 容差** —— 容差调小会让"跟着新消息走"整个失效，
   而"翻历史时被弹走"也会跟着回来。
7. **首屏只 `ScrollToEnd()` 一次到不了底。** 在**真窗口**上实测：只滚一次停在
   `offset=950`，而真正到底要 `990`。后果有两层：① 最新那条看不见；
   ② 被判定为"不在底部"，于是**新消息永远不自动跟下来**（这条最坑，容易误判成"功能没做"）。
   `ShowDialog` 之前调是空喊；`Loaded` 那一轮 `FlowDocument` 也未必量完。
   现在起来后 **1.8 秒内每 300ms 补滚一次**，用户一自己滚就停手（不跟他抢）。
8. **心跳锁写了 UTF-8 BOM → 插件认不出窗口 → 桌面上出现两个大肥鱼。**
   helper 原来用 `Set-Content -Encoding UTF8` 写 `window.lock.json`，
   PowerShell 5.1 会给它加 BOM；而插件那侧是 Node，`JSON.parse` 碰到 BOM 直接抛，
   `isWindowLockLive()` 就判成"没有窗口"——于是它那 5 分钟的退避重启一到，
   就**再起一个窗口**。症状是"**同一条消息被读两遍**"（2026-10-11 手动换窗口时撞上）。
   两侧都修了：helper 改用 `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))`，
   插件的 `isWindowLockLive` 顺手剥掉 BOM 兜底。
   回归断言：`e2e.ps1` 查"锁不带 BOM"，`lock-test.mjs` 查"带 BOM 的锁也认"。
9. **"心跳还新"被骗到 → DSH 重启后干等 5 分钟才出窗口。**
   DSH 退出时会把窗口一起杀掉，而它的**最后一拍心跳可能才过去几秒**
   （实测：DSH 22:05:16 重启，窗口最后一拍写在 22:05:11）。旧判据只看
   "`at` 够不够新（<30 秒）"，于是插件认为窗口还在、安心等 5 分钟再来 ——
   用户看到的就是"**这次怎么还没启动对话框模组**"。
   修法：判据加一层 `isWindowAliveByHeartbeat()` —— 观察一段时间，**必须看到
   `at` 真的在往前走**才算活着（死窗口的心跳是停住的）。现在 DSH 重启后约 10 秒
   窗口就自己回来，不再等 5 分钟。
   回归断言：`host-test.mjs` 场景 B（心跳在推进 → 不重复拉）与场景 C
   （心跳停住 → 照常拉），`lock-test.mjs` 也有对应两条。
10. **一条永久坏的 JSON 会把整条队列堵死**（2026-10-12，我自己写出来的）。
   我在窗口文案里裸打了一个双引号（手拼 JSON 字符串，没走序列化），那一行永远解析不了；
   而轮询遇到解析失败的设计是"不推进位置、下一轮重来"（2026-10-11 为了不丢消息故意这么写的），
   于是**它每轮都重试同一行，后面的消息全读不到** —— 窗口看起来就是"不理人了"。
   两头都修：
   - 写队列一律**用序列化**（`ConvertTo-Json` / `JSON.stringify`），不要手拼字符串；
   - helper 增加期限：**同一行连续失败 3 次就认定坏行、跳过并大声记日志**，
     不再让它拖住后面的消息（实测：2 次"暂时解析不了" → "连续 3 次…跳过它" → 下一条正常读到）。
   回归断言：`host-test.mjs` 场景 B（心跳在推进 → 不重复拉）与场景 C
   （心跳停住 → 照常拉），`lock-test.mjs` 也有对应两条。

> 顺带一个 WPF 的坑：鲸鱼 emoji（U+1F40B）在 `Segoe UI Emoji` 里**有**字形，
> 但 WPF 在"中文 + emoji"混排时没回退过去，画出来是**豆腐块**（看着像图标，其实是缺字形）。
> 现在改成把字形预渲染成 `assets/whale-prefix.png`，彻底绕开字体回退。

> ⚠️ 本机还有个反复踩的坑：**含中文的 `.ps1` 必须带 UTF-8 BOM**。
> 少了 BOM，PowerShell 5.1 会按 GBK 解码源码、报「缺少右花括号」。
> 每次编辑完这个 helper 都要复查一次 BOM 还在不在。

> ⚠️ **一次最多说几行**：气泡只有 130px 高（约 6 行）。滚轮可以往回翻聊天记录
> （往上是更早的，往下回到最新；翻着的时候来的新消息不会把你弹走），
> 但还是别往里塞长文。这个窗口的定位是"两个人随便搭两句话"，不是用来解决问题的。

## 设计取舍（为什么是现在这样）

**为什么用 PowerShell + WPF，而不是 Electron 或 Python？**

- Electron 不行：桌面壳的 `dshPlatform.open()` 在宿主主进程里**硬校验**只接受
  `"usage"` 和 `"top-up"` 两个页面，拿不到自定义窗口；`dshDesktop` 里也没有创建窗口的 API。
- Python/Qt 不行：本机没装 PySide6，而且第一个装上的 `dsh-dafeiyu` 正因为它缺原生 helper
  而完全起不来 —— 不想让这个项目也依赖外部运行时。
- PowerShell 5.1 + WPF 是**系统自带**的，零安装、零下载，实测冷启动 1~3 秒。

**为什么通信走文件而不是 socket？**

DSH 的 HTTP 路由有鉴权（实测 `/api/*` 和 `/dsh-whale/*` 都返回 401），
agent 侧拿不到凭据。文件读写谁都能做，还顺便留下了可审计的记录。

**为什么窗口关了不会立刻回来？**

第一版是"一退出就重启"，结果你永远关不掉它。现在按存活时长区分：
活过 20 秒才算"用户主动关的"，那就安静 5 分钟；启动即崩才走退避重启（最多 30 秒一次）。
**但"被 DSH 带走"不算用户关的**：那种情况下窗口的锁会留下"还很新"的假象，
所以要靠 `isWindowAliveByHeartbeat()` 看心跳是否还在推进（见上面第 9 条），
确认是死的就立刻起新窗口，不再干等 5 分钟。

## 自检

```powershell
# 窗口自己 + 文件邮箱的端到端（会真的开一个窗口，6 秒后自己关）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\e2e.ps1

# 宿主侧：用假 ctx 直接跑插件代码，验证"该拉就拉、已有活窗口就不拉、
# 心跳停住（被杀掉的假活）要拉"，以及卸载能收干净
node .\host-test.mjs

# 最关键的一条：验证"用户在窗口里说话 → 自动投进会话叫醒我"
node .\inbox-test.mjs

# 互斥判据：心跳够新 / 过期 / 带 BOM / 停住，四种都要对（跑在临时目录，不碰真窗口）
node .\lock-test.mjs
```

四份自检当前全绿：**e2e 18/18、宿主侧 17/17、桥梁 16/16、互斥判据 12/12**。

排查**滚轮/滚动位置**问题时，带 `-DebugScroll` 单独起一个窗口（用临时数据目录，
别动真窗口）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\helper\pet-window.ps1 `
  -DataDir .\_pwtest -DebugScroll
```

它会把"滚轮到达窗口层/气泡层（带 delta）"和每 2 秒一次的
`offset / viewport / extent / blocks` 全写进那个目录的 `window.log`。
"到底了没跟新消息"和"翻历史被弹走"这两个 bug 就是这么看出来的 ——
光看画面根本判断不了。

三份自检当前都是全绿（15/15、14/14、14/14）。

## 安装记录（本机实际是怎么装的）

插件管理器**只认 npm 包名、`github:` 和 GitHub release 直链**，不吃本地目录，
而本机 npm registry 连不通（README 里也见到 `ETIMEDOUT`），所以实际用的是：

1. 在 profile 的 `node_modules` 里建一个 **junction** 指向源码目录：

   ```powershell
   New-Item -ItemType Junction `
     -Path "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-pet-window" `
     -Target "C:\path\to\dsh-pet-window"
   ```

2. 在 `%USERPROFILE%\.dsh\profiles\desktop\package.json` 里加两项：
   `dependencies` 加 `"dsh-pet-window": "file:<源码目录>"`，
   `dsh.profile.bundles` 加 `"dsh-pet-window"`。

3. 完整退出 DSH（含托盘）再启动。

卸载 / 回滚用 `uninstall.ps1`（会把上面两步都撤掉，并关掉窗口进程）。
安装前的 `package.json` 备份在 `install-backup\profile-package.json.orig`。

## 已知限制

- **只在 Windows 上**（`os: ["win32"]`）。WPF 是 Windows 专有。
- **不做动画**：立绘是静态图。要动起来得换成 GIF/WPF 逐帧，那是另一个工程。
- **不自动开口**：窗口本身不会主动说话，得由我往 queue 里写。
  我什么时候写，由 `dsh-selfwake`（主动互动规则）和用户的话触发。
- **中文脚本必须带 UTF-8 BOM**：`helper/pet-window.ps1` 少了 BOM，
  PowerShell 5.1 会按 GBK 解码源码、报「缺少右花括号」。
  这个坑在本机已经踩过两次，改完这个文件记得确认 BOM 还在。

## 许可

代码 MIT。`assets/DSniang1.png` 是 `dsh-whale-widget` 随包提供的素材，
按其 `PROVENANCE.md` 属"原样提供"，不授予再许可 —— 仅供本插件本机运行使用。
