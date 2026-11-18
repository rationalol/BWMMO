# 序章三场景 vs ROM 原脚本逐句对照

日期：2026-10-23
工具：`tools/rom/trace_script.py`（回放单个 ROM 脚本）、`tools/rom/story_diff.py`（把回放结果和 `server/content/story/nuvema.json` 对齐）

## 为什么要做这件事

剧情 JSON 是手写的，`story:lint` 只能证明它内部自洽，不能证明它和原作一致。这里换一个方向：直接用 ROM 的脚本 VM 跑出原作会说的每一句话，再和我们的场景逐句对齐。这是目前唯一能把"我们写错了台词"和"我们漏了台词"区分开的自动化手段。

## 怎么复现

```bash
python3 tools/rom/trace_script.py --zone 391 --npc 2 --battle both   # 卧室开场，胜负两条轨迹
python3 tools/rom/trace_script.py --zone 390 --npc 0 --flag 2402=1   # 妈妈（已选御三家）
python3 tools/rom/trace_script.py --zone 396 --script-id 1 --entry 0x119 --flag 2402=1  # 研究所图鉴事件
python3 tools/rom/story_diff.py                                      # 生成下面的对照
```

`trace_script.py` 需要 `--rom` 指向 ROM（缺省找项目根目录下的 `.nds`）；输出可用 `--json` 换机器可读格式，`--out` 落盘。

## 回放机制上的两个坑

**脚本表里的偏移不一定是可执行入口。** 这个 ROM 的脚本文档里，每条记录前面有 8 字节的序言（`2e 00 a6 00 47 05 <id>`），脚本表指向的是序言而不是第一条指令，直接执行会撞上未识别指令。`trace_script.py` 的处理是：优先按表项执行，跑不干净就在本条记录的区间内扫描，取"台词最多、没有未识别指令、正常结束"的那个入口，并把找到的入口和扫描方式打印在标题行（`entry=0x025a (scanned)`）。卧室开场真正的入口是 `0x025a`，表项 `0x1e8` 比它早 0x72 字节。

**分支要靠外部状态注入。** 妈妈的 `.s` 脚本用 flag `2402`（已选御三家）分叉；不注入这个 flag，回放出来的是"还没拿到宝可梦"的那条线。这就是下面的第一个真问题。

## 结果

### 卧室开场 `prologue_bedroom_intro`

ROM 16 条消息，剧情 25 段：13 条逐字一致，1 条只是分页不同，2 条 ROM 独有。胜负两条分支都单独跑过，结果相同（除了胜负台词本身）。

逐字一致的部分覆盖了从"Everyone has chosen a Pokémon!"到切磋结束、Bianca 说"Oh! I'd better come, too!"的整段主干，说明主线和胜负分支是对的。

**缺失（ROM 有、我们没有）**

- 文本 25：`OK, I'll take this Pokémon! / Cheren, that one's yours!`
- 文本 26：`Hey, how come you get to pick out my Pokémon? / Oh, never mind. I wanted {rival} from the start, anyway.`

这两条紧跟在选完御三家之后（我们的 `chooseStarter` 之后直接接了"Everyone has chosen a Pokémon!"），是原作里白露抢走另一只、黑连抱怨的过场。建议在 `chooseStarter` 和"Everyone has chosen a Pokémon!"之间补一段 `say`。

**分页不同（不算错）**

ROM 把 `Honestly, Bianca...` 和后面的解释放在同一个消息的不同页；我们拆成了两句。同理 `Wow...`、`Uh...` 等叹词。对玩家来说显示效果一致。

**占位符**

ROM 文本 53 是 `Let's see what you can do, {rival}!`，我们写的是 `{name}`。原作里玩家就是黑连的对手（rival），两者指同一人；如果引擎只认 `{name}`，现在的写法是对的，只是和 ROM 的字面不同。

**我们独有的（刻意的改编，不算 bug）**

- 开场 Cheren/Bianca 的两句其实来自房间里 NPC 的环境对白（区域 391 的 npc 0/1），我们把它们搬进了场景；原作里这两句是靠近 NPC 时才触发的。
- "The gift box is on the desk."、"Three Poké Balls sit inside the box..."、"Which Pokémon will you choose?"、三个选项反应句——ROM 里选御三家是菜单没有台词，这些是我们补的引导。
- "Cheren healed Bianca's Pokémon!" / "Cheren healed {name}'s Pokémon!"——ROM 用脚本指令直接回血，没有这句话；我们用它替代没有表现力的治疗，可以保留。

### 妈妈 `prologue_mom`

这是本次对照里**唯一的内容错误**。

场景的触发条件是 `prologue.starterChosen: 1`，也就是玩家一定有御三家，对应 ROM 的 flag `2402 = 1`。此时 ROM 说：

- 文本 12：`Phew! I'm taking a little break from cleaning up. / You and your Pokémon should take a break, too. / Good Trainers don't push their Pokémon too hard.`
- 文本 13：`You and your Pokémon should all be filled with energy again! / Now, you can go anywhere!`

我们写的是文本 11 的内容：`You're going to thank the professor too, right? / Better get going, honey!` —— 这是 `2402 = 0`（还没选御三家）的分支。换句话说，**序章里妈妈说的是"还没拿到宝可梦"版本的话**。

另外"`Oh! Look at that—your very own Pokémon! / Everyone looks a little tired. Let me patch them up.`"在 ROM 的 43 条文本里都找不到，是我们自己写的。

建议把 `prologue_mom` 的第一步换成文本 12 和 13 的内容；如果保留"看看你的宝可梦"这层意思，可以放在文本 12 之前，但要知道它是二创。`notice` 那条是客户端提示，不属于对白，不用改。

### 研究所图鉴 `prologue_juniper_pokedex`

差距最大，但性质不同：这是**压缩改编**，不是错句。ROM 里这段事件有 14 条消息（触发后从"Hi there! I've been waiting for you young people!"开始，经历自我介绍、昵称询问、Cheren 抢答" It's for the Pokédex, right?"、博士解释图鉴、三人表态），我们压成了 5 句，其中 4 句还是从各 NPC 的环境对白里借的（Juniper 的 "Why, hello, {name}!"、Bianca 的 "For some reason, my heart is pounding..."、Cheren 的 "Finally, I can become a Pokémon Trainer."），"Your mother called ahead..."和"These are Pokédexes—one for each of you..."是原创的。

如果目标是"还原"，这段要重写并按 ROM 顺序补齐；如果目标只是"能玩通序章"，现在的版本信息量够用。需要明确选哪一种。

**回放中断**：轨迹在文本 18 之后停在未识别指令 `0x019F`（`bw_script_ops.json` 里没有这条 opcode，因此不知道它带几个参数）。所以图鉴到手那句"`{name} obtained the Pokédex!`"（文本 19）之后的流程还没被回放过。补 opcode 表才能覆盖到场景结尾；在那之前，这个场景的对照只到"All of you, thanks!"。

## 结论

自动化对照能把问题分成三类，而且这次三类都出现了：

1. **真错**：妈妈场景用了未选御三家分支的台词。改一句话即可，建议这次就改。
2. **漏**：卧室选完御三家后少了白露抢宝可梦／黑连抱怨的两句。补一段 `say`。
3. **改编**：研究所场景是压缩版，卧室开场补了引导语。这些不是 bug，但需要决定"还原度"的标准，否则以后每次对照都会把它们报出来。

工具本身也暴露了两个已知缺口：脚本表偏移需要入口解析（已处理），以及 opcode `0x9F` 未收录导致图鉴事件回放不全（已处理：`0x9F` 本身在表里，真正缺的是 `0x19F`，按一次 u16 参数补上后图鉴事件不再中断）。

## 后续：把脚本编译成剧情 JSON

`tools/rom/compile_story.py` 是同一套回放机制的生产方向用法。它对每个入口跑两遍（战斗胜/负），用 `difflib` 对齐两条事件流，把事件翻译成我们的 step：

- 两条轨迹都有的事件 → 普通 step；
- 只有赢或只有输才有的事件 → 同一 step 加 `when: {"8010": 1|0}`，顺序保持原作顺序；
- `0x85` + `0x8E` + `0x8D` → 一个 `battle` step，`resultFlag` 取自 `0x8D` 写入的 work 变量；
- `0x23`/`0x24` → `setFlag`；内部 work 写入不输出。

产物是 `server/content/rom/rom_prologue.json`（不在剧情加载路径上），每个场景附 `verify`：把编译出的 step 重新展开成台词，再和独立回放的 ROM 台词比较。当前卧室 38 行 / 33 行（胜/负）、妈妈 5 行、研究所 32 行，全部一致。

这直接印证了上面的三条结论：编译出的卧室场景**开头就是文本 25/26**（白露抢宝可梦、黑连抱怨），妈妈场景在 `2402=1` 下**只有文本 12/13**。换句话说，手写剧情里缺的和说错的，编译器产出的片段可以直接对照着补。研究所补上 `0x19F` 后不再中断，文本覆盖到 2–22（21 步 / 76 行），"All of you, thanks!" 之后的内容也进来了。

编译器的边界：`chooseStarter` 是菜单不是脚本；训练家队伍现在从 ROM 的训练家档案里抽（`tools/rom/extract_trainers.py` → `content/rom/trainers.json`），白露 `rom_59`（小水獭 L5，class 38）、黑连 `rom_53`（暖暖猪 L5，class 37）都带真实队伍，`romParams` 仍记录 `0x85` 的两个参数；NPC 注册、地图放置、触发器、`interactions`/`gates` 都不在脚本里，需要手工接。产物是"审阅后合并"的素材，不是可直接运行的剧情包。

### 批量编译（2026-10-23）

`--bulk` 把同样的流程套到全部 427 个区域：291 个区域有对白，共 1143 个场景、4584 行台词，跑完约 3 秒，输出 `content/rom/story_bulk/`（每区一个文件 + `_index.json`）。入口解析 89 条靠扫描、6 条 fallback、6 条撞未识别 opcode，`mismatch` 为 0。

2026-10-23 修掉一个真正的解码 bug 后，数字从 1142/4172（fallback 15、blocked 15、扫描 127）变成上面的样子：`0x2A` 的表格宽度是 `var + value` 四个字节，运行时却只吃了 `var` 两个字节，凡是走到这条指令的脚本后面全部错位——补上宽度后 7 条 blocked 直接变干净（例如 16 区脚本 7 从 11 句涨到 14 句，内容确实是博物馆场景的完整对白）。同时让 `0x04` 的向后调用可以落到同一文件里更早的公共子程序（在区间外但仍是已知指令开头时放行），47 区脚本 3 因此补出第 2 句台词。`0x1B6` 按一次 u16 参数补进表。

批量结果里有三件事需要知道：

- **入口扫描可能选错脚本。** 研究所 `script 1` 的图鉴事件里有 `0x9F`，扫描会跳过它、选同区间里另一条能跑完的脚本。所以 `SOURCES` 里钉了 `(396, 1) → 0x119`，批量模式会优先用这个覆盖。类似情况只能靠 `entryResolved: "scanned"` 和 `blocked` 名单人工抽查。
- **说话人大量为空。** 1567 个 `say` step 里 1050 个没有 speaker，因为 ROM 只有部分消息带 `Name:` 前缀；批量模式拿不到"这条脚本属于哪个 NPC"的可靠对应关系（同一条脚本可能被多个 NPC 用，事件脚本里还会换人说话），硬填会张冠李戴。按需在合并时补。
- **全局脚本 NPC 没覆盖。** 2257 个 NPC 中有 1134 个用 ≥1000 的全局脚本 id，这些脚本不在这 427 个区域脚本文件里，批量模式一句也拿不到；`npc_dialogues.json` 里同样只有本地脚本的 966 个 NPC。要覆盖得先解决全局脚本表（见上文 `read_global_table` 的限制）。

另外 3467 条脚本记录里只有 2064 条落在区域脚本文件、1259 条带对白；剩下的门、动画、道具脚本没有对白，批量按"有对白或有战斗"过滤掉了，`skipped` 字段能看到每个区域跳过多少条。
