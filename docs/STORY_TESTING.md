# 剧情层测试手册

这份文档说明诺文镇序章（选择御三家 → 找妈妈 → 拿图鉴 → 开放 1 号道路）已经如何验证、还需要人工确认哪些点。剧情数据在 `server/content/story/nuvema.json`，引擎在 `server/src/game/story.ts`。

## 数据模型速览

`server/content/story/*.json` 由加载器合并成一份 `StoryContent`：

- `startMap` / `initialFlags`：新角色出生地图和初始 flag（缺省 flag 视为 0）。
- `scenes`：一串按顺序执行的 step。会暂停的有 `say`（等 `story_advance`）、`chooseStarter`（等 `story_choice`）、`battle`（等 `battle_start` 打完并收到 `battle_closed`）和 `walk`（等 `path.length * msPerTile` 让 NPC 走完）；`setFlag`、`giveStarter`、`givePokemon`、`giveItem`、`heal`、`warp`、`notice`、`face` 立即执行。
- step 上的 `when`：flag 条件不满足就跳过该 step，等价于 ROM 脚本的条件跳转（`0x1F`）。卧室场景用它区分“赢了”和“输了”的台词。
- `battle`：用 `trainer` 指定 `trainers` 里的训练家，或用 `variants` 按 `when` 选第一个命中的（对应 ROM 按御三家分支）。`win`/`lose` 是战斗结束后的台词数组，`resultFlag` 写入 1（胜）或 0（负），对应 ROM 的 work `0x8010`。
- `trainers`：训练家定义（`name`、`sprite`、`party` 物种与等级、可选 `reward`）。卧室里的白露/黑连各有三个版本，按玩家选的御三家切换。
- `walk` / `face`：对应 ROM 的 `applymovement` + `waitmovement`。`walk` 的 `path` 每跳一格，服务端据此算出每跳的 `dir` 一起下发；`facing`（`up/down/left/right/player`）决定走完后的定格朝向，`vanish` 让角色走完消失（ROM 的 `0x45`）。`face` 只转身不移动、不暂停，用于让 NPC 说话前看向玩家。服务端会在下发送前校验“逐跳相邻 + 目标格可走”，不满足就记一条内容错误并跳过该 step，不会让角色贴着墙走或倒着走。
- `npcs`：剧情专用 NPC，加载时并入 `map.npcs`，和普通 NPC 一样参与碰撞、交互和 `map_state` 快照。`visibleWhen` 按玩家 flag 逐人过滤，隐藏的 NPC 对该玩家既不可见也不挡路。闸门处也放了一个 `visibleWhen` 与闸门条件一致的 NPC（`prologue_route1_bianca` / `prologue_route1_cheren`），这样拦路的角色本身是看得见的；移动判定先检查闸门再检查 NPC 碰撞，所以对话仍由闸门负责。
- `interactions`：让普通 NPC 触发场景（例如妈妈 `z390_n0`）。
- `triggers`：踩到矩形区域触发场景，可配 `onceFlag`。
- `gates`：当 `when` 命中时，矩形区域不可通行，并发送一句解释（`kind:"gate"`）。
- `onEnter`：进入地图（登录、传送、场景 warp）时自动播放，可配 `onceFlag`。

服务端对每个连接保存一个 `StorySessionState`（场景 id、当前 step、等待类型）。所有判定都用**该玩家自己的** `storyFlags`，所以同一张地图上不同进度的人看到的 NPC 和道路不同。

## 自动化验证

在 `server/` 下执行：

```bash
npm run validate-content   # 剧情引用、边界、flag 条件、物种/道具/地图是否存在
npm run story:lint         # 状态机检查：可达性、死分支、永久闸门、孤儿 flag
npm run typecheck
npm test                   # 含 test/story.test.ts 的 18 条规则测试
```

`story:lint` 不检查引用（那是 `validate-content` 的活），它把剧情当成状态机来跑：从 `initialFlags` 出发，遇到 `battle` 就同时探索“赢”和“输”两条分支，遇到 `chooseStarter` 就按每个选项的 `value` 分支，最后看哪些场景、step、闸门真的能到达。它报的是这几类只能靠状态推演发现的问题：条件里要求某个值但没有任何地方会写这个值（错别字、写错分支）、场景有入口但永远触发不了、某个 step 在任何可达状态下都被跳过、闸门在所有可达状态下都锁着（等于一堵墙）、flag 写了没人读。输出里的 `386 maps` 证明它真的对照了地图目录；地理连通性目前不建模，所以 `gate-never-opens` 是它唯一的几何结论，但这条结论是准确的——所有状态下都锁着的门，地图怎么画都过不去。

上面这几条只证明剧情内部自洽，不证明它和原作一致。要对照原作，用 ROM 回放：在项目根目录执行 `python3 tools/rom/story_diff.py`，它会用 ROM 的脚本 VM 跑出卧室、妈妈、研究所三个场景的原台词，再和 `nuvema.json` 对齐，报出"逐字一致 / 分页不同 / ROM 独有 / 剧情独有"四类差异和完整清单。单场景回放用 `tools/rom/trace_script.py`（`--zone`/`--npc` 或 `--script-id`，`--flag` 注入剧情 flag，`--battle` 选胜负）。已知限制：图鉴事件在未识别指令 `0x9F` 处会中断，脚本表里部分偏移指向序言、需要入口扫描，工具会在标题行标出来。最近一次结果和结论见 `docs/research/prologue_rom_diff.md`。

如果要从原作**生成**剧情而不是逐句比对，用编译器：

```bash
python3 tools/rom/compile_story.py            # 写 server/content/rom/rom_prologue.json
python3 tools/rom/compile_story.py --json     # 直接打印
```

它把同一段脚本按"战斗胜利/失败"各回放一次，对齐两条事件流，产出 `say` / `setFlag` / `battle` 三种 step：两边都有的事件正常输出，只有一边有的事件挂上 `when`（键为战斗结果 flag，如 `8010`），所以胜负台词的分支和顺序都是原作的样子。每个场景会自带 `verify`，记录"编译后的 step 重新展开"与 ROM 回放逐行比较的结果（当前三个场景都是 100% 一致）。产物落在 `content/rom/`，不会被剧情加载器读到（加载器只读 `content/story/*.json`），是给人审阅后合并的片段，不是可以直接顶替 `nuvema.json` 的完整剧情包；`chooseStarter`、NPC 注册和地图触发器不在编译范围内，工具会在 `todo` 里列出来。

`battle` 的训练家队伍来自 `server/content/rom/trainers.json`（`python3 tools/rom/extract_trainers.py` 生成，本地提取、已 gitignore）。抽取器按内容定位两个档案：每个训练家一条 20–64 字节的记录（前四字节是队伍格式、训练家职业、战斗类型、队伍人数），再找成员数和记录逐条对上的队伍档案，按 Gen 5 的队伍条目格式解码（IV、性别/特性、等级、性格、物种、形态，可选道具、可选四招）。当前 616 个训练家、1304 只宝可梦；批量产物里 70 场战斗有 68 场带真实队伍，剩下两场是 `rom_0`（占位训练家）。

要一次拉出所有区域，加 `--bulk`：

```bash
python3 tools/rom/compile_story.py --bulk                       # 输出到 content/rom/story_bulk/
python3 tools/rom/compile_story.py --bulk --zones 390,391,396   # 只跑指定区域
```

批量模式会枚举每个区域脚本文件里的所有对白条目，一个区域一个 `zone_<id>.json`，另有 `_index.json` 记录每个区域扫到多少条、出多少场景、多少台词，以及哪几条落在 `fallback`（入口解析不出）或 `blocked`（撞上未识别 opcode）。当前全量结果：291 个区域、1143 个场景、4584 行台词，约 3 秒；`mismatch` 为 0，`fallback`/`blocked` 各 6 条。批量模式只从"全 0 flag"起跑，需要特定 flag 才出现的分支要用单场景模式补；`rom_z*` 是脚本级 id，和 `nuvema.json` 里的场景 id 不冲突，改名后即可合并。

剩下的 6 条 `blocked` 都停在 opcode 空间之外的值（`0x8021`、`0x8025`、`0x32f`、`0x3b8`、`0x3f02`、`0xd000`）——表里 0x0–0x424 之外没有指令，说明这些脚本中途跳进了数据表或还有一条指令宽度不对，不是缺 opcode。它们留在名单里比猜一个宽度更可靠。

`test/story.test.ts` 覆盖：

- 序章数据能通过 `validateContent`，剧情 NPC 已并入卧室/研究所地图；
- 条件匹配（缺省 flag 为 0、多 key 必须全部相等）；
- 剧情 NPC 的 `visibleWhen` 同时影响可见性和碰撞，两个对手在切磋期间一直留在房间里；
- 北出口两段闸门的优先级（没伙伴 → 没图鉴 → 放行）和区域外不误伤；
- 卧室场景发放伙伴：只发一次、正确物种/等级/招式、写入 `prologue.starterChosen` 和 ROM flag `2402`、登记图鉴；
- 选御三家写入 `prologue.starter`（Tepig 0 / Oshawott 1 / Snivy 2，对应 ROM work `0x4030`）；
- 两场切磋按选择切换对手（白露克制你、黑连跟你同款），`8010` 写入胜负，胜/负台词不同但都会回到主线；
- 输了切磋不会结束场景，治疗步骤照常执行；
- 战斗结束框没关之前，后续台词不会提前推送（`battle_closed` 握手）；
- 战斗中途断线后重进卧室会从切磋继续（不会重复发伙伴），且场景完成后不再重播；
- 过期的 `story_advance`（重复 step / 别的场景）不会跳页；
- 卧室告别演出会下发两条 `npc_move`（白露、黑连各一段 3 格路径），并在走完之前不结束场景；
- 非法选项不会发伙伴，场景停在选择；
- 妈妈/博士场景的条件、治疗、flag 和只播放一次；
- 旧存档仍会自动补初始伙伴，剧情角色不会。

### 新账号端到端冒烟

需要两个终端（服务器必须不设置 `DEBUG_SKIP_STORY`）：

```bash
# 终端 1：干净的数据目录
cd server
PORT=3599 DATA_DIR="F:/AgentProject/BWMMO/.tools/story-smoke-data" npm start

# 终端 2
cd server
npm run smoke:story   # 连 ws://127.0.0.1:3599
```

脚本会真实走 WebSocket：注册 → 不带 starter 创建 → 卧室场景逐页确认 → `story_choice` 选 Tepig → 白露切磋（断言 `battle.mode==="trainer"`、`trainerId==="bianca_oshawott"`）→ 用 `battle_action` 打完并发送 `battle_closed` → 黑连切磋（`cheren_tepig`）→ 场景结束、房间 NPC 消失、队伍满血、图鉴登记 → 下楼触发妈妈场景 → 在 (788,741) 向北推进，断言 `move_ack` 的 `reason` 为 `story_gate` 且收到 Cheren 的拦路对白 → 进研究所自动播放图鉴场景 → 回到同一格并成功踏上 (788,740) → 断线重连后确认队伍仍在、没有重播 `story_begin`。冒烟里两场切磋可能一胜一负，脚本两种情况都接受，因为胜负分支都必须能接回主线。

想连别的地址时设 `STORY_SMOKE_URL=ws://...`。旧的 `npm run smoke` 假设角色已经过完序章，启动测试服务器时要加 `DEBUG_SKIP_STORY=1`；它只是测试开关，正常游玩不要设置。

## 手动验收清单（Windows 上跑 Godot 客户端）

Linux 开发机跑不了 Godot，客户端部分只能静态检查，因此下面每一项都需要在本机执行：

```text
run-client-debug.cmd   # 控制台版，日志在 .tools/client.log
```

1. **创建角色**：登录页注册新账号 → 创建界面只有名字和颜色，没有御三家按钮；副标题应提示第一只伙伴在房间里。提交后应进入卧室（`unova_in_391`），队伍为空，HUD 队伍面板不显示宝可梦。
2. **开场对白**：进入世界后立刻出现 Cheren/Bianca 对话，按 E / Space / 点击逐页推进；台词中 `{name}` 应替换成角色名。
3. **选择御三家**：对白推进到“Which Pokémon will you choose?”时出现三张大按钮（Snivy / Tepig / Oshawott，带 Lv.5），世界输入被锁住；鼠标点选和键盘（Tab/方向 + Enter）都应可用。选中后先出现该伙伴的反应台词，再继续剧情。
4. **发放结果**：选中后队伍面板立刻出现 1 只 Lv.5 伙伴，图鉴 Caught +1；Cheren/Bianca 仍站在房间里（切磋还没打完）。若此时立刻断线重连，不应再次出现选伙伴界面（`prologue.starterChosen` 在选完的同一刻落盘）。
5. **第一场切磋（白露）**：剧情推进到“Get ready for a Pokémon battle!”后自动进入战斗。顶部横幅应是“Bianca wants to battle!”，**没有 RUN 按钮**，BAG 仍在；对方是克制你选择的那只（选 Tepig → Oshawott，选 Oshawott → Snivy，选 Snivy → Tepig）。打赢后出现“{name}, you're gonna be an awesome Trainer someday”，打输后出现“I got so absorbed…”；两种都会继续“Wh-whoa! What happened?!”和 Cheren 的治疗台词，队伍回满血。
6. **第二场切磋（黑连）**：紧接着 Cheren 挑战，对方和你选的是同一只。战斗界面同样没有 RUN。结束后 Bianca 说“Oh! I'd better come, too!”，随后她和黑连各自沿着房间走两步再消失（白露向右再向上，黑连向右再向上），**走动时面朝前进方向**（不会出现倒着走），台词不会抢在走完之前弹出；卧室场景结束后两个 NPC 同时消失。若战斗输了，队伍仍会被治疗，不应被传送回床上（训练家战败不黑屏）。
7. **下楼**：在楼梯格按原版方向离开卧室（卧室出生格按“右”），进入 1F；走到妈妈旁按 E，出现妈妈的台词并治疗队伍，收到“Mom healed your team…”提示。再和妈妈说话应回到普通对白。1F 里**只有一个妈妈**，屋内的桌子、电视、书架、床等家具都应在原位，**上楼的楼梯（`stair_d01`）也必须看得见**。家具缺失或错成房子/球场，说明室内资源是按户外 prop 档案抽的，需要重跑 `tools/rom/extract_unova_indoor.py`；重跑前后都用 `npm run audit:assets` 判断（它会从 ROM 重建每个房间的摆放再和 `library.json` 对比，卧室 391 是金丝雀）。
8. **闸门挡路**：出门沿诺文镇北侧走到 1 号道路接缝（约 x788, y741），**应该能看见黑连（Cheren）站在前方的路面上**，而不是只有空气挡路；向上走被拒绝并弹出 Cheren 的“Hold on. Professor Juniper is waiting…”；连续按住方向键不应刷屏（2.5 秒节流）。如果还没选御三家，这里站的是白露（Bianca），台词换成“You don't have a Pokémon yet”。
9. **研究所图鉴**：从北侧进入博士研究所，进门即自动播放 Juniper/Bianca/Cheren 的图鉴场景；研究所里应能看到各自的独立立绘（黑连、白露、红豆杉博士、赛德），不是同一个主角小人；结束后收到“Route 1 is now open”，黑连从路口消失，再回到同一格向上走应能正常进入 1 号道路。
10. **多人可见性**：用第二个账号（也已过完序章或正在序章中）站在同一张地图，确认对方看不到你房间里的 Cheren/Bianca、也不会被它们挡住；你自己的剧情 NPC 只在本机快照中出现。
11. **重连/切图**：剧情播放中切图（例如研究所自动场景会伴随场景 warp）时，对话框不应被 `map_state` 顶掉，世界也不应提前解锁；重连后从当前 flag 继续，不重播已完成的 `onEnter` 场景。
12. **失败态**：在 `story_choice` 弹窗出现时按 ESC 或点击面板外，不应关闭弹窗或让角色移动；选项只接受服务器提供的 id。

## 改剧情后怎么自查

1. 改完 `content/story/nuvema.json` 先跑 `npm run validate-content`：场景引用、NPC 是否站在可走格、gate/trigger 边界、`chooseStarter` 的物种/等级、`battle` 的 `trainer`/`variants` 引用和训练家队伍、`warp` 目标坐标都会报错。
2. 跑 `npm test`，`test/story.test.ts` 会验证条件、闸门、发放伙伴和切磋战斗的规则；如果改了场景页数，`story-smoke` 会自动按服务器下发的 `step` 推进，但战斗内容（对手、胜负分支）变了就要同步脚里的断言。
3. 新增 flag 时同时更新 `initialFlags`、场景里的 `setFlag` 和闸门/可见性的 `when`，并在 `validate-content` 后手动走一遍对应分支。
4. 剧情 NPC 的 `sprite` 用 ROM 模型 id（序章：Cheren=12、Bianca=135、Juniper=110、Cedric=109）；客户端只内置了部分 NPC 行走图，缺素材时会回退成主角外观，这是已知的美术缺口，不是剧情 bug。
5. 新抽的 `client/assets/bw/overworld/npc_*/frames/*.png` 没有 Godot `.import`，客户端会退化成直接解码原始 PNG；如果 NPC 只有名字标签没有身体，先跑 `check_npc_sprites.gd`，再执行 `godot --headless --path client --import`。

## 当前限制

- 只有诺文镇序章有剧本；其他道路/城镇的剧情、训练家对战、徽章门槛尚未接入。
- NPC 走动只支持剧情里的 `walk`（纯演出，不改服务端坐标）和 `movement != 0` 的原地转身待机；随机漫游需要服务端逐格同步 NPC 位置，否则视觉和碰撞会不一致。
- `battle` 步骤目前只支持单打训练家战；双打、道具携带、训练家 AI 换招等仍由 Showdown 的默认 AI 负责。
- 剧情状态按角色保存，没有“二周目/重置序章”的界面；测试时请用新账号。
- 客户端没有专门的剧情回顾/跳过功能；已看过的 `onEnter` 场景靠 flag 不重播。
