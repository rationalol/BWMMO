# BWMMO Prototype

一个以《宝可梦 白》为长期目标、**从 ROM 解析素材重新拼装**的联网游戏。当前版本不是完整的《白》复刻，而是一个已经跑通“原版素材 + 服务器权威联机”的垂直切片：

- **完整 Unova 室外世界**：109 个非空 overworld matrix 格子拼成 928×864 的连续战场，地形、道路、草丛、城镇和角色动画全部从本地 ROM 提取
- 室外不再有地图切换：客户端按玩家所在的 2D 格子流式加载/卸载地形；当前半径 2，会保持周围 5×5 格
- **瓦片窗口 + AOI**：服务器只下发玩家周围 65×65 的碰撞瓦片（约 4 KB，替代 830 KB 全量地图），接近边缘时用 `map_window` 重新下发局部窗口；玩家移动广播限制在半径 64 格内，并用 32 格网格索引查询邻近玩家
- **室内场景已接入**：382 张室内/独立场景地图、222 张可从室外门、桥梁或室内楼梯到达。门口传送、室内出口、楼梯和当前保留的服务 NPC 来自 ROM 的 zone entities（`a/1/2/5`），进屋会保留独立 `map_state` 加载和短淡入；5 个没有可站立地面的特殊场景会跳过
- **剧情层 + 诺文镇序章**：`server/content/story/*.json` 用数据描述场景、对白、选择御三家、flag、NPC 可见性、tile 触发器和道路闸门；服务器按玩家自己的 `storyFlags` 推进，不依赖客户端。当前序章从卧室开始（Cheren/Bianca 对白 → 打开礼物盒选御三家 → 获得第一只宝可梦 → 下楼找妈妈治疗 → 去博士研究所拿图鉴）；选御三家是全屏礼物盒场景：桌面上的紫色礼物盒里摆着三颗精灵球，悬停/方向键查看，点选后宝可梦从球中现身，再按确认或点金色按钮决定，没选伙伴或没拿图鉴时诺文镇北出口会被剧情挡住并给出台词，拦路的 Bianca/Cheren 本人就站在地图上（各自独立立绘，不是主角占位）；房间里的 Cheren/Bianca 在选完伙伴后对其他玩家消失。对白仍取自 `a/0/5/7`/`a/0/0/3` 解码文本，少量衔接句为手写
- 账号注册 / 登录 / 令牌续连 / 设置内退出登录（吊销令牌并回到登录页）
- 角色创建（原版流程：创建时不选伙伴，空队伍在卧室醒来，第一只宝可梦由序章发放）、服务器存档
- 同屏多人移动、全局聊天、聊天气泡、原版 32×32 像素小人四方向走路/跑步动画
- **聊天栏三页签**：`World` 是世界频道；`System` 是个人冒险日志（遭遇、出招、捕捉、击败、升级、进化、学习/遗忘招式、道具获得与使用、治疗、PC 存取），按类别着色；`Social` 保存与好友或附近玩家的私聊会话。连接与服务器错误日志移到 `Settings → Diagnostics → Connection log`
- **社交**：右下角 `Social` 面板列出好友（在线/离线）、待处理的好友申请和附近玩家，可查看距离、发送申请、同意/拒绝/撤回申请、删除好友，并从列表直接打开私聊；好友关系只在对方同意后建立并写入双方角色存档，私聊只允许好友或当前可见的附近玩家
- **好友切磋**：好友行提供 DUEL，对方收到决斗弹窗后接受/拒绝；接受后双方进入同一场 Showdown 单打战斗，各自选招和换人，切磋中禁用背包、精灵球和逃跑，断线视为认输；赛后不结算金币/胜场/经验，双方队伍回满并留在原地
- 治疗/商店/PC 服务 NPC 交互；碰撞、位置和交互距离由服务器裁定
- **全量 Gen 5 内容**：649 只宝可梦、559 个招式、全部升级学习表、71 个 ROM 遇敌 zone；属性克制和升级由 Showdown 结算
- **宝可梦特性**：每只宝可梦按物种分配并保存特性槽（普通 1 / 普通 2 / 隐藏）；队伍详情显示本地化名称、隐藏标记和说明；研究所的“特性专家”可在同物种的合法特性之间切换并立即写档；战斗中换人或发动的特性会以顶部提示显示名称和效果说明
- **养成闭环**：320 条 Gen 5 进化关系（等级、道具、亲密度、交换等），等级达标后自动进化并保留等级/经验/招式/PP；升级触发进化时播放 BW 风格演出（背景压暗、旧形态剪影黑白频闪、全屏白闪后揭示新形态）；图鉴记录 649 个编号的 Seen/Caught；满 4 招升级时进入“替换/放弃”选择而不是静默顶掉旧招；每招 PP 在战斗后写回存档，护士治疗同时回满 PP
- **努力值（EV）**：击败野生或训练家的宝可梦后，按该物种的 ROM 努力值产出加到出战宝可梦身上（单项 255、总和 510 上限），并即时重算能力值；IV、性格与 EV 一起参与 Gen 5 能力公式，客户端队伍详情可直接查看
- **补全养成操作**：TM（可重复使用）与招式教学/回忆 NPC 共用现有的“学习/替换”流程；进化石对队伍成员直接使用即可触发道具进化；亲密度达到 220 后升级触发亲密度进化；连接交换台模拟交换进化并检查所需携带物；PC 支持改名（1–12 字符，可用中文）和放生。研究所里放了 6 个测试 NPC 和 1 台测试 PC，首次交谈会发放 TM、进化石以及 Pikachu/Kadabra/Golbat 测试队伍，方便逐项验证
- **战斗动画立绘**：前后立绘使用 Showdown Gen 5 动画帧表，进入战斗后循环播放待机动画；缺帧时回退到 ROM 静态图
- **原版招式特效**：559 个招式的动画脚本从 `a/0/6/6` 解码，粒子贴图/调色板从 `a/0/0/6` 提取。客户端按原版脚本的 `LoadSPA`、`PlaySPAAnimation`、`PlaySPAProjectile`、`Wait`、相机与精灵抖动命令播放撞击星、火花、火焰、心形等真实 BW 粒子；没有素材时按招式属性回退到程序特效。服务器给每个回合附带结构化 `events`，伤害、克制、异常和倒下与动画同步
- **原版战斗画面**：天空、草地和双层圆台按 BW 的四季战斗背景重绘（`batt_bg02a-d` / `batt_stage23a-d` 配色）；HP 条、名字、性别、等级、HP 数字和 EXP 条使用 ROM 字体与配色，指令层按原版组织为 FIGHT / BAG / POKéMON / RUN，再进入招式、背包或队伍子菜单
- **昼夜系统**：客户端世界时钟默认 60×（24 分钟过完一天），HUD 左上显示 `Dawn / Day / Dusk / Night` 和 `HH:MM`；天空渐变、环境光、太阳/补光以及全屏 multiply 色罩在黎明/白天/黄昏/夜晚之间连续插值，室内保持较亮；战斗场地和宝可梦立绘也同步时间色调。`--time=18:30` 指定起始时间，`--time-scale=10` 调整速度，`--real-time` 或 `--freeze-time` 切换真实/冻结时钟
- **动态世界**：室外植被使用风摆 shader，程序化天空背景遮住地图边缘，树木材质改为双面 + alpha scissor + linear mipmap；远景雾已关闭，避免白膜
- **具体地名**：无缝合众地图按 ROM 的 32×32 地图矩阵拆成 40 个区域（城镇、道路、洞穴等），HUD 训练家卡显示当前格子对应的具体地名，例如诺文镇、1号道路、唐草镇；服务端在 `map_state` 和 `move_ack` 里下发按语言渲染的 `location`。
- **实时 3D 区域图**：HUD 不再挂常驻小地图；右下角 `Map` 入口打开的区域图使用独立 `SubViewport` 镜像当前已加载的地形块、房屋和角色，以俯视 3/4 相机实时渲染（放大时相机自动拉远）。镜像共享网格/材质资源，只在 chunk 加载/卸载时复制节点；旧的 2D 城镇地图仍回退到瓦片图。
- **世界地图**：`Map` 打开当前区域放大图，右下角独立的 `World` 入口打开合众总览。世界地图使用 ROM 原版合众地图底图（`a/0/8/5` file 7，256×168）和 `a/0/8/6` 的 61 个地点坐标，显示全部 40 个命名区域；当前区域用脉冲红点标出，城镇/道路/地标使用不同标记，悬停或点击标记可看到地名。`map_state.worldMap` 按玩家语言下发地点名；底图未提取时仍会用 40 个标记画出简图，区域图不受影响。
- **原版季节花树**：ROM 的花树是 `r01_a/b_spring/summer/autumn/winter` 模型替换（prop 295–302），不是 shader 变色。已提取全部季节变体并用 `seasonal_props.json` 按当前季节替换，秋季加载真正的 `r01_*_autumn` 模型；`kisetu_hana`/`hana` 小花再用色相重映射补充。默认秋季，`--season=spring|summer|autumn|winter` 可切换
- **3D 地面高度**：室外每个地图 chunk 附带从 ROM `MapHeightTile` 解码的 32×32 高度图——和 permission grid 是同一份 8 字节条目（低 2 位 shape、14 位 slope 索引、16 位平面 offset 索引，split 瓦片带两块斜面），不再从 GLB 网格采样；室内仍按 GLB 采样（室内模型自带楼层偏移）。人物、NPC 和其他玩家按脚下地形高度站立，楼梯/坡道平滑过渡；高草丛会把角色抬到草丛叠层（`kusa_ec1/2/3`，高出地形 2–10 单位）的最高表面，避免草叶几何体从中间切进角色；服务器在每一步移动时比较脚下高度：向上超过 24 单位（1.5 格）会被拒绝，向下最多 128 单位（8 格）允许跳下，所以不能再爬上墙体或悬崖
- **伪 3D 层次**：地形/建筑使用 ROM 烘焙顶点色 + 轻微方向明暗，3D 贴图改用线性 mipmap 过滤，接近原版柔和的 DS 观感；树底的 `ki02c`/`ki02dx`/`kage` 阴影卡片按半透明 alpha blend 渲染，不再被 alpha scissor 裁成黑块；不投实时方向光阴影，角色和 NPC 使用落地 blob shadow，相机下压到更低的俯视角；人物本身仍是原版 32×32 2D billboard，帧图只有全透明/不透明两种 alpha，因此启用 alpha scissor（`ALPHA_CUT_DISCARD`）写入深度，半透明的池塘水面（`ike01`）和其他透明叠层在角色身后时会被正确剔除，不再盖到人物身上。走路 4 帧/4fps、跑步 4 帧/8fps（一个步态循环含两次落脚、跨两格），移动时间与步间隔严格对齐
- 最多 6 只的队伍、战斗内换宠、药水/球道具、服务器权威回合制战斗（Showdown Gen 5 规则内核）
- **抓—养—治—买闭环**：Poké/Great/Ultra Ball 三种捕获率、Potion/Super Potion/Hyper Potion、Full Heal、Revive；诺文镇出生点南侧的 Nurse Joy 免费回满 HP 并清除异常状态；Mart Clerk 买卖道具（卖价半价）；PC 终端可存取 30 只宝可梦，存储时保留 HP/异常状态；野生战斗内也能用球和药，但会消耗回合（好友切磋中禁用）
- **背包与消费**：HUD 背包按 Balls / Medicine 分页显示数量与描述，药水可直接选择队伍成员使用；战斗背包按持有的球种逐个列出，药品再选目标；金钱来自战斗胜利，商店买卖由服务器校验库存、携带上限和 NPC 距离
- 断线自动重连
- **原版 BGM / 音效**：从 ROM 的 `wb_sound_data.sdat` 用原版 SWAV 采样渲染全部室外地区、382 张室内地图、Pokémon Center、博士研究所、野生/训练家战斗和标题画面 BGM；菜单、对话、传送、撞墙、治疗、升级、捕捉等 19 个音效取自同一份 SDAT，按地图/zone 自动切换，BGM 带原版循环点
- **NDS 风格 ABXY 交互**：桌面 `WASD` 移动、`J`=A（对话/确认）、`K`=B（取消/返回，按住跑步）、`U`/`I`=X/Y（预留）；安卓左手 D-pad、右手 ABXY 菱形布局，B 按住跑步，X/Y 预留；触摸时聊天栏移到右上角、点输入框即可打字
- **启动加载动画**：启动图 + 进度条 + 旋转精灵球加载页；Android 首次启动把约 247 MB 的 `game.pck` 分块复制到 `user://` 并显示百分比进度，之后启动直接挂载缓存，不再长时间黑屏
- 桌面键盘 + Android 触摸操作
- 内容数据放在 JSON 文件中，带校验器和独立校验命令
- 本地 ROM 素材管线：649 只宝可梦前后立绘、24 个训练家立绘、109 个室外地图格、387 个室内场景和角色

旧的 2D 占位城镇 / 路线 / 森林仍保留在 `server/content/maps`，用于战斗、遇敌和传送的回归测试。当前主流程是完整 Unova 室外世界 + 可进入的室内场景：野外草丛会触发服务器结算的野生战斗，诺文镇的房屋和博士研究所可以从门口直接进入。

项目结构：

```
BWMMO/
├─ client/          Godot 4 客户端（GDScript）
│  └─ assets/bw/    本地提取的 BW 素材（gitignored，不上传）
├─ server/          TypeScript + Node.js 权威服务器
│  └─ content/      地图、宝可梦、招式、遇敌表（JSON）
├─ tools/rom/       ROM 素材提取工具
├─ docs/            协议与架构文档
├─ PokeMMO-Client.apk       参考用客户端（未纳入版本控制）
└─ Pokemon - White ...nds   ROM 参考文件（未纳入版本控制）
```

> 这是技术原型。请遵守版权规定，不要分发 ROM 素材或 PokeMMO 的素材/代码。

---

## 快速开始

### 环境要求

- Node.js 20+（本项目在 Node 22 上开发）
- Godot 4.4.x（项目按 4.4.1 编写；`client/project.godot` 可直接打开）
- 可选：Python 3.10+、`ndspy`、`Pillow`（仅用于从 ROM 提取本地素材）
- 无需数据库或 Docker

### 0. 提取本地 BW 素材（战斗立绘，可选）

这一步让战斗立绘、训练家立绘和 Nuvema 场景使用真正的 BW 素材。素材只在本地生成，`client/assets/bw/` 已加入 `.gitignore`，不会进入仓库。

```bash
pip install ndspy pillow
python tools/rom/extract_bw_assets.py   --rom "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
```

产物：

- `client/assets/bw/pokemon/<species>_front.png` / `_back.png`（649 只宝可梦的 96×96 静态战斗立绘）
- `client/assets/bw/trainers/<id>.png`（24 个 BW 训练家立绘）
- `client/assets/bw/manifest.json`

战斗待机动画单独下载并转成客户端帧表（需要网络，缓存在 `.tools/showdown_sprites`；产物仍在 gitignored 的 `client/assets/bw/`）：

```bash
python tools/fetch_battle_sprites.py
```

产物是 `client/assets/bw/pokemon_anim/<species>_front.png` / `_back.png` 和 `manifest.json`。每只宝可梦取 GIF 开头稳定的待机段，前后立绘各约 1–30 帧；没有动画数据时客户端自动回退到 ROM 静态立绘。

招式特效同样从本地 ROM 提取（动画脚本、粒子遮罩与调色板）：

```bash
python tools/rom/extract_battle_effects.py --rom "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
```

产物在 `client/assets/bw/battle_effects/`：`manifest.json` 保存 559 个招式的命令序列和 568 组效果索引，`effect_<id>.png` 是每组效果按原版 TPS 遮罩/调色板生成的贴图集。客户端会用原版脚本的时序和发射目标播放这些贴图；素材缺失时仍可用程序特效进入战斗。

宝可梦与训练家素材缺失时，客户端会自动回退到程序绘制占位图。请只对自己拥有的 ROM 使用，不要分发提取出的素材。

### 0.2 提取 BW 原版 UI（可选，HUD 皮肤）

HUD 的 9-slice 窗口边框和像素字体可以直接从 ROM 提取。字体是原版 NFTR 转成的 BMFont；窗口边框来自 `a/0/0/5`，几何保持原样，调色板重映射到客户端的深色 HUD：

```bash
python tools/rom/extract_bw_ui.py --rom "Pokemon - White Version (USA, Europe) (NDSi Enhanced).nds"
```

产物（同样在 gitignored 的 `client/assets/bw/` 下）：

- `client/assets/bw/ui/window_frame.png`：24×24 的 9-slice 窗口框
- `client/assets/bw/ui/bw_font.fnt` / `bw_font.png`：Godot 可直接加载的 BMFont
- `client/assets/bw/ui/items/`：原版精灵球道具图标（Poké/Great/Ultra/Master Ball）
- `client/assets/bw/ui/types/`：17 种属性的原版 32×16 类型徽章
- `client/assets/bw/ui/ui_manifest.json`：来源档案和尺寸

HUD、聊天、菜单和对话会自动使用这些素材；如果文件不存在，客户端会回退到程序绘制的深色 UI，所以没有 ROM 素材时仍可运行。聊天记录和输入框保留系统字体，以支持中文等原版字体没有的字符。

选御三家的全屏礼物盒场景使用仓库内自带的生成美术，不依赖 ROM：

```bash
python tools/build_starter_ui_assets.py
```

产物在 `client/assets/ui/starter/`（桌面背景、打开的礼物盒、精灵球和柔光贴图）。

### 0.5 构建完整 Unova（默认流程，必需）

完整室外世界需要先提取所有非空地图格和角色。若暂时没有 ROM 素材，可以把
`server/content/game.json` 的 `startingMap` 改为 `"town"`，以旧的 2D 占位流程运行。
还需要 Apicula：

1. 下载 [Apicula](https://github.com/scurest/apicula/releases) 的 Windows 版本，放到 `.tools/apicula/apicula.exe`
2. 运行：

```bash
# 全量物种/招式 -> server/content/game.json
python tools/rom/extract_all_species.py
python tools/rom/extract_moves.py
(cd server && npm run build-content)
# 世界与室内
python tools/rom/extract_nuvema.py
python tools/rom/extract_unova_outdoor.py
python tools/rom/build_unova_world.py
# 室内场景素材 + 碰撞 + 门/NPC 数据
python tools/rom/extract_unova_indoor.py
python tools/rom/build_unova_indoor_worlds.py
python tools/rom/extract_zone_entities.py
python tools/rom/extract_dialogues.py
python tools/rom/build_unova_maps.py
# 世界地图底图与地点坐标（区域图之外的 World 入口）
python tools/rom/extract_town_map.py
```

仓库里已经有生成好的 `game.json`；只想重建地图时可以跳过前三行。

产物：

- `client/assets/bw/nuvema/actors/`：原版 `fmdl_hero` 系角色帧和 `actor.json`
- `client/assets/bw/unova_outdoor/`：109 个室外格的地形/道具和 `library.json`（约 51 MB）
- `server/content/maps/unova_full.json`：可玩的 928×864 完整室外地图（约 830 KB；生成源同时在 `server/content/worlds/`）
- `client/assets/bw/unova_indoor/`：387 个室内 zone 场景，5900 个房间格（约 175 MB）
- `server/content/worlds/unova_indoor.json`：室内场景碰撞数据（来自 map chunk 的 permission grid）
- `server/content/rom/species_all.json`：649 个图鉴编号的种族值、属性、捕获率和完整升级学习表
- `server/content/rom/moves.json`：559 个招式的类型、分类、威力、命中、PP 和优先度
- `server/content/rom/zone_entities.json`：427 个 zone 的 NPC、传送门、触发器
- `server/content/rom/npc_dialogues.json`：按 zone/NPC 解码出的台词、story flag 和条件分支（当前 278 个 zone、966 个 NPC profile、164 个分支）
- `server/content/maps/unova_in_<zone>.json`：382 张室内/独立场景地图（222 张可从室外门/楼梯到达，含门、楼梯和当前保留的服务 NPC）
- `client/assets/bw/ui/unova_map.png`：原版合众世界地图底图（256×168，本地 ROM 素材）
- `server/content/rom/world_map.json`：40 个命名区域的城镇/道路/地标标记坐标（来自 ROM 的 61 地点表）

服务器把完整室外地图作为 `unova_full` 加载，出生点仍是诺文镇。客户端根据服务端下发的 `visual.chunks` 在玩家周围加载 5×5 格地形；碰撞瓦片只下发玩家周围的 65×65 窗口（约 4 KB），玩家接近窗口边缘时服务器发送 `map_window` 重新居中，不再传输整张 928×864 网格。室内使用独立 `map_state`：ROM 门洞按 warp 的完整 footprint（常见 1×3 侧门、3×1 正门）铺 `P` 瓦片，并保留原版的 `contactDirection` 作为入口方向——正面门按 W、东墙侧门按 A、西墙侧门按 D、北面门按 S，方向不符不会传送。门格本身是实心的时候，触发点铺满门前整排/整列（1×3 门就是 3 格触发）：先走上门前地板，再朝门推一次才进入（原版的两步接触）；门格本身可走的门则在方向匹配的那一步触发。刚落地的那一格会短暂失效，避免宽门洞来回弹。切换地图时客户端会短暂显示淡入遮罩。

室内 GLB 和 ROM 行走图（`client/assets/bw/overworld/npc_*/frames/*.png`）首次使用前需要导入缓存。新抽出来的 PNG 没有 `.import`，客户端虽然会退化成直接读原始 PNG，但 `godot --headless --import` 跑一遍更稳、启动也更快：

```bash
.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client --import
```

`run-nuvema.cmd` 仍可单独打开离线场景做素材预览；正常游戏请启动服务器和客户端，角色会直接出生在诺文镇。

### 1. 启动服务器

```bash
cd server
npm install
npm start
```

默认监听 `0.0.0.0:2567`。启动后会打印：

```
WebSocket: ws://localhost:2567
LAN (use this on your phone):
  ws://192.168.x.x:2567
Health:    http://localhost:2567/health
```

存档写入 `server/data/store.json`。可通过环境变量覆盖配置：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `2567` | 监听端口 |
| `HOST` | `0.0.0.0` | 监听地址 |
| `DATA_DIR` | `server/data` | 存档目录 |
| `CONTENT_DIR` | `server/content` | 内容数据目录 |
| `ENCOUNTER_RATE` | 地图配置 | 强制遇敌概率（0~1，测试用；诺文镇范围没有遇敌区） |
| `TILE_WINDOW_RADIUS` | `32` | `map_state`/`map_window` 的瓦片窗口半径（65×65） |
| `TILE_WINDOW_MARGIN` | `16` | 距窗口边缘多少格时提前发送新窗口 |
| `AOI_RADIUS` | `64` | 玩家可见/移动广播的 Chebyshev 半径（格） |

### 2. 启动客户端

用 Godot 4.4.1 打开 `client/project.godot`，按 F5 运行。

Windows 下也可以直接双击根目录的 `run-server.cmd` 和 `run-client.cmd`（客户端脚本使用本项目下载到 `.tools` 的 Godot）。

或在命令行：

```bash
# Windows 示例
"C:\path\to\Godot_v4.4.1-stable_win64.exe" --path client
```

登录界面中：

1. 输入用户名和密码
2. 点 **Create account** 注册，或 **Log in** 登录
3. 首次进入会要求创建训练家（名字必须全服唯一）
4. 出生在 **Nuvema Town** 中央；`sprite` 决定使用原版主角/配角小人（0 Hilbert、1 Hilda、2 男孩 NPC、3 女孩 NPC）
5. 沿中央道路往北走出诺文镇，进入 **Route 1**；进入草丛会触发野生战斗

客户端默认连接 `ws://122.51.98.40:2567`，登录界面不再需要填写服务器地址。本机联调时用 `--server` 覆盖：

```bash
".tools\Godot_v4.4.1-stable_win64.exe" --path client -- --server=ws://127.0.0.1:2567
```

`run-client.cmd` / `run-client-debug.cmd` 已经带上这个参数，配合 `run-server.cmd` 可以直接本机测试。

**手机/局域网测试**：手机和电脑连同一个 Wi-Fi，启动客户端时用 `--server=ws://192.168.x.x:2567` 指向电脑。Android 导出时需要在导出设置中勾选 `INTERNET` 权限。

Android 打包（PCK 资源包、导出与签名）见 [docs/ANDROID_BUILD.md](docs/ANDROID_BUILD.md)。

### 3. 双人测试

启动服务器后，同时运行两个客户端，用不同账号注册/登录。两个角色会先按序章流程出生在玩家家卧室，完成序章进入 Nuvema Town 后相遇；移动、聊天和聊天气泡会实时同步。出生点南侧保留了 Nurse Joy、Mart Clerk 和 PC 终端，研究所里还有测试用的养成 NPC。

好友功能在右下角导航的 **Social** 面板：附近训练家可直接 ADD，收到申请后 ACCEPT/DECLINE，好友可 CHAT 私聊或 REMOVE。两个 headless 客户端可用 `--auto-social` / `--auto-social-b` 自动验证“申请 → 同意 → 私聊 → 回复 → 删除”整条链路，不需要窗口或截图：

```bash
.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client -- --auto-social --server=ws://127.0.0.1:3567
.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client -- --auto-social-b --server=ws://127.0.0.1:3567
```

好友切磋：好友行有 **DUEL** 按钮，对方收到决斗弹窗后 ACCEPT/DECLINE。接受后双方进入同一场服务端权威的 Showdown 单打战斗，各自选择招式和换人；切磋中禁用背包、精灵球和逃跑。赛后不结算金币、胜场或经验，双方队伍回满并留在原地。两个 headless 客户端可用 `--auto-duel` / `--auto-duel-b` 自动跑完“加好友 → 决斗邀请 → 接受 → 战斗 → 结算”：

```bash
.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client -- --auto-duel --server=ws://127.0.0.1:3567
.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client -- --auto-duel-b --server=ws://127.0.0.1:3567
```

### 4. 自动截图演示（开发用）

服务端单独起一个测试端口（会写入独立存档）：

```bash
cd server
PORT=3567 DATA_DIR="F:/AgentProject/BWMMO/.tools/demo-data" ENCOUNTER_RATE=0 npm start
```

然后开两个终端（路径换成你的 Godot 可执行文件）：

```powershell
& ".\.tools\Godot_v4.4.1-stable_win64.exe" --path client -- --auto --server=ws://127.0.0.1:3567 --screenshot=F:/AgentProject/BWMMO/.tools/shot-a.png
& ".\.tools\Godot_v4.4.1-stable_win64.exe" --path client -- --auto-b --server=ws://127.0.0.1:3567 --screenshot=F:/AgentProject/BWMMO/.tools/shot-b.png
```

两个客户端会自动注册账号、创建角色、进入诺文镇、移动几步，然后保存截图并退出。`--touch` 可以强制显示触摸 D-pad/ABXY。

其他开发用自动模式（除特别说明外，截图模式都需要 `--screenshot=<绝对路径>`）：

| 参数 | 行为 |
|---|---|
| `--auto` / `--auto-b` | 在当前出生地图诺文镇里走动、发一句聊天后截图 |
| `--auto-social` / `--auto-social-b` | 两个 headless 客户端自动加好友、私聊、回复并删除好友，不需要截图 |
| `--auto-duel` / `--auto-duel-b` | 两个 headless 客户端自动加好友、发起并接受决斗、选招打到结算，不需要截图 |
| `--auto-run` | 用原版跑步帧在诺文镇跑一段后截图 |
| `--auto-dialogue` | 已停用（当前没有剧情 NPC） |
| `--auto-create` | 注册到创建角色界面后截图 |
| `--auto-reconnect` | 进入世界后主动断开 socket，验证 token 重连后截图 |
| `--auto-indoor` | 走进诺文镇研究所并截图 |
| `--auto-house` | 走进玩家家并截图 |
| `--auto-cliff` | 走到 Route 1 的高差/河边观察点并截图 |
| `--capture-login` | 显示登录页并截图（不连接服务器） |
| `--auto-battle` | 旧 2D 流程：需要把 `server/content/game.json` 的 `startingMap` 改回 `town` |
| `--auto-grove` | 旧 2D 流程：同样需要 `startingMap: "town"` |
| `--season=spring\|summer\|autumn\|winter` | 切换花树季节配色，默认 `autumn` |

常驻调试窗口：

```bash
./.tools/Godot_v4.4.1-stable_win64_console.exe --path client -- \
  --auto --debug-keep --server=ws://127.0.0.1:3578 \
  --debug-shot=F:/AgentProject/BWMMO/.tools/live.png
```

`--debug-keep` 走完自动路径后不退出，并把窗口拉到前台；`--debug-shot` 每 2 秒覆盖写一次当前画面，便于不开截图模式也能观察改动。

测试特定地点时可以用服务端 `DEBUG_START_X` / `DEBUG_START_Y` 覆盖新角色出生格，例如直接把角色放在 Route 1 花田：

```bash
DEBUG_START_X=786 DEBUG_START_Y=720 PORT=3579 npm start
```

---

## 操作

| 操作 | 桌面 | 触摸 |
|---|---|---|
| 移动 | `WASD` / 方向键 | 左侧 D-pad（按住方向） |
| 跑步 | 按住 `K`（B）+ 移动（`Shift` 也可） | 按住 `B` + D-pad |
| 对话 / 继续对话 / 确认 | `J`（A）/ `Space` / `Enter` | `A` 按钮；对话面板可点按 |
| 取消 / 返回 | `K`（B）/ `Esc` / `F` | `B` 按钮 |
| X / Y（预留） | `U` / `I` | `X` / `Y` 按钮 |
| 打开聊天 | `T` / `Enter` | 点聊天栏输入框（触摸时在右上角） |
| 发送聊天 | `Enter` | 键盘 `Enter` 或发送按钮 |
| 背包 / 队伍 / 区域图 / 世界地图 / 社交 / 设置 | 右下角 `Bag` / `Party` / `Map` / `World` / `Social` / `Settings` | 同左（触摸时导航移到右上角） |
| 使用药水 | 打开 `Bag` → `Medicine` → 选中道具 → `USE` | 同左 |
| 商店 / PC | 走到 NPC 旁按 `J`（A） | 走到 NPC 旁点 `A` |
| 关闭聊天/对话/菜单 | `K`（B）/ `Esc` / `F` | `B` 按钮 |

游戏内 UI 支持 English 与简体中文（默认跟随系统语言）。中文使用打包的 Noto Sans SC，英文仍使用 BW 位图字体；登录界面和 `Settings → Language` 都可以切换，选择保存在 `user://settings.cfg`。服务端代码和协议字段使用英文；说明文档为中文。物种、招式、道具、地图和 NPC 名称已生成中文名；冒险日志（`journal`）按客户端语言渲染；NPC/剧情台词和说话人名称已接入中文，服务器 notice 仍是英文源。

---

## 音频

BGM 和音效全部来自本地 ROM 的 `wb_sound_data.sdat`：`tools/rom/extract_bw_audio.py` 用 SDAT 的 SYMB 名称表解析序列，用原版 SBNK 乐器 + SWAV 采样渲染（`tools/rom/audio/` 是从 aletheia 项目带进来的 MIT 资产工具，修掉了 PSG 噪声固定种子导致音效静音的 bug），输出到 gitignored 的 `client/assets/bw/audio/`：

```bash
python tools/rom/extract_bw_audio.py            # 首次渲染全部 BGM/SFX（约 30 分钟）
python tools/rom/extract_bw_audio.py --only SEQ_BGM_T_01
python tools/rom/extract_bw_audio.py --list     # 只打印地点/zone → BGM 映射
```

- `bgm/*.ogg`：按原版 loop 点截断，`manifest.json` 里记录 `loop` / `loopOffset`，客户端用 `AudioStreamOggVorbis.loop_offset` 接回循环。
- `sfx/*.wav`：菜单、对话、传送、撞墙、治疗、升级、捕捉等短音效，运行时用 `AudioStreamWAV.load_from_file` 直接读取，不依赖 Godot 导入缓存。
- 地点 → BGM 由 ROM 的 32×32 zone matrix 决定（秋季槽），室内地图由各自 zone 决定；切换地点/进屋时客户端自动换曲，战斗切到野生/训练家曲，结束后恢复地图曲。
- 音量默认音乐 -7 dB、音效 -3 dB，保存在 `user://settings.cfg` 的 `audio/music`、`audio/sfx`（暂无设置界面，可手动改）。

音频文件属于版权素材，只保留在本机 `client/assets/bw/` 下，不要提交或分发。

## 启动与加载

`client/scenes/Boot.tscn` 是入口。引擎启动阶段显示深蓝底色；autoload `Loading` 在第一帧用 `client/boot_splash.png`（由 `tools/build_boot_splash.py` 生成）作为加载页背景，叠加旋转精灵球、状态文字和进度条。桌面直接挂载 `res://game.pck`；Android 上该 PCK 在 APK 里是 deflate 压缩条目，随机读取很慢，所以首次启动按 1 MB 分块复制到 `user://game.pck`，加载页显示百分比；复制完成后再挂载缓存，之后启动直接秒挂。复制使用 `.tmp` 临时文件并在完成后改名，进程中途被杀不会留下半截缓存。`Main` 构建 3D 世界和 HUD 的步骤之间会主动让出帧，让加载页继续转动，构建完成后淡出。

---

## 多语言

- 客户端 UI 文案在 `client/i18n/<locale>.json` 中维护，生成 Godot 使用的 PO：`python tools/build_i18n.py`。
- 运行时由 `Loc` autoload 加载 `client/i18n/*.po`，无需在编辑器中手动导入；当前发布 `en` / `zh_CN`，代码保留 `zh_TW`、`ja`、`ko` 供后续扩展。
- 客户端会在 `register` / `login` / `resume` 消息中附带 `locale`，运行中切换语言会发送 `set_locale`。
- 字体文件：`client/assets/fonts/NotoSansSC-Regular.ttf`（SIL OFL 1.1，许可证见同目录 `OFL.txt`）。新增 `ja`/`ko` 等语言前需要确认字体覆盖；当前 Noto Sans SC 不含韩文谚文。
- 内容名称由 `tools/fetch_pokeapi_zh.mjs` 生成：物种和招式从 PokeAPI GraphQL 的 `zh-hans` 名称批量获取，道具使用 PokeAPI REST，地图/NPC 名使用项目术语表。输出在 `server/content/i18n/zh_CN/names.json`，服务端按玩家 `locale` 输出。
- 特性名称和说明用 `cd server && npm run build:ability-i18n` 从 PokeAPI 生成到同一份 `names.json` 的 `abilities` / `abilityDescriptions`；脚本会缓存请求到 `.tools/ability-i18n-cache.json`。
- NPC/剧情台词由 `tools/rom/build_dialogue_zh.py` 从 PokeMMO 社区中文语言包生成，输出在 `server/content/i18n/zh_CN/dialogue.json`。语言包的剧情文本保留了 ROM 文本表编号（`table_id`/`block_id`/`entry_id`），因此可以和 `extract_dialogues.py` 抽出的英文逐段对齐。项目自写的护士/商店/剧情台词放在 `dialogue_manual.json`。
- 对白以“整段英文台词”为键而不是单行：同一段的英文可能被 `<PAGE>` 拆成多页，中文则是重排后的一整段，翻译值可以有不同的页数。
- 当前已完成：UI 固定文案、类型/性格/状态/季节/时间标签、649 个物种名、559 个招式名、8 个道具名、地图名、NPC 名、冒险日志句子模板，以及全部已放置的 NPC/剧情台词（语言包生成 928 条，项目自写 43 条）。语言包对少数被 PokeMMO 改编过的文本表无法逐句对齐，生成器会跳过而不是猜测。待完成：剩余 ROM 对白、道具描述，以及服务端 notice/error 的本地化。


---

## 当前可玩的闭环

1. 注册账号 → 三选一初始伙伴 → 创建角色 → 出生在从 ROM 拼装的 Nuvema Town
2. 另一个玩家加入 → 同屏可见 → 四方向走路/跑步动画同步
3. 服务器权威碰撞：房屋、边界和 NPC 都会阻挡
4. 全局聊天 → 头顶气泡
5. 走到出生点南侧使用 Nurse Joy / Mart Clerk / PC；玩家家、研究所和诺文镇已接入序章 NPC，研究所里另有测试用的招式教学/回忆、连接交换、羁绊专家和测试 PC
6. 出生点往南走到服务角：Nurse Joy 回满全队 HP、清除中毒/麻痹等异常状态并恢复全部 PP
7. 在 Mart Clerk 处用战斗赢来的金币买 Poké Ball、Great Ball、Ultra Ball 和药水；背包里可以直接对队伍成员使用药水，卖出道具返还半价
8. 在 PC 终端存取宝可梦：队伍至少保留 1 只，存储上限 30 只，存入/取出/交换都保留当前 HP 与异常状态
9. 从诺文镇沿道路一直向北，跨过格子边界时没有黑屏/传送，进入 Route 1，并可以继续探索整个 Unova 室外世界
10. 踏入任意区域配置了遇敌的草丛 → 服务器判定遇敌并下发 `battle_start`
11. 战斗指令发到服务器 → 服务器结算回合、属性克制、换宠、球种捕捉与药水 → 客户端只负责表现
12. 战斗胜利获得金币与经验，升级会提升属性并学习新招式；四招已满时会弹出替换/放弃界面，达到进化等级的物种会直接进化并更新队伍卡
13. 遇到野生宝可梦会登记图鉴 Seen，捕捉、初始伙伴和进化会登记 Caught；HUD 的 Dex 页可按全部/已见/已捕筛选并查看属性与进化条件
14. 每招剩余 PP 在战斗回合后写回角色存档，重连后继续保留；Nurse Joy 回满 HP 时也会回满 PP。战斗失败会黑屏并回到 Nuvema Town；客户端断线可用 token 恢复当前位置

> 服务角在同一屏内：从出生点向下走 7 格，Nurse Joy 在 `(783,760)`、Mart Clerk 在 `(785,760)`、PC 终端在 `(783,761)`。站在 `(784,760)` 就能同时对话/使用三者。

### 当前遇敌表（从 ROM 提取）

| 区域 | 草丛 | 宝可梦 |
|---|---|---|
| Nuvema Town / 城镇 | 无/少量 | 对应 zone 无遇敌表时不触发 |
| Route 1 及其他野外 zone | 有 | 读取各 zone 自己的 `a/1/2/6` 表；已导入全量 649 只物种 |

完整室外世界生成了 **71 个遇敌 zone**，每个区域读取自己 zone header 的 `a/1/2/6` 表。Route 1 仍是 zone 317 的第 77 号表（Patrat/Lillipup Lv2–4，各 50%）。遇敌概率目前是 10%/步，配置在 `unova_full.json` 的 `encounterZones` 中。

战斗由服务器结算，规则内核使用 **Pokémon Showdown** 的 Gen 5 模拟器（`@pkmn/sim`，MIT 许可）。速度/先制、命中、伤害、特殊/物理拆分、属性克制、STAB、暴击、能力等级、异常状态、特性和道具效果都由 Showdown 计算；我们的服务器继续负责遇敌、逃跑、捕捉概率、经验、升级、金币、存档和权威校验。捕捉使用 Gen 5 风格公式：HP 比例 × 原始捕获率 × 球加成 × 异常状态加成，再做 3 次摇球判定；客户端有投球、球落地、1–3 次摇晃和破球/捕获表现；成功捕获会直接退出战斗并弹出新宝可梦的详情卡片，不再显示战斗结算确认框。会心捕捉和暗草/捕获之力修正尚未接入。客户端只发送 `battle_action` 并显示服务器同步过来的战斗快照。详细结构见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#battle)。

### 物种数据（从 ROM 提取）

- `a/0/1/6` 的个人数据提供真实种族值、属性和捕获率（649 个图鉴编号）
- `a/0/1/8` 提供完整等级学习表（招式 ID + 等级）
- `a/0/2/1` + `a/0/0/2[203]` 提供 559 个招式的类型、分类、威力、命中、PP、优先度和英文名
- `a/0/0/2[70]` 提供物种英文名
- 全量数据保存在 [species_all.json](server/content/rom/species_all.json) 和 [moves.json](server/content/rom/moves.json)
- [build-game-content.ts](server/scripts/build-game-content.ts) 用 Showdown Gen 5 做 ID/名称映射并读取进化图；种族值、招式数值和学习表仍来自 ROM
- `game.json` 现在是 649 只物种 + 559 个招式；每只的升级学习表按 Showdown 可用招式过滤并去重，并带 `evolutions` 数组（共 320 条关系，含等级、道具、亲密度、交换、招式/地点条件）
- Lv5 时 Snivy 有 Tackle + Leer，Tepig 有 Tackle + Tail Whip，Oshawott 有 Tackle + Tail Whip；Lv7 学会各自的 STAB 招式，Lv17 进化为 Servine/Pignite/Dewott
- 当前只导入**基础形态**的图鉴编号；地区形态、Mega/其他战斗形态、蛋招式、TM/教学招式尚未导入
- 种族值中的 SpA/SpD 由 Showdown 用于特殊招式；`baseXp` 仍是原型奖励缩放
- 战斗招式按钮显示当前/最大 PP，0 PP 的招式会被禁用；队伍详情显示每招剩余 PP 并支持二次确认遗忘。能力等级和异常状态图标仍未显示，但这些状态已经在服务器端生效

```bash
python tools/rom/extract_all_species.py
python tools/rom/extract_moves.py
cd server && npm run build-content
```

---

## 截图

### Route 1 春季场景与战斗动画

| Route 1（风摆 + 季节植被） | Nuvema 3D 视角 | 战斗动画立绘 |
|---|---|---|
| ![Route 1 春季](docs/screenshots/route1-spring.png) | ![Nuvema 3D](docs/screenshots/nuvema-3d.png) | ![战斗动画](docs/screenshots/battle-animated.png) |

走路 / 跑步循环的连续截图检查：

| 走路（500ms/格，4fps） | 跑步（250ms/格，8fps） |
|---|---|
| ![走路循环](docs/screenshots/walk-cycle.png) | ![跑步循环](docs/screenshots/run-cycle.png) |

### Nuvema Town 在线主世界（从 ROM 拼装）

| 单人进入诺文镇 | 双人同屏 |
|---|---|
| ![Nuvema Town](docs/screenshots/nuvema-online.png) | ![Nuvema Town 双人](docs/screenshots/nuvema-multiplayer.png) |

| 剧情 NPC 对话（当前已移除） |
|---|
| ![Nuvema 对话](docs/screenshots/nuvema-dialogue.png) |

### 早期 2D 占位地图阶段（仍用于战斗回归测试）

| 登录 | 创建训练家 |
|---|---|
| ![登录界面](docs/screenshots/login.png) | ![创建训练家](docs/screenshots/create-character.png) |

| 双人同屏 + 全局聊天 | 服务器结算的野生战斗 |
|---|---|
| ![双人同屏](docs/screenshots/world.png) | ![战斗](docs/screenshots/battle.png) |

| Whispering Grove | NPC 对话 + 治疗 |
|---|---|
| ![Whispering Grove](docs/screenshots/grove.png) | ![NPC 对话](docs/screenshots/dialogue.png) |

| 触摸控制布局 | 断线重连 |
|---|---|
| ![触摸控制](docs/screenshots/touch.png) | ![断线重连](docs/screenshots/reconnect.png) |

---

## 架构

```
Godot 4 client (GDScript)
  ├─ NuvemaOnlineView (3D, ROM GLB + AnimatedSprite3D actors)
  ├─ WorldView (legacy 2D placeholder maps)
  │  WebSocket + JSON
  ▼
Node.js + TypeScript server (authoritative)
  ├─ auth / sessions / tokens
  ├─ world (maps, collision, portals, encounters)
  ├─ battle engine (party, switching, catching, XP)
  └─ JSON store (atomic debounced writes)

server/content/*.json
  ├─ game.json (startingMap, moves, species, starters, items, shops, balance)
  └─ maps/*.json (Nuvema, Route 1 south/north, legacy 2D maps)
```

关键原则：

- **服务器权威**：位置、碰撞、遇敌、战斗结算、奖励、HP 都在服务端决定；客户端只发送意图。
- **兴趣管理**：地图瓦片只发送玩家周围的 65×65 窗口；同屏玩家和移动广播限制在半径 64 格内。
- **客户端预测 + 服务器校正**：移动立即本地表现，`move_ack` 用服务器位置纠正。
- **同一份地图数据两种表现**：服务器用 32×32 网格做碰撞，Nuvema / Route 1 客户端把网格叠加到 ROM 的 3D 地形上；2D 旧地图仍用 ASCII 瓦片渲染。
- **存档版本化**：当前是单文件 JSON；数据层已封装，后续可替换成 PostgreSQL。
- **内容驱动**：地图、NPC、招式、宝可梦、遇敌表都在 `server/content` 中，服务端启动时校验。
- **素材本地化**：ROM 提取产物只存在本机 `client/assets/bw/`，不进入仓库、不随构建分发。

更多细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，消息格式见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。

---

## 测试

```bash
cd server
npm run typecheck
npm run validate-content
npm test        # node:test 单元测试
```

### 一键地图审计（不启动游戏）

```bash
python tools/rom/audit_maps.py
# 或双击仓库根目录的 audit-maps.cmd
# 或 cd server && npm run audit:maps
```

报告写到 `.tools/map-audit/report.md`，高度断点全量列表在 `.tools/map-audit/height-pairs.csv`，覆盖：

- 直接重读 ROM 室外 chunk，核对 109 个格子的 914 个道具与道具包解析（能抓“整批建筑丢失”这类问题）；
- 386 张地图的结构、出生点、1353 个传送门的目标地图/目标格；
- 室内地图是否混入无服务功能的剧情 NPC、NPC 是否堵住传送门；
- 相邻可行走格的 **>24 单位高度断点**（“看起来能走却走不动”的那类 bug，按是否靠近传送门优先列出）；
- 983 个 GLB 的贴图缺失、光效/发光材质是否仍用普通 alpha（例如矢车森林入口的白线 `d2_hika02`）、带 alpha 贴图却被当成不透明的材质。

它抓的是**确定性的还原问题**；建筑比例、构图和美术观感仍然需要预览或跑图确认。高度断点里有很多是原版就有的单向台阶，报告会把靠近传送门的排在前面。

端到端冒烟测试（需要第二个终端启动服务器，并强制遇敌）：

```bash
# 终端 1
cd server
PORT=3567 DATA_DIR="F:/AgentProject/BWMMO/.tools/smoke-data" ENCOUNTER_RATE=1 DEBUG_SKIP_STORY=1 npm start

# 终端 2
cd server
SMOKE_URL=ws://127.0.0.1:3567 npm run smoke
```

冒烟测试覆盖：注册/角色创建、初始图鉴登记与 649 条目录下发、出生在无缝 Unova、`map_state` 只携带 65×65 瓦片窗口、双人可见、移动/跑步/原地转向广播、接近窗口边界后收到 `map_window`、聊天、Nurse Joy 治疗并清除异常、非法 PC 存入被拒绝、在 Mart 买卖药水并校验金钱、进入诺文镇博士研究所、跨越诺文镇/Route 1 接缝且不触发地图切换、草丛遇敌（只生成 Patrat/Lillipup Lv2–4）并登记 Seen、服务器结算至少一个战斗回合、战斗消耗 PP 并写回存档、token 重连后恢复世界位置/图鉴/剩余 PP、战斗后用 Potion 回复受伤的初始伙伴。这条历史链路假设角色已经过完序章，所以测试服务器要加 `DEBUG_SKIP_STORY=1`；正常游玩不要设置它。

序章另有一条专用冒烟测试（新账号从头走完整段剧情，包括闸门挡路和解锁）：

```bash
# 终端 1
cd server
PORT=3599 DATA_DIR="F:/AgentProject/BWMMO/.tools/story-smoke-data" npm start

# 终端 2
cd server
npm run smoke:story   # 默认连 ws://127.0.0.1:3599
```

覆盖：新账号无角色 → 不带 starter 创建 → 卧室旁白与 `story_choice` → 选 Tepig 后队伍/图鉴/flag 落盘 → Cheren/Bianca 从房间消失 → 下楼找妈妈（治疗 + flag）→ 北出口被 Cheren 的闸门话术挡住（`reason:"story_gate"`）→ 进研究所自动播放图鉴场景 → 同一格道路放行 → 断线重连不重播序章。逐步的验收清单见 [docs/STORY_TESTING.md](docs/STORY_TESTING.md)。

好友链路另有独立冒烟测试（两个账号、两个 WebSocket 客户端，覆盖申请/同意/私聊/删除/拒绝/取消/离线申请/断线重连）：

```bash
# 终端 2（服务器仍用上面的测试端口）
cd server
SMOKE_URL=ws://127.0.0.1:3567 npm run smoke:social
```

好友切磋另有双账号冒烟测试，覆盖好友限制、拒绝/取消邀请、禁止球/药/逃跑、双方选招、结算、赛后回血和位置保持：

```bash
SMOKE_URL=ws://127.0.0.1:3567 npm run smoke:duel
```

养成操作另有独立冒烟测试，覆盖测试 NPC 发放 TM/进化石/测试宝可梦、教学与回忆、TM 使用、道具进化、交换进化、亲密度、改名、存入和放生：

```bash
# 终端 1（强制遇敌关闭，避免走去研究所的路上被打断）
cd server
PORT=3568 DATA_DIR="F:/AgentProject/BWMMO/.tools/growth-smoke-data" ENCOUNTER_RATE=0 DEBUG_SKIP_STORY=1 npm start

# 终端 2
cd server
SMOKE_URL=ws://127.0.0.1:3568 npm run smoke:growth
```

测试 NPC 位于博士研究所（`unova_in_396` 的 8–14, 9 一带）：招式教学家、招式回忆家、连接交换台、羁绊专家、研究所补给台和测试 PC。第一次和补给台说话会播放一段剧情并发放测试物资与三只宝可梦；之后再说话就变成普通商店。

客户端离屏资源检查（无需窗口）：

```bash
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_rom_assets.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_battle_animation.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_battle_effects.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_battle_effect_integration.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_battle_layout.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_shop_layout.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_pc_layout.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_world_time.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_turn_logic.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_visual_runtime.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_indoor_props.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_grass_lift.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_city_and_forest.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_npc_sprites.gd
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client --script res://tests/check_battle_names.gd
```

好友面板、私聊记录、HUD 布局和世界地图用场景式测试（`--script` 模式不会实例化 `Loc` 自动加载，所以这里走 `--path client <scene>`）：

```bash
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/SocialUITest.tscn
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/HudLayoutTest.tscn
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/WorldMapTest.tscn
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/GrowthUITest.tscn
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/StarterChoiceTest.tscn
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/StarterWiringTest.tscn
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/TouchControlsTest.tscn
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/AudioTest.tscn
.tools/Godot_v4.4.1-stable_win64.exe --headless --path client res://tests/PckAudioTest.tscn
```

`TouchControlsTest.tscn` 检查左侧 D-pad、右侧 ABXY 菱形布局、方向信号、A/B/X/Y 信号、B 按住跑步状态、聊天栏在触摸时移到右上角，以及对话模式只保留 A/B；`AudioTest.tscn` 检查 `manifest.json` 的地图/室内 → BGM 映射、loop 偏移、音频文件存在和 OGG/WAV 能加载（没有渲染音频时跳过）；`PckAudioTest.tscn` 挂载 `client/game.pck`，验证 Android 实际读取的 pck 内音频路径（需要先重新生成 PCK）。

`check_battle_animation.gd` 验证前后立绘帧表和帧推进；`check_battle_effects.gd` 读取原版 manifest，验证 Pound 的粒子贴图和脚本播放，并检查无素材时的属性回退；`check_battle_effect_integration.gd` 用结构化 `events` 驱动战斗 UI，验证动画期间菜单锁定、伤害事件同步更新 HP、特效结束后恢复操作，以及胜利界面等待招式动画播完；`check_battle_layout.gd` 用假战斗数据检查战斗 HUD 的字体、指令/招式/背包菜单、招式 PP 标签、球种按钮、药品目标菜单、HP 条和消息框布局；`check_hud_layout.gd` 检查背包分页、药品详情、“USE ON”按钮、图鉴筛选/分页/详情以及满四招学习弹窗；`check_world_map.gd` 验证 `Map` 入口打开区域图、`World` 入口打开合众世界地图、40 个地点标记和当前区域高亮会随 `location` 更新；`check_shop_layout.gd` 检查商店买卖分页、金钱显示和购买请求；`check_pc_layout.gd` 检查队伍/盒子列表以及 STORE/TAKE/SWAP 请求；`GrowthUITest.tscn` 验证教学/回忆面板的招式列表与发送、连接交换面板的 `tradeable` 状态、特性专家面板的切换请求与战斗特性顶部提示，以及 PC 改名/放生弹窗的请求内容；`check_world_time.gd` 验证时钟格式化、昼夜相位、夜间变暗和室内亮度；`check_turn_logic.gd` 验证首次按方向只转向、同方向再按才迈步；`check_visual_runtime.gd` 在 headless 下构建 Route 1 chunk，检查树/花材质 override、昼夜天空/环境光、天空环境和角色 sprite 的 alpha scissor 深度写入；`check_indoor_props.gd` 构建诺文镇 Pokémon Center，断言 `pc_01`/`searock`/`c04_football` 不会作为室内 props 生成，同时保留洞穴里的 `searock`；`check_grass_lift.gd` 用合成的草丛卡片验证角色站到卡片表面、无草格保持地形高度、房间已采样的高度不会重复抬升，并且抬升不影响坡度判定；`check_city_and_forest.gd` 验证七宝市街区按城市道具包加载房屋/博物馆/咖啡馆，构建矢车森林独立地图检查室外相机和道路/木栈道材质，并检查区域图镜像 viewport、角色镜像和放大相机；`check_npc_sprites.gd` 验证玩家 0-3 仍用四个共享角色，NPC 的 `sprite` 通过 `assets/bw/overworld/npc_<id>` 加载原版行走图，并断言每个方向动画都有 32×32 贴图（未提取素材时跳过）；`check_battle_names.gd` 断言训练家战把对手叫 `Foe X`、切磋叫 `X's Y`、只有野生战才用 `Wild X`。`StarterChoiceTest.tscn` 验证礼物盒三球布局、选球后立绘/名字/属性出现、确认只发送一次以及中英文切换；`StarterWiringTest.tscn` 验证 `kind:"starter"` 会打开礼物盒场景，而普通 `story_choice` 仍使用原选择卡片。以上都不打开窗口。

客户端静态检查（可选）：

```bash
pip install gdtoolkit
python -m gdtoolkit.linter client/scripts/*.gd
```

---

## 当前限制（有意为之）

- 完整室外 Unova 已拼接为 109 个格子/928×864 网格；地图瓦片按 65×65 窗口下发（约 4 KB），但 `map_window` 仍是整窗重发而不是差分。AOI 已改为 32 格网格索引（`server/src/game/aoi.ts`），每次移动只查询新旧位置附近的桶，不再线性扫描全部玩家
- 玩家广播半径固定为 64 格（`AOI_RADIUS`）；视野外的玩家不会互相收到移动消息，也还没有分线/channel
- 387 个室内场景中 374 个已生成地图（13 个 permission grid 无可站立地面而跳过）；从室外出生点出发可到达 169 张，129 个室外门（门前共 197 个触发格）已连通。少数门/电梯/剧情传送因为目标场景特殊或坐标被阻挡而暂时跳过
- 室内 NPC 对话已从 `a/0/5/7` 脚本和 `a/0/0/3` 文本解码；当前约 47% 的室内 NPC 实体有可用 profile，其余是特殊/全局脚本、无文本 NPC 或遇到未解码命令，仍回退到通用对话
- 剧情层只做到诺文镇序章：场景/触发器/闸门/选择御三家的引擎已接入，其他城镇和道路还没有剧本。Bianca 的首次对战被替换成过场对白，训练家对战引擎（`a/0/5/7` 的高号命令、训练家事件）仍未接入；序章之外的 ROM flag 仍只由 NPC 对话脚本的 SetFlag 写入
- 室外和室内碰撞与地面高度都来自 permission grid（`a/0/0/8`）的 8 字节条目：高 16 位决定可走性，低 16 位的 shape/slope/offset 决定该格的地形平面；服务器移动时再做逐格上下坡判定（向上 24 单位上限、向下 128 单位上限），客户端预测使用同一规则。这比生成时永久封边更接近原版“跳下矮台、不能爬墙”，建筑/道具 footprint 和跨格接缝仍需视觉抽查
- 战斗待机动画使用 Showdown Gen 5 GIF 转帧表，不是直接解析 ROM 的 NCER/NANR；闪光、替身和全部形态动画尚未覆盖
- 招式特效的**选择、时序、目标侧、投射物路径和精灵抖动**来自 ROM 的 559 份动画脚本与 `a/0/0/6` 粒子贴图，但原版粒子是 3D billboard + APS 发射器；当前客户端用 2D 贴图近似，尚未解析 APS 粒子图（多个发射器共享一张贴图时按序号循环映射），也还没有接入招式音效和招式背景（`LoadBackground`）。部分 `CheckMoveUser` 分支和 3D 旋转参数被忽略
- Route 1 原版的季节性飞舞落叶尚未复刻；客户端此前自制的 MultiMesh 叶片实现因生成位置跟随角色而出现“人走到哪生成到哪”的 bug，已删除脚本、贴图和测试。树/花材质修正、风摆和天空背景已接入；远景雾曾因相机距离过远产生白膜，现已关闭。已带窗口复核诺文镇、Route 1、研究所和玩家家；其他城市/洞穴仍需逐区域抽查
- 人物仍是原版 32×32 2D billboard，不是 3D 骨骼/模型；3D 层次来自逐格地形高度、烘焙明暗、线性贴图过滤和相机角度。高草丛的 ROM 叠层卡片比地面高 2–10 单位，客户端在 chunk 载入时把每格卡片高度栅格化进 `chunk_grass_lift`，角色站到卡片表面而不是地形上，否则自身格子的草叶会遮住下半身。走路 4 帧/4fps（500ms/格），跑步 4 帧/8fps（250ms/格），一个步态循环含两次落脚、跨两格，连续移动有 80ms idle 缓冲避免每步闪回站姿
- 地形/建筑/植被使用 ROM 烘焙顶点色和线性 mipmap，不投射实时方向光阴影；角色使用 blob shadow。这是为了贴近原版 BW 的烘焙光照，不追求 PBR/全局光照/SSAO
- 室内使用更近、更高的相机预设；小房间会自动取可走区域中心，再向玩家偏移 35%，并隐藏室内 chunk 携带的 `buill_*`/`thouse_*` 建筑外壳 props，以及 Pokémon Center 房间里的 `pc_01` 建筑外壳、`c04_football` 测试场地和 `searock` 镇外岩石。部分房间仍有黑边和墙体遮挡，需要逐场景微调
- NPC 名字标签按距离淡出，玩家自己的头顶名字隐藏；聊天栏 12 秒无活动会自动折叠成一条窄栏，点击 `+` 或按 T 可重新展开
- 目前已启用 FXAA；GL Compatibility 下测试 MSAA 会导致曝光/阴影异常，所以 MSAA 保持关闭，后续如果要更强抗锯齿需要评估 Forward+/Mobile 渲染器
- 旧 2D 地图仍在，用于战斗、遇敌和传送的回归测试，不在默认出生流程内
- 其他 2D 地图仍使用 BW 训练家战斗立绘缩放成头像；完整 Unova 室外使用原版 32×32 场景小人
- 全量内容目前只覆盖基础形态的图鉴编号；地区形态、Mega/其他战斗形态、蛋招式、TM/教学招式尚未导入
- 进化图已导入 320 条关系；等级、升级时已掌握招式、道具（进化石）、亲密度（≥220）和交换（含所需携带物）已接入。特殊地点/时段和需要持有物的 `levelExtra`/`levelHold` 还没有获取持有物或判断时段/地点的完整入口，暂时不会触发；道具、亲密度和交换进化目前也只在测试 NPC 处验证
- TM 采用 Gen 5 的可重复使用行为；教学家和回忆家已接入，但教学家可教招式来自 NPC 的 `moveList`（当前是测试列表），还没有全量 TM/教学招式内容
- 道具经济是原型规模：诺文镇商店卖 8 种基础道具，研究所测试补给台卖 14 种测试用 TM/进化石，携带上限 99；没有徽章/剧情门槛、完整的持有物系统、训练家对战、双打、非好友 PvP、真实交易或市场
- PC 已支持存入/取出/交换/改名/放生；没有多盒子分类、排序和批量整理
- 战斗内使用药品会固定消耗一个回合；没有战斗内换人时的药品提示、批量购买确认或撤销购买
- 没有完整的 BW 剧情、任务/事件脚本；季节目前是客户端 `--season=` 选择 + `r01` 模型替换/小花重映射，还没有全局季节状态、ROM 季节事件或服务器日期同步
- 没有分线/分片；AOI 是单进程内的网格索引 + 距离过滤，当前按“小规模世界”设计
- 没有生产级反作弊、审计、限流集群；`game-server.ts` 已拆成组合根和各领域控制器，但仍是单进程内存状态
- 存档是 JSON 文件，不是 PostgreSQL
- Android 导出预设未提交（需要本机 Android SDK + 导出模板；在导出设置里添加 INTERNET 权限）
- 中文 UI 字体、物种/招式/道具/地图/NPC 名称和 NPC/剧情台词已接入；道具描述和服务器提示仍未翻译。冒险日志由客户端按 `locale` 渲染，服务端 notice/error 仍是英文源

## 下一步路线

> P0 全量内容已完成：649 个图鉴编号、559 个招式、完整升级学习表、320 条进化关系、71 个遇敌 zone、649 组前后立绘。

1. **室内覆盖补全**：处理剩余 13 个空碰撞场景、被阻挡/剧情用的门，并逐个抽查洞穴、电梯和大型建筑
2. **AOI 与分线**：网格 AOI 已完成；接下来把 `map_window` 改成差分更新，并加入地图分线（channels）和更多相邻格的预加载圈
3. **剧情与事件**：NPC 对话已解码；继续补齐 `a/0/5/7` 的高号命令、剧情 trigger/flag 初始化、训练家遭遇和剧情传送
4. **室内体验**：按房间调整镜头距离，逐个检查门口朝向、传送落点和大型洞穴的镜头遮挡
5. **继续拼装更多 ROM 场景**：把室内/室外构建器扩展成通用 zone 管线，并补齐洞穴、桥梁和特殊地形
6. **养成扩展**：道具/亲密度/交换进化、TM/教学/回忆、改名与放生已接入；剩下完整的持有物系统、特殊地点/时段进化、PP 恢复道具和全量 TM/教学招式内容
7. **战斗扩展**：持有物、能力等级与异常状态图标、训练家对战、双打、更聪明的 AI
8. **商店与 PC 扩展**：更多城镇商店、徽章门槛、道具分类/多盒子、批量整理
9. **MMO 层**：分线、交易、PvP、市场、好友申请/黑名单、公会（基础好友与私聊已完成）
9. **生产化**：PostgreSQL + Redis、战斗回放/审计、反作弊、可观测性

## 版权说明

本项目用于局域网内部的个人学习与原型验证。战斗规则使用 MIT 许可的 [Pokémon Showdown](https://github.com/smogon/pokemon-showdown) `@pkmn/sim`；宝可梦数据与 IP 权利仍属于原权利人。项目不会对外发布，`PokeMMO-Client.apk`、NDS ROM 和从 ROM 解码的剧情文本仅在本机使用。
