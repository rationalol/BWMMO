# ROM 工具脚本清单

这份清单说明 `tools/rom/` 下每个脚本负责什么、读什么、写什么、什么时候必须重跑。所有脚本只读本机那份《白》ROM（`Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds`），产物落在 `client/assets/bw/**` 与 `server/content/rom/**`，仅供本地个人研究，已在 `.gitignore` 里，不提交、不分发。

整条管线分四层，每一层都可以单独重跑：

```
ROM ──①读取层──> 资源与数据 ──②抽取层──> client/assets/bw/**（GLB/PNG/JSON）
                                      └─③构建层─> server/content/**（地图、世界、剧情）
                                                        └─④校验层─> 退出码 + 报告
```

---

## 0. 一键入口

| 入口 | 做什么 |
| --- | --- |
| `rebuild-indoor.cmd` | 室内资源一键重建：抽取 → 室内世界 → 地图 → `godot --headless --import` → 自动 audit。改过家具规则或 `extract_unova_indoor.py` 后跑它 |
| `audit-maps.cmd` | 全量地图体检，报告写到 `.tools/map-audit/report.md` |
| `npm run audit:assets` | 家具解析 + 行走图方向，两类"看着像美术 bug"的数据问题 |
| `npm run audit:assets:test` | 自检：正确规则必须通过、`area[0]` 旧 bug 必须被抓到 |
| `npm run validate-content` | 剧情/地图/物种/道具引用与边界 |
| `npm run story:lint` | 剧情状态机：可达性、死分支、永远锁着的闸门、孤儿 flag |
| `npm test` | 服务端单测（含 `test/story.test.ts`） |
| `npm run smoke:story` | 起服务端跑一遍序章冒烟；跑完要关掉服务端 |

---

## 1. 读取层（纯 stdlib，不依赖任何第三方包）

| 脚本 | 做什么 | 关键接口 / 产出 |
| --- | --- | --- |
| `nds_fs.py` | 最小的 NDS ROM + NARC 读取器：FAT、FNT 文件名表、NARC 成员、按内容找档案 | `NintendoDSRom`、`NARC`、`named_files()`（247 个具名文件）、`magic_archives()`、`detect_script_archive()` |
| `prop_resolve.py` | 室内家具解析规则的唯一实现：id ≥147 是户外地图物件；两个 AB 档案是两套 id 空间；包只是贴图分组，房间可以从多个包取；档案按"贴图集是否指向本档案的包"评分 | `choose_bundle()`、`sources()`、`unresolved()`、`assign()`、`score()`、`name_conflicts()`。抽取器和 audit 都 import 它，规则不会两边跑偏 |
| `sprite_frames.py` | 解码抽取出来的 RGBA PNG，用肤色重心判断这一帧朝左还是朝右 | `read_png_rgba()`、`face_offset()`（负=朝左）、`skin_pixels()`。抽取时自检、`audit_assets --sprites` 复查都用它 |
| `field_models.py` | 野外模型 id → 精灵 id 的对象码表（`a/0/4/8`，每条 0x1C 字节） | 剧情内容里的 `sprite` 应写精灵 id，不是模型 id |
| `glb_bounds.py` | 读 GLB 的 JSON 块，把每个 `POSITION` 的 min/max 按节点矩阵变换后合成世界 AABB（ROM 单位，16 = 一格）。只解析头部，不解码几何，带按路径缓存 | `bounds(path)` → `((x,y,z),(x,y,z))`。家具碰撞的唯一数据来源 |

---

## 2. 抽取层（ROM → `client/assets/bw/**`，个别写 `server/content/rom/**`）

| 脚本 | 做什么 | 产出 | 依赖 |
| --- | --- | --- | --- |
| `extract_nuvema.py` | 最早的原型：把诺文镇一个 cell 抽成 Godot 可用的 3D 场景。也是共用库：`find_rom` / `lz11_decompress` / `read_narc` / `run_apicula` / `prop_bundle_models` | `client/assets/bw/nuvema/` | ndspy、Pillow、apicula |
| `extract_bw_map.py` | 抽任意一个室外 matrix cell（`--cell x,y`），Route 1 南北两段用它 | 指定的 `--out` 目录 | ndspy、apicula |
| `extract_unova_outdoor.py` | 全量室外：109 个 cell 的地形、道具、贴图 | `client/assets/bw/unova_outdoor/` | ndspy、apicula |
| `extract_unova_indoor.py` | 387 个室内 zone：地图模型按贴图集分批转换，家具按 `prop_resolve` 选档案/包；解析不了的场景逐个列出，`--strict-props` 时直接失败 | `client/assets/bw/unova_indoor/library.json` + `mapsets/` + `propsets/` | ndspy、apicula |
| `extract_overworld_sprites.py` | NPC 行走图：按家族给方向帧号（左 6–8、右 9–11），7/9 帧表镜像生成右侧，肤色重心自检 | `client/assets/bw/overworld/npc_<id>/frames/*.png` + `actor.json` | 纯 stdlib |
| `extract_bw_assets.py` | 战斗精灵：正/背面 96×96、闪光、训练家 | `client/assets/bw/` 下对应目录 | ndspy、Pillow |
| `extract_bw_ui.py` | 原版 UI：九宫格窗框、按钮、血条等 | `client/assets/bw/ui/` | ndspy、Pillow |
| `extract_battle_effects.py` | 招式动画脚本（`a/0/6/6`）与 SPA 粒子贴图 | `client/assets/bw/battle_effects/` | ndspy、Pillow |
| `extract_seasonal_props.py` | 季节树 `r01_a/b` 的春/夏/秋/冬四套模型（295–302） | `unova_outdoor/` 内的季节道具 | ndspy、apicula |
| `extract_town_map.py` | 城镇地图底图（`a/0/8/5`）+ 61 个地点表 | 地图 PNG + 数据 | ndspy、Pillow |
| `extract_species.py` | 种族值、属性、特性、升级学习表；`--apply` 写回 `game.json` 里现有的 roster | `server/content/rom/species.json` | ndspy |
| `extract_all_species.py` | 全 649 只，不做 roster 过滤 | `server/content/rom/species_all.json` | ndspy |
| `extract_moves.py` | 招式表（属性、分类、威力、命中、PP 等） | `server/content/rom/moves.json` | ndspy |
| `extract_encounters.py` | 查某个 zone 或 cell 的野生遇敌表（12 档），只读 | 打印或 `--json` | ndspy |
| `extract_trainers.py` | 训练家职业与队伍。ROM 文件名表不全，两个档案按内容定位 | `server/content/rom/trainers.json` | 纯 stdlib |
| `extract_dialogues.py` | 字段脚本 → 对白。指令宽度来自 `bw_script_ops.json` | `server/content/rom/npc_dialogues.json` | 纯 stdlib |
| `extract_zone_entities.py` | 每个 zone 的 NPC、warp、trigger（`a/1/2/5`） | `server/content/rom/zone_entities.json` | ndspy |
| `extract_outdoor_locations.py` | 室外 cell → 地名网格（HUD 左上角显示） | `server/content/rom/outdoor_locations.json` | ndspy |
| `extract_bw_audio.py` | 从 `wb_sound_data.sdat` 解析 SYMB/INFO/FAT，用 SBNK + SWAV 渲染 BGM（按 ROM zone 的秋季 BGM id 映射地点）和 19 个 SFX；OGG 只保留一轮原版 loop，`manifest.json` 记录 `loopOffset` | `client/assets/bw/audio/{bgm,sfx}/` + `manifest.json` | `tools/rom/audio/`（aletheia MIT 工具，已修噪声种子）、`ndspy`、`ffmpeg` |
| `fix_alpha_textures.py` | 把 alpha=0 像素的 RGB 换成最近不透明色，消掉双线性过滤造成的紫边/白边 | 就地改写 GLB 里的贴图 | Pillow、numpy |

### 音频管线（`tools/rom/audio/`）

`extract_bw_audio.py` 直接从 ROM 的 `wb_sound_data.sdat` 渲染原版 BGM/SFX，不再用 MIDI 合成：

- **容器**：SDAT 的 `SYMB`/`INFO`/`FAT`/`FILE` 四个块。`INFO` 头部 8 个 `u32` 是 8 张 record 表（SEQ/SEQARC/BANK/WAVEARC/PLAYER/GROUP/PLAYER2/STRM）的偏移；SEQ record 12 字节，`+4` 的 u16 是 BANK 索引；BANK record 12 字节，`+4` 起是 4 个 wave archive 槽位；FAT 每条 16 字节（offset/size/8 字节保留），offset 是文件在 SDAT 内的绝对偏移。
- **名称 → 序列**：SYMB 的 SEQ 表是 `u32 count + count*u32 名称偏移`，偏移相对 SYMB；名称顺序与 SEQ id 一一对应，所以能直接按名字取 `SEQ_BGM_*`/`SEQ_SE_*`。
- **地点 → BGM**：室外 `a/0/0/9` 的 29×27 matrix 有 zone grid，每个 zone header 的 `u16[7..10]` 是春/夏/秋/冬 BGM 序列 id；`extract_bw_audio.py` 把秋季 id 落成 32×32 格子的 `locationGrid`，客户端按 `self_grid // 32` 取曲，与语言无关。室内地图按各自的 `zone` 走 `indoorMaps`。
- **渲染**：`sdat.py`/`sseq.py`/`sbnk.py`/`swav.py`/`adpcm.py`/`sseqsynth.py` 从 aletheia（MIT）带进来，只做本地渲染。`sseqsynth` 额外记录了每个 track 第一次 backward `Jump` 的 tick，`probe_seq()` 不渲染音频就能给出 loop 起止，`--one-loop` 只渲染一轮；提取器按原版 loop 点截断并写进 manifest。PSG 噪声的 LFSR 原来以全 1 为种子（自洽不动点，所有噪声音效静音），已改成非不动点种子。
- **编码**：BGM 用 ffmpeg 转 OGG（Vorbis q4），SFX 直接保留 32 kHz 立体声 WAV；客户端运行时 `load_from_file` 读取，不依赖 Godot 导入缓存。音频属于版权素材，只落在 gitignored 的 `client/assets/bw/audio/`。

---

## 3. 构建层（assets → `server/content/**`）

| 脚本 | 做什么 | 产出 |
| --- | --- | --- |
| `build_unova_world.py` | 用室外 `library.json` 拼出无缝大地图：碰撞、高度、遇敌区域 | `server/content/worlds/unova_full.json` |
| `build_unova_indoor_worlds.py` | 室内每个场景的碰撞与可视清单（家具实例、地图模型路径） | `server/content/worlds/unova_indoor.json` |
| `build_unova_maps.py` | 室内地图与门：NPC、warp、trigger 落位；导出 NPC 的 `movement` 字节；丢掉 `spawnFlag` 条件重复项（家里的第二个妈妈就是这么来的）；按家具 GLB 的 AABB 把占据的格子写成墙（权限网格只标地板和墙，家具的碰撞在模型里）；把 ROM 的可交互物件导出成 `interactables`，并剔掉被家具围死、够不到的那些 | `server/content/maps/unova_in_*.json` |
| `build_dialogue_zh.py` | 用 PokeMMO 中文剧情 dump 对齐英文原文，生成中文对白 | `server/content/i18n/zh_CN/dialogue.json` |
| `prune_non_service_npcs.py` | 删掉占位/纯剧情 NPC，只留治疗、商店这类真的能交互的 | 就地改写 `server/content/maps/*.json` |

---

## 4. 剧情逆向与编译

| 脚本 | 做什么 | 用法 |
| --- | --- | --- |
| `trace_script.py` | 跑 ROM 的字段脚本 VM，打印事件流（台词、移动、战斗、flag） | `--zone` / `--npc` 或 `--script-id`，`--flag` 注入状态，`--battle` 选胜负 |
| `story_diff.py` | 把卧室、妈妈、研究所三个场景的 ROM 回放和 `nuvema.json` 逐句对齐，报"逐字一致 / 分页不同 / ROM 独有 / 剧情独有" | 直接运行，结论见 `docs/research/prologue_rom_diff.md` |
| `compile_story.py` | 把 ROM 脚本编译成我们的 `StoryStepDef` JSON（同一个脚本赢/输各跑一遍再对齐分叉） | 单场景或批量；产物 `server/content/rom/rom_prologue.json` |

---

## 5. 校验层（无头，替代"进游戏转一圈看看"）

### `audit_assets.py`

三类检查，全部只需要 ROM 和已经抽出来的文件，不需要 ndspy / apicula / GPU：

| 参数 | 检查内容 | 通过标准 |
| --- | --- | --- |
| `--props`（默认） | 从 ROM 重建每个 zone 的家具摆放（zone 头 → 区域记录 → matrix → chunk → 摆放表），按名字和 `library.json` 比 | 0 条问题；卧室 391 必须解析出 `tv01 / stair_d01 / plant01` |
| `--sprites`（默认） | 每张行走图的左/右帧朝向、正面有没有脸、背面有没有露脸 | 左偏为负、右偏为正 |
| `--self-test` | 用当前规则合成一份 library（必须通过），再用 `area[0]` 旧 bug 合成一份（必须失败并点名卧室） | 两句都成立才退出 0 |

失败按类别聚合（错包、少了哪些、多了哪些、磁盘缺文件），不会刷几百行。`--json` 给机器读。

### `audit_maps.py`

一次扫全部 386 张地图，查这几类人工巡检容易漏的问题：GLB/manifest 缺失、portal 目标不存在、出生点被 NPC 挡住、不该出现的剧情 NPC、相邻可走格高度差 >24（隐形墙）、发光材质用了普通 alpha 混合（白色卡片）。产出 Markdown 报告 + `height-pairs.csv`。

### 客户端侧静态检查（需要 Godot，`godot --headless --script` 运行）

`client/tests/` 下的 `check_indoor_props.gd`（家具是否真的写进地图）、`check_npc_sprites.gd`（NPC 有没有身体、`.import` 是否齐全）、`check_rom_assets.gd`（引用的资源是否都在）、`check_visual_runtime.gd`（可视清单与运行时数据一致），以及战斗/HUD/商店/图鉴布局检查。

---

## 6. 依赖与环境

| 依赖 | 脚本 | 说明 |
| --- | --- | --- |
| 纯 stdlib | `nds_fs.py`、`prop_resolve.py`、`sprite_frames.py`、`audit_assets.py`、`extract_overworld_sprites.py`、`extract_dialogues.py`、`extract_trainers.py`、`trace_script.py`、`story_diff.py`、`compile_story.py`、`build_dialogue_zh.py`、`prune_non_service_npcs.py` | 这台 Linux VM 里能直接跑 |
| `ndspy` | 绝大多数 `extract_*` 与 `build_unova_*` | VM 里没装且装不了（无外网），需要在 Windows 本机跑 |
| `apicula.exe`（`.tools/apicula/`） | `extract_nuvema`、`extract_bw_map`、`extract_unova_outdoor`、`extract_unova_indoor`、`extract_seasonal_props` | 把 NSBMD + BTX0 转成 GLB；Windows PE，VM 里跑不了，所以重建资源必须在你的机器上执行 |
| Pillow / numpy | 战斗精灵、UI、城镇地图、`audit_maps`、`fix_alpha_textures` | 同上 |

---

## 7. 典型重跑顺序

只改家具解析规则或 `extract_unova_indoor.py`：

```
rebuild-indoor.cmd
```

改了行走图抽取（方向帧号、镜像）：

```
python tools\rom\extract_overworld_sprites.py --rom "...nds"
godot --headless --path client --import
npm run audit:assets -- --sprites
```

改了剧情数据：

```
cd server
npm run validate-content
npm run story:lint
npm test
npm run smoke:story      # 跑完把服务端关掉
```

只想知道某个房间在原版里摆了哪些家具、为什么某件没渲染：

```
python tools/rom/audit_assets.py --props
```

---

## 8. 它替掉的验收点

| 以前要你肉眼确认 | 现在由谁判断 |
| --- | --- |
| 楼梯/家具没渲染 | `audit_assets --props`（卧室 391 是金丝雀） |
| NPC 倒着走、左右帧反了 | `audit_assets --sprites`（肤色重心；抽取时也会自检） |
| NPC 只有名字没有身体 | `check_npc_sprites.gd`（`.import` + 帧号偏移） |
| 剧情 NPC 走错方向/穿墙 | `validate-content`（逐跳相邻 + 目标格可走，服务端运行时再校验一次） |
| NPC 说话时不看你 | `face` 步骤 + `npm run validate-content` |
| 两个妈妈、重复 NPC | `build_unova_maps.py` 的 `spawnFlag` 去重 |
| 地图有隐形墙、portal 通不了 | `audit_maps.py` |
| 家具能穿过去、撞不到 | `build_unova_maps.py` 用 GLB AABB 盖墙；围死的物件不会进 `interactables` |
| 剧情和原版对不上 | `story_diff.py` |

---

## 9. 已知边界

- 23 个 zone（289–316）虽然走的是室内 matrix，其实是尼姆巴沙市、涟漪镇这类户外地图，它们缺的 109/146 两个 id 是户外物件，不属于室内家具档案；audit 会把它们列出来而不是当成回归。
- `audit_assets` 只比对数据（摆放、名字、方向），不判断"好不好看"；光影、遮挡、镜头这类仍然需要真机。
- 室内地图模型自带的家具有碰撞（AABB 盖墙），但名字拿不到：能查的 406 个物件里 392 个只显示 "It's furniture." 这类通用文案（中文客户端显示"是一件家具。"，标签和文案都在 `server/content/i18n/zh_CN/` 里）。ROM 的物件脚本是全局脚本调用（0x38/0x43/0x44），本地 VM 还没解出来，所以只用了按模型名猜的标签兜底；解出来的两个物件（天际塔的钟、联合塔的电梯）保留原文。
- VM 里不能跑 apicula、ndspy、Pillow、Godot，所以涉及 GLB 转换或渲染的步骤必须在你的 Windows 上执行；其余校验我可以直接在这里跑。
