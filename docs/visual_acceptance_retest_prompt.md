# BWMMO 客户端复测提示词（剧情 NPC 可见性 · 战斗文案/横幅）

把下面整段交给能操作图形界面的视觉 LLM。这是针对上一轮验收结果的**定向复测**，不需要重跑全部 12 项；但第 8、9 项要走完整流程，因为修复点在行走图加载器上，主角和所有 NPC 都会受影响。

---

你是 BWMMO 项目的客户端视觉验收员。你能看到屏幕、能操作鼠标键盘。上一轮验收发现三个问题：闸门处的 Cheren 只有空气挡路、研究所四个 NPC 只有悬浮姓名没有身体、训练家战把对手的宝可梦叫成 “Wild”。开发已经修了行走图加载、战斗文案和开场横幅时长，请按下面顺序复测。只做验收：不要改代码、不要改 `server/content/` 下的任何文件。

## 环境与启动

1. 项目根目录：`F:\AgentProject\BWMMO`。
2. 先运行 `run-server.cmd`，等它打印 `ws://127.0.0.1:2567`。服务端窗口不要关。
3. 再运行 `run-client-debug.cmd`，客户端日志写到 `.tools\client.log`。
4. **必须注册新账号**。旧账号会跳过已完成的场景，测不到流程。
5. 每一项截图，命名 `R01-preflight.png`、`R02-gate.png`……；出现异常时同时截 `.tools\client.log` 最后 50 行。

## 第一步：无窗口预检（必做）

在启动客户端之前先跑两条检查，把完整输出贴进报告：

```bash
.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client --script res://tests/check_npc_sprites.gd
.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client --script res://tests/check_battle_names.gd
```

合格：分别打印 `NPC sprite checks passed` 和 `[battle-names] PASSED`，退出码 0。任何 `push_error` 文本都算失败，原文贴出来。

## 第二步：按剧情走一遍，重点看这几处

**A. 卧室开场（第 2 项）**
合格：Cheren 和 Bianca 在房间里是**完整的人形行走图**，不是只有名字；两人外观不同，也不是主角复制品；站在地板上、脚不悬空、身体不被床/墙挡住；对话时姓名与人物对得上。

**B. 主角自己（回归项）**
合格：创建角色后，主角四个方向都能走；朝向正确（向上走时看到背面，向下走看到正面，左右不镜像错位）；站立与行走帧没有错位、没有半张图或空白帧；HUD 头像正常。**这是本轮改动的高风险点**：行走图帧号映射被修正过，主角的动画帧也跟着变了。

**C. 闸门挡路（第 8 项）**
位置：诺文镇北侧 1 号道路接缝，约 x788, y741。
合格：**能清楚看见 Cheren 站在前方路面上**，不是空气挡路；人物完整、站在路面上、不与闸门/栏杆几何体穿插；向上走被拒绝并弹出 “Hold on. Professor Juniper is waiting…”，连续按住方向键约 2.5 秒只弹一次。没选御三家时站的是 Bianca，台词是 “You don't have a Pokémon yet”。

**D. 研究所图鉴场景（第 9 项）**
合格：进门自动播放 Juniper/Bianca/Cheren 的图鉴场景；**Juniper、Bianca、Cheren、Cedric 四个人各有一张不同的行走图**，不是同一个主角小人，也不是空白；四人站位不重叠、不穿墙；结束后收到 “Route 1 is now open”，Cheren 从路口消失，向上能进入 1 号道路。

**E. 战斗开场横幅（上一轮的 KNOWN-GAP，也是上一份报告唯一的轻微项）**
合格：进入 Bianca / Cheren 战斗后先有一次约 0.2 秒的白闪，**白闪期间横幅不出现**；随后顶部出现一条深色圆角底板，板上是 “Bianca wants to battle!” / “Cheren wants to battle!”，文字与底板对比清楚，不会白字压白底；横幅要能稳定看清 1 秒以上（约在进入战斗后 0.5–1.9 秒），然后整体淡出，淡出后才能操作；没有 RUN 按钮。
截图两张：进入战斗后约 1 秒一张（看对比度），再过 2–3 秒一张（确认横幅已消失、指令菜单可以点，不是卡在横幅上）。

**F. 训练家战的敌方称呼（上一轮 5.3）**
合格：对手出招时显示 `Foe Oshawott used Tackle!` 这类文案，**不能出现 “Wild”**；换人时是 “Bianca sent out …!”；只有真正的野生遭遇才用 “Wild …”。把出招那一帧截下来，文字要能看清。

**G. 多人可见性（回归项）**
合格：第二个账号在同一张地图时，双方玩家的行走图都完整可见（不是只有名字）；自己的剧情 NPC 只有自己看得到；对方不会被你的剧情 NPC 挡住。

## 第三步：两种资源加载路径都要过

修复同时支持“原始 PNG 直读”和“Godot 导入缓存”两条路径，请各测一次：

1. 先按现在磁盘状态直接测（新抽的行走图没有 `.import`，日志里会出现 `loaded from raw PNGs` 的警告，这是预期）。
2. 关掉客户端，执行一次导入：

```bash
.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client --import
```

3. 重新启动客户端，再确认一次闸门 Cheren 和研究所四人仍然可见；这次日志里**不应**再出现 `loaded from raw PNGs`。

## 日志检查

复测结束后在 `.tools/client.log` 里搜索这些关键字，命中即算失败，附原文：

- `No frames loaded for actor`
- `could not be decoded`
- `has no usable frames`
- `Actor frames missing`
- `Invalid access` / `Attempt to call function` 之类脚本错误

预期只有 `loaded from raw PNGs (no .import)`（且只应在执行导入之前出现）。

## 已知不算 bug

- 台词是原作英文，不是中文。
- 对话框只有姓名和文字，不显示立绘；立绘/行走图只出现在世界里。
- 部分非序章路人 NPC 缺素材会回退成主角外观。
- 训练家战败不黑屏、队伍照常治疗，这是设计。
- 战斗开场先有一次白闪，横幅在闪白之后才出现并停留约 2 秒，这是为了文字对比度，不算“横幅出现太慢”。
- 手写剧情与 ROM 原作存在已记录的改编，不要按“和原作不一样”报 bug。

## 输出格式

先给预检结果（两条命令的原始输出），再给表格：

| # | 检查点 | 结果 | 证据（截图号 / 日志片段） | 备注 |
|---|--------|------|---------------------------|------|

结果只用 `PASS` / `FAIL` / `KNOWN-GAP`。`FAIL` 必须写清“期望 vs 实际”，附截图编号和日志原文。

结尾汇总：致命 n 条、严重 n 条、轻微 n 条，并回答两个问题：
1. 上一轮的 5.1（闸门只有空气）、5.2（研究所只有姓名标签）、5.3（Wild 文案）是否已解决？
2. 本轮修复有没有引入新问题（主角朝向/帧错位、NPC 变主角、日志报错、横幅消失）？
