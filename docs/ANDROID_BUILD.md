# Android 打包

当前可安装包：`client/build/bwmmo-debug.apk`（约 183 MB，arm64-v8a，debug 签名，minSdk 21 / targetSdk 34，包名 `com.bwmmo.client`）。

## 为什么需要 game.pck

Godot 4.4.1 的 Android 导出会把项目资源逐个放进 APK。本项目有约 7.9 万个资源条目，超过 ZIP 的 65,535 条上限，apksigner 会报：

```text
Unused space at the end of ZIP Central Directory
```

这是 Godot 的已知问题（[godotengine/godot#106857](https://github.com/godotengine/godot/issues/106857)）。本项目的处理方式：

- APK 只保留脚本、场景、i18n 等少量文件；
- `assets/**` 和 `.godot/imported/**` 打进 `client/game.pck`；
- `client/scenes/Boot.tscn` 在加载 `Main.tscn` 前挂载 `game.pck`。APK 里的 `assets/game.pck` 是 **deflate 压缩** 的 ZIP 条目（247 MB → 约 156 MB），从压缩条目里随机读资源会非常慢，所以 Android 上 Boot **总是**先把 PCK 以 1 MB 分块复制到 `user://game.pck`，再挂载缓存；桌面则直接挂载 `res://game.pck`；
- 首次复制在 `Loading` autoload 的加载页上显示百分比；复制写入 `user://game.pck.tmp`，尺寸校验通过后才改名，进程被杀不会留下坏缓存。之后启动只要 `user://` 缓存尺寸与 APK 内 PCK 一致就直接挂载；
- 项目级字体在引擎启动时就加载，所以 `project.godot` 不再设置 `gui/theme/custom_font`，改由 Boot 在挂载后设置 `ThemeDB.fallback_font`，并调用 `UI.reset_font_cache()`；
- 引擎启动阶段显示 `boot_splash/bg_color` 深蓝底色；`Loading` autoload 在第一帧用 `client/boot_splash.png`（`tools/build_boot_splash.py` 生成）作为加载页背景，叠加旋转精灵球、状态文字和进度条，覆盖 PCK 复制和 Main 构建阶段。

`client/tools/build_assets_pck.gd` 会跳过原始 GLB/NSBMD/NSBTX/TTF（运行时用对应的 `.scn`/`.ctex`/`.fontdata`），但保留原始 PNG 和音频（OGG/WAV 由客户端用 `load_from_file` 直接读取），因为角色帧有 `Image.load_from_file()` 的兜底路径。

**修改资源后必须重新生成 `game.pck`**，否则 APK 里仍是旧资源。`client/game.pck` 约 247 MB，已加入 `.gitignore`。当前 PCK 已包含 58 首 BGM + 19 个音效（音频约 88 MB）。

## 前置条件

- Godot 4.4.1（`.tools/Godot_v4.4.1-stable_win64_console.exe`）
- 4.4.1 Android 导出模板（`%APPDATA%\Godot\export_templates\4.4.1.stable`）
- JDK 17（`F:\Program Files\Java\jdk-17.0.7`）；在 `Editor Settings → Export → Android → Java SDK Path` 指向它
- Android SDK（`F:\Android\android-sdk`）：build-tools 34.0.0、platforms/android-34、platform-tools
- 调试 keystore：`%APPDATA%\Godot\keystores\debug.keystore`（storepass/keypass `android`，alias `androiddebugkey`）
- `client/project.godot` 已开启 `rendering/textures/vram_compression/import_etc2_astc=true`

## 构建步骤

0. 生成音频（首次或想要更新 BGM 时）：

```bash
python tools/rom/extract_bw_audio.py
```

输出到 `client/assets/bw/audio/`（gitignored），包含 `manifest.json`、`bgm/*.ogg`、`sfx/*.wav`。需要本机 ROM、`ndspy` 和 PATH 上的 `ffmpeg`；完整渲染约 30 分钟，之后会跳过已存在的文件。

1. 生成资源包（资源有变动时）：

```bash
./.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client \
  --script res://tools/build_assets_pck.gd
```

输出 `client/game.pck`。

2. 导出 APK：

```bash
./.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client \
  --export-debug "Android" "F:/AgentProject/BWMMO/client/build/bwmmo-debug.apk"
```

3. 校验：

```bash
/f/Android/android-sdk/build-tools/34.0.0/apksigner.bat verify --print-certs \
  client/build/bwmmo-debug.apk
/f/Android/android-sdk/build-tools/34.0.0/aapt.exe dump badging \
  client/build/bwmmo-debug.apk | grep -E "package|sdkVersion|INTERNET|native-code"
```

4. 安装到手机（打开 USB 调试）：

```bash
/f/Android/android-sdk/platform-tools/adb.exe install -r client/build/bwmmo-debug.apk
```

## 导出预设要点

`client/export_presets.cfg`：

- `package/unique_name="com.bwmmo.client"`
- `architectures/arm64-v8a=true`
- `permissions/internet=true`
- `export_filter="all_resources"`
- `include_filter="game.pck"`（PCK 是非资源文件，必须显式包含）
- `exclude_filter="assets/*,.godot/imported/*"`
- `gradle_build/use_gradle_build=false`（使用预编译模板，不需要 NDK/Gradle）

## 正式签名

当前 APK 用 debug keystore 签名，可直接侧载。需要 release 签名时，自己生成 keystore（不要提交密码），在预设的 `Keystore → Release` 填路径/用户/密码，或使用环境变量，然后用 `--export-release` 导出。发布到 Google Play 需要 AAB、release keystore 和 64 位支持；本项目当前只启用 arm64-v8a。

## 运行时验证记录

在 x86_64 headless 模拟器（API 35）上安装并启动验证：

- 首次启动日志为 `[boot] copying game.pck to user storage (one time)`，加载页显示百分比；第二次启动为 `[boot] mounted cached user pack`；
- 没有 `No loader found`、preload 失败、`net` 为空等脚本/资源错误；
- `[audio] N BGM, 19 SFX` 出现在日志里，说明 `game.pck` 内的音频 manifest 已挂载；
- 模拟器的 SwiftShader 会报 `Fragment shader active uniforms exceed GL_MAX_FRAGMENT_UNIFORM_VECTORS (261)`，这是软件 GL 的 uniform 上限，真机 GPU 通常不会触发；画面表现请以真机为准。

桌面可以用 `-- --mobile-copy` 强制走 Android 的 `user://` 复制分支，验证首次启动流程（会在桌面 `user://` 留下约 247 MB 的 `game.pck`，验证后可删除）：

```bash
./.tools/Godot_v4.4.1-stable_win64_console.exe --headless --path client \
  -- --capture-login --mobile-copy
```

客户端默认连接 `ws://122.51.98.40:2567`。这是明文 WebSocket，正式对外发布前建议加域名和 `wss://` 反代。
