# BWMMO 客户端视觉验收报告（诺文镇序章）

- 验收日期：2026-10-23
- 验收对象：Godot 4.4.1 客户端 + `ws://127.0.0.1:2567` 服务端
- 验收范围：新账号序章全流程、12 项手动检查、视觉专项
- 结论：**不可交付**（2 项严重 FAIL，0 项致命）

## 1. 结论摘要

| 项目 | 数量 |
|---|---:|
| 12 项检查 PASS | 10 |
| 12 项检查 FAIL | 2 |
| 致命 | 0 |
| 严重 | 2 |
| 轻微 | 1 |
| 证据缺口（KNOWN-GAP） | 1 |

阻塞交付的问题是**剧情 NPC 本体不可见**：

1. 北口闸门处看不到 Cheren 本人，只有空路面/闸门小物件；拒绝对话仍能触发。
2. 研究所内 Juniper、Bianca、Cheren、Cedric 以及测试 NPC 都只剩悬浮姓名标签，没有角色本体；对话 UI 也没有立绘。

这两项直接违反“剧情 NPC 不可见/站位错误属于严重问题”的验收标准，也违反视觉专项“立绘不穿墙不悬空”。素材文件 `npc_104/105/109/110/12/135` 实际存在，因此不属于“NPC 行走图缺素材回退主角”的已知缺口。

## 2. 环境与账号

- 启动方式：`run-server.cmd` → `run-client-debug.cmd`；双账号测试时并行启动两个客户端。
- 测试账号（均为本轮新注册，剧情状态按角色保存）：

| 角色 | 账号 | 初始伙伴 | 战斗结果 | 用途 |
|---|---|---|---|---|
| Nova | accept1023 | Tepig | 胜 Bianca，负 Cheren | 主线全流程、图鉴、解锁、重连 |
| Luna | accept2024 | Snivy | 负 Bianca，负 Cheren | 鼠标选宠、败北分支、双账号可见性 |
| Stella | accept1025 | Tepig | 胜 Bianca，负 Cheren | 补拍战斗横幅/战报文案 |

服务端日志中的关键对战记录：

```text
[battle] Nova challenged Bianca (bianca_oshawott) ... Nova won
[battle] Nova challenged Cheren (cheren_tepig) ... Nova lost
[battle] Luna challenged Bianca (bianca_tepig) ... Luna lost
[battle] Luna challenged Cheren (cheren_snivy) ... Luna lost
[battle] Stella challenged Bianca (bianca_oshawott) ... Stella won
[battle] Stella challenged Cheren (cheren_tepig) ... Stella lost
```

这组记录同时验证了：对手克制选择（Tepig→Oshawott、Snivy→Tepig）、Cheren 同种、胜负两条分支都接回主线。

## 3. 证据位置

- 截图、完整服务器日志、角色状态快照：`.tools/visual-acceptance/`
- 本文档用相对链接引用这些文件；`.tools/` 已加入 `.gitignore`，属于本机验收产物，不会随仓库提交。
- 关键文件：
  - [server.log](../.tools/visual-acceptance/server.log)
  - [final-character-state.json](../.tools/visual-acceptance/final-character-state.json)
  - [截图目录](../.tools/visual-acceptance)

## 4. 逐项结果

结果列只用 `PASS` / `FAIL` / `KNOWN-GAP`。FAIL 的“期望 vs 实际”见第 5 节。

| # | 检查点 | 结果 | 截图与日志证据 | 备注 |
|---|---|---|---|---|
| 1 | 创建角色：只有名字和颜色；进入卧室队伍为空 | **PASS** | [03-create-character.png](../.tools/visual-acceptance/03-create-character.png)、[04-bedroom-empty.png](../.tools/visual-acceptance/04-bedroom-empty.png) | 创建页只有名字、颜色、进入按钮；卧室 HUD 显示 `队伍 0/6`，无宝可梦 |
| 2 | 开场对白：Cheren/Bianca 立刻出现；E/Space/点击翻页；`{name}` 替换 | **PASS** | [04-bedroom-empty.png](../.tools/visual-acceptance/04-bedroom-empty.png)、[05-dialogue-E.png](../.tools/visual-acceptance/05-dialogue-E.png)、[06-dialogue-Space.png](../.tools/visual-acceptance/06-dialogue-Space.png)、[07-dialogue-click.png](../.tools/visual-acceptance/07-dialogue-click.png)、[70-b-name-line.png](../.tools/visual-acceptance/70-b-name-line.png) | 三种输入均能翻页；Luna 线显示“来吧，Luna——打开它！” |
| 3 | 选御三家：三张大按钮 Lv.5；世界输入锁住；鼠标/键盘可选；反应台词 | **PASS** | [08-starter-choice.png](../.tools/visual-acceptance/08-starter-choice.png)、[11-choice-move-attempt.png](../.tools/visual-acceptance/11-choice-move-attempt.png)、[12-choice-keyfocus.png](../.tools/visual-acceptance/12-choice-keyfocus.png)、[13-starter-reaction.png](../.tools/visual-acceptance/13-starter-reaction.png)、[72-b-starter-reaction.png](../.tools/visual-acceptance/72-b-starter-reaction.png) | A 用键盘 Right+Enter 选 Tepig；B 用鼠标选 Snivy；弹窗期间按 D 角色未移动 |
| 4 | 发放：队伍立刻 1 只 Lv.5、图鉴 +1；重连不再弹选择 | **PASS** | [13-starter-reaction.png](../.tools/visual-acceptance/13-starter-reaction.png)、[31-pokedex.png](../.tools/visual-acceptance/31-pokedex.png)、[32-reconnect.png](../.tools/visual-acceptance/32-reconnect.png) | 队伍立即 `1/6 Lv.5`；图鉴“已捕获 1”；重连后直接回卧室，无选择弹窗 |
| 5 | 白露战：无 RUN、BAG 在、对手克制、胜负接回治疗回满 | **PASS** | [91-c-bianca-battle.png](../.tools/visual-acceptance/91-c-bianca-battle.png)、[75-bianca-battle.png](../.tools/visual-acceptance/75-bianca-battle.png)、[25-heal-bianca.png](../.tools/visual-acceptance/25-heal-bianca.png)、[26-heal-player.png](../.tools/visual-acceptance/26-heal-player.png)、[78-b-after-battles.png](../.tools/visual-acceptance/78-b-after-battles.png)、[server.log](../.tools/visual-acceptance/server.log) | 选 Tepig→对手 Oshawott；选 Snivy→对手 Tepig。只有战斗/背包/宝可梦。A 胜后 1/21→21/21；B 败后也回满 19/19 |
| 5b | 白露战入场横幅 | **KNOWN-GAP** | [74-bianca-entry-attempt.png](../.tools/visual-acceptance/74-bianca-entry-attempt.png)、[90-c-bianca-entry-attempt.png](../.tools/visual-acceptance/90-c-bianca-entry-attempt.png)、`client/scripts/battle_ui.gd:657` | 横幅只显示约 0.42–0.84s，桌面截图会等待动画稳定，未抓到有效帧；代码在 `trainer` 模式绑定 `"Bianca wants to battle!"`。未观察到错误内容，但**没有视觉确认** |
| 6 | 黑连战：对手同种、无 RUN；结束后两 NPC 消失；输了不传回床 | **PASS** | [29-cheren-battle.png](../.tools/visual-acceptance/29-cheren-battle.png)、[30-cheren-turn1.png](../.tools/visual-acceptance/30-cheren-turn1.png)、[78-b-after-battles.png](../.tools/visual-acceptance/78-b-after-battles.png)、[server.log](../.tools/visual-acceptance/server.log) | A/C 为 Tepig 对 Tepig，B 为 Snivy 对 Snivy；无 RUN；战后两 NPC 消失；A 输后仍在卧室桌边，B 输后在下楼后的 1F，不是床 |
| 6b | 黑连战入场横幅 | **KNOWN-GAP** | [28-cheren-entry-attempt.png](../.tools/visual-acceptance/28-cheren-entry-attempt.png)、`client/scripts/battle_ui.gd:657` | 同 5b：瞬态动画未抓到有效帧，代码路径存在 |
| 7 | 下楼：按“右”出门；妈妈对话/治疗；再对话普通对白 | **PASS** | [34-downstairs.png](../.tools/visual-acceptance/34-downstairs.png)、[35-mom-dialogue.png](../.tools/visual-acceptance/35-mom-dialogue.png)、[37-mom-heal.png](../.tools/visual-acceptance/37-mom-heal.png)、[38-mom-normal-dialogue.png](../.tools/visual-acceptance/38-mom-normal-dialogue.png) | 卧室出生格按右直接下到 1F；妈妈提示“Mom healed your team…”；再对话进入普通休息对白 |
| 8 | 北口闸门：看得见 Cheren 本人挡路；拒绝台词；按住不刷屏 | **FAIL** | [42-gate-message.png](../.tools/visual-acceptance/42-gate-message.png)、[43-gate-hold-3s.png](../.tools/visual-acceptance/43-gate-hold-3s.png)、[44-gate-second-line.png](../.tools/visual-acceptance/44-gate-second-line.png)、[83-a-sees-luna-not-cheren.png](../.tools/visual-acceptance/83-a-sees-luna-not-cheren.png)、[85-b-gate-cheren-dialogue.png](../.tools/visual-acceptance/85-b-gate-cheren-dialogue.png) | 拒绝台词与 2.5s 节流通过；但路面上看不到 Cheren 本体。期望/实际见 5.1 |
| 9 | 研究所：进门自动图鉴场景；四名角色独立立绘；Route 1 解锁；Cheren 消失 | **FAIL** | [47-lab-cutscene.png](../.tools/visual-acceptance/47-lab-cutscene.png)、[56-route1-open.png](../.tools/visual-acceptance/56-route1-open.png)、[56-lab-npcs-crop.png](../.tools/visual-acceptance/56-lab-npcs-crop.png)、[57-lab-npcs-visible.png](../.tools/visual-acceptance/57-lab-npcs-visible.png)、[58-cheren-dialogue-lab.png](../.tools/visual-acceptance/58-cheren-dialogue-lab.png)、[63-route1-unlocked.png](../.tools/visual-acceptance/63-route1-unlocked.png) | 自动播放、Route 1 解锁、闸门放行通过；四名角色独立立绘失败。期望/实际见 5.2 |
| 10 | 双账号：互相看不到对方剧情 NPC，也不被对方挡住 | **PASS** | [83-a-sees-luna-not-cheren.png](../.tools/visual-acceptance/83-a-sees-luna-not-cheren.png)、[84-a-crosses-gate-no-block.png](../.tools/visual-acceptance/84-a-crosses-gate-no-block.png)、[85-b-gate-cheren-dialogue.png](../.tools/visual-acceptance/85-b-gate-cheren-dialogue.png)、[final-character-state.json](../.tools/visual-acceptance/final-character-state.json) | A 在闸口能看到 B 的 Luna，但看不到 B 的 Cheren；A 在 B 的闸门激活时仍能穿过 (787,737→741)。B 自己的 Cheren 不可见属于第 8 项 |
| 11 | 重连/切图：对话框不被 map_state 顶掉；不提前解锁；不重播已完成场景 | **PASS** | [47-lab-cutscene.png](../.tools/visual-acceptance/47-lab-cutscene.png)、[32-reconnect.png](../.tools/visual-acceptance/32-reconnect.png)、[42-gate-message.png](../.tools/visual-acceptance/42-gate-message.png)、[63-route1-unlocked.png](../.tools/visual-acceptance/63-route1-unlocked.png) | 进研究所 warp 后 Juniper 对话框立即出现，未被 `map_state` 顶掉；B 未拿图鉴时闸门仍锁，A 解锁后可过；A 重连后卧室/选择均未重播，flag 保持 |
| 12 | 弹窗失败态：ESC/点面板外不关闭；角色不能动 | **PASS** | [08-starter-choice.png](../.tools/visual-acceptance/08-starter-choice.png)、[09-choice-esc.png](../.tools/visual-acceptance/09-choice-esc.png)、[10-choice-outside.png](../.tools/visual-acceptance/10-choice-outside.png)、[11-choice-move-attempt.png](../.tools/visual-acceptance/11-choice-move-attempt.png) | ESC、点击面板外后弹窗仍在；按 D 角色未移动；只有服务器选项可提交 |

## 5. FAIL 详情

### 5.1 第 8 项：闸门处看不到 Cheren 本人（严重）

- **期望**：在诺文镇北侧 1 号道路接缝 (约 788,741) 能看见 Cheren 本人站在前方路面上，而不是空气挡路。
- **实际**：路面上没有人形；B 视角（闸门对该角色激活）也只有 A/Luna 两个玩家和闸门小物件，没有 Cheren 的身体或姓名标签。拒绝台词仍会由闸门触发。
- **通过的部分**：
  - 被拒绝时弹出 Cheren 的“等一下 / 离开小镇之前，红豆杉博士还在研究所等我们呢。”
  - 按住 W 3 秒只再次触发一次，未刷屏（2.5 秒节流生效）。
- **证据**：
  - [42-gate-message.png](../.tools/visual-acceptance/42-gate-message.png)
  - [43-gate-hold-3s.png](../.tools/visual-acceptance/43-gate-hold-3s.png)
  - [44-gate-second-line.png](../.tools/visual-acceptance/44-gate-second-line.png)
  - [83-a-sees-luna-not-cheren.png](../.tools/visual-acceptance/83-a-sees-luna-not-cheren.png)（A 视角：看得到 Luna，看不到 Cheren，符合预期）
  - [85-b-gate-cheren-dialogue.png](../.tools/visual-acceptance/85-b-gate-cheren-dialogue.png)（B 视角：闸门已激活，仍看不到 Cheren）
- **严重度**：严重。验收标准明确把“剧情 NPC 不可见/站位错误”列为严重。

### 5.2 第 9 项：研究所四名角色只有悬浮姓名，没有立绘（严重）

- **期望**：进门自动播放 Juniper/Bianca/Cheren 的图鉴场景；Juniper、Bianca、Cheren、Cedric 四人各有独立立绘/行走图，不是同一个主角小人；对话中能看到角色。
- **实际**：图鉴场景会自动播放，台词页也能推进；但房间内所有 NPC（包括测试 NPC）只有悬浮姓名标签，标签下方没有角色本体；对话 UI 也没有立绘。研究所内无法确认四名角色的独立外观。
- **通过的部分**：
  - 进门自动播放，未出现“加载中”文案。
  - 结束后提示“You received a Pokédex! Route 1 is now open.”。
  - 北口放行，进入 1 号道路。
- **证据**：
  - [47-lab-cutscene.png](../.tools/visual-acceptance/47-lab-cutscene.png)（Juniper 对话开始）
  - [56-route1-open.png](../.tools/visual-acceptance/56-route1-open.png)（解锁提示）
  - [56-lab-npcs-crop.png](../.tools/visual-acceptance/56-lab-npcs-crop.png)（“白露/黑连/红豆杉博士”标签，下方无本体）
  - [57-lab-npcs-visible.png](../.tools/visual-acceptance/57-lab-npcs-visible.png)（移动到 NPC 附近后仍只有标签）
  - [58-cheren-dialogue-lab.png](../.tools/visual-acceptance/58-cheren-dialogue-lab.png)（Cheren 对话可用，但没有角色/立绘）
  - [63-route1-unlocked.png](../.tools/visual-acceptance/63-route1-unlocked.png)
- **补充**：`client/assets/bw/overworld/` 下存在 `npc_104/105/109/110/12/135` 等素材，不是“缺素材回退主角”的已知缺口；问题更像是 NPC actor 的渲染、遮挡或层级放置。
- **严重度**：严重。

### 5.3 训练家战报把对方写成“Wild …”（轻微）

- **期望**：训练家战显示“Foe/对方”或训练家名，例如“Foe Snivy used Tackle!”。
- **实际**：训练家战中显示“Wild 藤藤蛇 used Tackle!” / “Wild 暖暖猪 used Tackle!”。
- **证据**：
  - [77-b-bianca-result.png](../.tools/visual-acceptance/77-b-bianca-result.png)
  - [93-c-pre-cheren.png](../.tools/visual-acceptance/93-c-pre-cheren.png)
  - [server.log](../.tools/visual-acceptance/server.log) 中对应战斗是 `trainer` 模式（Bianca/Cheren），不是野生战。
- **严重度**：轻微（文案/语义错误，不影响流程）。

## 6. 视觉专项

| 项目 | 结果 | 证据 | 备注 |
|---|---|---|---|
| 场景切换淡出→淡入，无“加载中”文案 | **PASS** | `client/scripts/main.gd:29`，[34-downstairs.png](../.tools/visual-acceptance/34-downstairs.png)、[47-lab-cutscene.png](../.tools/visual-acceptance/47-lab-cutscene.png) | 代码为 0.26s 淡出 + 0.05s 黑场 + 0.42s 淡入；多次切图未见加载文案。未抓到中间帧，属于证据有限 |
| 对话框不溢出 | **PASS** | [47-lab-cutscene.png](../.tools/visual-acceptance/47-lab-cutscene.png)、[56-route1-open.png](../.tools/visual-acceptance/56-route1-open.png)、[70-b-name-line.png](../.tools/visual-acceptance/70-b-name-line.png) | 长中文/英文均自动换行在框内，无裁切 |
| 立绘不穿墙不悬空 | **FAIL** | [56-lab-npcs-crop.png](../.tools/visual-acceptance/56-lab-npcs-crop.png)、[57-lab-npcs-visible.png](../.tools/visual-acceptance/57-lab-npcs-visible.png) | 姓名标签悬空，标签下方没有角色本体；与第 8/9 项同源 |
| HUD 即时更新 | **PASS** | [13-starter-reaction.png](../.tools/visual-acceptance/13-starter-reaction.png)、[26-heal-player.png](../.tools/visual-acceptance/26-heal-player.png)、[31-pokedex.png](../.tools/visual-acceptance/31-pokedex.png)、[63-route1-unlocked.png](../.tools/visual-acceptance/63-route1-unlocked.png) | 选宠后队伍立即出现；治疗 1/21→21/21；图鉴 0→1；地名“诺文镇”→“1号道路” |
| 只看到背景没有 UI（致命空窗） | **PASS** | 全部编号截图 | 未出现无 HUD/无对话框的静态空白窗口；转场黑屏是主动淡入淡出的一部分 |
| 输入：鼠标与键盘都能完成剧情选项 | **PASS** | [12-choice-keyfocus.png](../.tools/visual-acceptance/12-choice-keyfocus.png)、[72-b-starter-reaction.png](../.tools/visual-acceptance/72-b-starter-reaction.png) | A 键盘、B 鼠标均成功选宠 |
| 帧率/长时间卡住 | **PASS** | 客户端运行观察 | 过场/战斗切换未出现 >3 秒的卡死 |

## 7. 胜负分支与状态验证

- **白露战**
  - A（Tepig）胜 Oshawott；战后队伍 1/21 → 21/21。
  - B（Snivy）负 Tepig；战后队伍回满 19/19。
- **黑连战**
  - A（Tepig）负 Cheren 的 Tepig；A 未被传回床，仍在卧室桌边。
  - B（Snivy）负 Cheren 的 Snivy；B 在下楼后的 1F，未回床。
  - C（Tepig）负 Cheren 的 Tepig，用于补拍战报。
- **状态落盘**（`final-character-state.json`）：
  - Nova：`prologue.pokedex=1`、`prologue.routeUnlocked=1`，图鉴 caught=1。
  - Luna：`prologue.pokedex=0`、`prologue.routeUnlocked=0`，仍被闸门拦住。
  - Stella：`prologue.bedroomDone=0`，用于战斗横幅/文案复现。

## 8. 限知与未覆盖项

1. 入场横幅（5b/6b）没有抓到有效视觉帧。桌面截图工具会等待 UI 稳定，横幅在约 0.42–0.84 秒内结束；高频截屏尝试又受窗口焦点切换影响，抓到了 ZCode 窗口而不是游戏。代码路径存在，暂按证据缺口处理。
2. 没有单独做“完整 12 项全程打赢两场”的第四轮；但胜负两条分支都实际走过：A/C 胜白露、B 负白露；A/B/C 均负黑连的样本也覆盖了失败路径。
3. “场景切换淡出中间帧”未单独截图；代码与切图结果均未出现“加载中”文案，但严格视觉证据有限。
4. 若后续确认入场横幅确实不显示，按验收标准的严重度定义应升级为严重（可能 +1～+2）。

## 9. 建议修复顺序

1. **P0（阻塞）**：修复研究所/闸门剧情 NPC 的 actor 渲染。重点检查：
   - NPC actor 的 root/sprite 高度与地板高度是否一致；
   - 室内墙体、闸门几何体是否把 NPC 挡在深度后面；
   - 为什么姓名 Label3D 可见而 AnimatedSprite3D 不可见。
   修复后复测第 8、9 项和“立绘不穿墙不悬空”。
2. **P1**：用实时抓帧或录屏补确认 Bianca/Cheren 入场横幅；如果确实缺失，按严重问题修复。
3. **P2**：修正训练家战报的“Wild …”文案，改为对方/训练家称呼。
4. 复测时至少使用两个新账号，一个走胜利分支、一个走失败分支，并保留双账号闸门可见性检查。

## 10. 清理说明

- 验收结束后已关闭全部 Godot 客户端并停止服务器。
- 已恢复验收前的登录会话；测试账号仍保留在 `server/data/`，便于复查。
- 未修改任何客户端代码或 `server/content/` 内容文件；仅新增 `.tools/visual-acceptance/` 下的截图、日志和状态快照。
