# Sofatap

[English](README.md) · **简体中文** · [日本語](README.ja.md)

**把 iPhone 变成客厅电脑的遥控器。**

![Sofatap 使用场景：坐在沙发上，用 iPhone 操作连接客厅电视的电脑](docs/images/sofatap-living-room.png)

*AI 生成的产品场景示意图，并非应用截图。*

Sofatap 是 [chekusu](https://github.com/chekusu) 开发的开源遥控工具。把 iPhone 变成 Windows、Mac 或受支持 Linux 电脑的手势鼠标和语音／文字输入器。电脑画面留在电视上，人坐在沙发上就能操作。

[下载版本](https://github.com/chekusu/sofatap/releases) · [问题反馈](https://github.com/chekusu/sofatap/issues) · [MIT 许可](LICENSE)


**接收器自启更新：**电脑端 0.7.3 beta.1 与 Android/Google TV 0.1.2 beta.1 新增原生自启选项，首次正常打开时默认开启。电脑端在登录后启动，关闭窗口继续接收，明确选择退出才停止；电视端仍受 Android 和厂商系统限制。参见[行为和验证范围](docs/verification/receiver-autostart-2026-10-16.md)。

**接收器更新功能：**[电脑接收器 0.8.1 beta.1](https://github.com/chekusu/sofatap/releases/tag/v0.8.1-beta.1) 已提供 Windows、Mac 和 Linux 下载。Windows、Linux 加入原生检查更新与自动下载。Mac 的 Apple Silicon 和 Intel 安装包均已签名、公证，并提供已验证的签名更新源。旧接收器需先手动安装一次，后续检查与下载通过原生更新器完成。[Android/Google TV 0.2.1 beta.1](https://github.com/chekusu/sofatap/releases/tag/android-tv-v0.2.1-beta.1) 仍是当前实验性电视接收器，安装需在电视确认。旧接收器需要先手动升级一次，才能获得更新入口。参见[更新行为与限制](docs/RECEIVER-UPDATES.md)。

**开发中的电脑控制（尚未发布）：**电脑遥控新增默认输出设备的音量减、音量加和静音切换，以及可保存的 0.25–3× 指针速度。音量控制需要新版接收器与可调节的系统音频输出；电视控制保持原样。见[行为与验证范围](docs/verification/desktop-controls-2026-10-18.md)。

## 宣传视频

[![观看 Sofatap 宣传视频：用 iPhone 的手势、键盘输入和语音听写操作电视上的电脑](https://sofatap.app/media/sofatap-demo-poster-zh-cn.jpg)](https://sofatap.app/zh/#video)

一分钟短片：手势指针、手机键盘打字、语音听写，坐在沙发上就能完成。[在 sofatap.app 观看宣传视频](https://sofatap.app/zh/#video)，或下载带字幕的 MP4：[简体中文](https://sofatap.app/exports/sofatap-promo-zh-cn.mp4) · [英文](https://sofatap.app/exports/sofatap-promo-en.mp4)。

## 可以做什么

- 一个大圆角触控区域，容纳当前设备选择、独立指南、麦克风和键盘入口。背景铺满缓慢流动的点阵，触摸会使附近点阵弯曲、偏移，点击产生涟漪。触控面不放说明文字；开启「减弱动态效果」后点阵保持静止，触摸反馈简化。
- 滑动移动鼠标，任意位置单击都是左键。构建 16 在隐形左半区连续点两下发送两次左键，在右半区连续点两下发送两次右键；旧构建 15 是任意位置双击发送一次右键。静止按住 300 ms 后拖动，双指滑动滚动；触控区不增加分隔线或文字。
- 点击底部麦克风使用设备支持的本机语音识别，也可使用 iPhone 键盘／Typeless。受支持的输入框默认实时同步：键盘确认的文字、删除、选区和语音识别更新直接反映到电脑，无需点**发送**。其他输入框及旧接收端保留检查草稿后发送；不会额外追加回车或提交操作。
- 扫描**电脑原生窗口**里的二维码配对：Mac 使用 AppKit/SwiftUI，Windows 使用 WinForms，Linux 使用 GTK3，无需打开浏览器。
- 三端接收器采用已选定的**暮色薄荷**设计：深灰底色、薄荷绿操作按钮与清晰的白底二维码。当前 beta 安装包已包含该设计和新版 Sofatap 图标，参见[设计规格](docs/RECEIVER-DESIGN.md)。
- 通过家庭局域网连接，使用 WSS/TLS、证书指纹校验和本地配对凭据。电脑上的修改与当前编辑冲突或连接中断时，实时输入会暂停；结果不确定的编辑不会自动重放。

TestFlight 构建 15 已包含设备管理，并对齐官网的 12 种语言：英语、简体中文、日语、韩语、德语、法语、西班牙语、巴西葡萄牙语、俄语、阿拉伯语、印地语、印尼语。阿拉伯语采用从右到左排版，滚动条仍位于触控区物理右侧。见[语言覆盖](docs/APP-LANGUAGES.md)与[验证记录](docs/verification/device-library-2026-10-14.md)。

**当前公开测试版：**iPhone **1.0 (22)** 已通过 TestFlight 外部审核，可通过[公开邀请](https://testflight.apple.com/join/e6MuKx9S)安装，测试人数上限为 10,000 人。Windows、Mac、Linux 使用[电脑接收器 0.8.1 beta.1](https://github.com/chekusu/sofatap/releases/tag/v0.8.1-beta.1)，实验性的电视适配器使用 [Android/Google TV 接收器 0.2.1 beta.1](https://github.com/chekusu/sofatap/releases/tag/android-tv-v0.2.1-beta.1)。**电视自动重连需要手机构建 17 及以上和电视接收器 0.1.1 beta.1 配合；原生电视控制需要手机构建 20 或更高版本。**参见[构建 18 历史分发记录](docs/verification/testflight-1.0-18.md)和[电视软件验证](docs/verification/android-tv-reconnect-2026-10-16.md)。索尼 XRJ-85X95L 与小米 MiTV-MOEU0 已完成部分安装与设置检查；原生遥控服务配对和第三方应用输入仍待验收。参见[限定实测结果](docs/verification/tv-native-controls-2026-10-17.md)。正式 App Store 构建 15 的提交是独立流程。

**手机构建 22 更新：**iPhone **1.0 (22)** 改善指针发送节奏，修复接收端明确返回忙碌后普通移动无法恢复的问题，并在可用时自动使用 Mac 点对点连接，保留经过身份校验的 Wi-Fi 回退。构建 22 已通过外部审核，内部测试与公开测试现已提供同一版本，可通过上述公开邀请安装。Mac 点对点连接需配合接收器 **0.8.1 beta.1**。参见[实现与验证范围](docs/verification/pointer-transport.md)。

**重连更新：**iPhone **1.0 (16)** 与接收器 **0.7.2 beta.1** 修复电脑接收器重启后的连接恢复。手机 App 在前台时，会重试当前已保存的电脑，无需重新扫码；接收器新增无关网卡时会保留原有配对。待确认的文字和鼠标操作不会自动重放。证书更换仍需重新配对，已有的重复设备不会自动合并。参见[自动重连回归检查](docs/verification/reconnect-2026-10-15.md)；真实 iPhone 到 Windows 的关闭／重开验收仍待完成。

此前的 [0.7.0 (10) 真机到 Windows 限定验收](docs/verification/realtime-input-0.7.0.md)已通过原生 RichEdit 字段的已有文字导入、多语言／emoji／换行追加、键盘删除、全选和清空；最终构建的实时语音及其他项目仍待验收。[0.6.0 记录](docs/verification/2026-10-13-iphone-input.md)另有手势、麦克风听写和明确发送的结果。接收器打包与公证检查不等于真实输入验收。蓝牙连接和云中继尚未实现。参见[交互规格与后续独立 CUA 方向](docs/INTERACTION.md)。

双指滚动像拖动内容：向上滑查看页面下方，向下滑查看页面上方。点阵触控区内部右侧的滚动条采用滚动条方向：向下拉，页面向下滚动。薄荷色圆形发送按钮位于输入框右侧内部，独立留白避免遮住文字。清空和键盘切换采用更小的无底色图标，放在框下方左侧；键盘展开／收起时箭头向下／向上切换，带动画与触觉反馈，连接和发送状态提示放在同一行右侧。不显示字数或常驻实时输入能力提示；确认发送模式下，已发送草稿继续追加后只发送新增文字。[查看输入区预览](docs/images/device-library-20261014/zh-keyboard-open.png)。

点击左上角的设备名称打开设备管理弹窗，可保存多台电脑／电视配对、选择当前设备、本地重命名、断开或单方面移除配对；移除本机配对不会撤销其他手机的权限。右上角问号打开独立的图解使用指南。需要输入时，编辑区才出现在触控区域下方；受支持的输入框直接实时编辑，其他输入框保留草稿检查与明确发送。[查看离线模拟器界面](docs/images/device-library-20261014/en-touchpad.png)与[点阵动效预览](docs/images/sofatap-touch-effects.mp4)。这些仅展示本地渲染，不代表真实 iPhone 输入或性能已验证。

**构建 15 更新：**添加设备统一进入**扫描二维码**页面，上半部为相机，下方为支持的平台说明。扫描或粘贴电脑、Android/Google TV 的配对码，无需先选设备类型。App 自动选择连接适配器，显示二维码中提供的平台和名称，认证连接成功后再进入命名步骤。可保留建议名称或保存新名称，之后仍可在“我的设备”中本地重命名。LG webOS 仍需手动输入 IP 并在电视上授权。Android/Google TV 仍属实验性功能，尚无通过验收的电视型号或第三方电视应用。

接收器自 0.7.1 beta.1 起，电脑配对码包含 `platform` 和 `name`，手机可自动识别 Windows、Mac 或 Linux。新码要求 **iPhone 1.0 构建 15 或更新版本**，旧手机构建无法读取。构建 15 同时兼容[接收器 0.7.0 beta.1](https://github.com/chekusu/sofatap/releases/tag/v0.7.0-beta.1) 的旧格式。二维码中的标签用于识别候选设备；实际连接仍须通过证书和配对凭据校验。

**路线图：**免费提供手动鼠标／触控遥控，当前支持电脑，下一步扩展直连电视；电视的真实光标能力需要单独验证，方向键导航不等同于鼠标。基础语音转文字仍是免费输入。付费的语音目标自动化先面向 Windows、macOS、Linux 的多步任务，之后再扩展电视。本次 beta 的电视遥控仍是实验性预览；自动化与订阅尚未启用。参见[路线图与验收目标](docs/ROADMAP.md)和[自动化研究](docs/research/natural-language-pro.md)。

**电视开发预览：**源码现已加入 LG webOS 的原生 IP 配对，以及移动、单击、滚动、返回和主页适配器。已通过本地协议与 TLS 测试，尚无通过真机验收的电视型号；自动发现、电视打字与听写仍待实现。参见[详细技术方案](docs/research/tv-implementation-plan.zh-CN.md)和[验证范围](docs/verification/webos-pointer-preview.md)。

**Android/Google TV 测试版：**[接收器 0.2.1 beta.1](https://github.com/chekusu/sofatap/releases/tag/android-tv-v0.2.1-beta.1) 提供开发签名 APK。配合 iPhone 构建 17 或更高版本，App 在前台时会自动重连当前保存的电视；重启接收器和无关网卡变化会保留有效配对。原生接收器提供无障碍叠加光标，以及依赖目标控件的点击与滚动。独立的原生方向键、确认、返回和主页操作需要使用电视验证码与 Android TV Remote Service 配对。可选的打字和听写需要用户启用并选中 Sofatap 输入法，且目标应用提供普通 Android 输入框；拖动和右键仍未支持。**索尼 XRJ-85X95L 与小米 MiTV-MOEU0 已完成部分安装与设置检查。小米的同签名更新保留了配对和无障碍授权，并已确认启用、选中 Sofatap 输入法。两台电视的原生遥控配对，以及 YouTube、Netflix 和浏览器的实际输入仍待验收。**参见[安装指南](android/README.md)、[限定实测结果](docs/verification/tv-native-controls-2026-10-17.md)与[待完成的硬件验收](docs/ACCEPTANCE.md)。

兼容接收端识别到提供辅助功能元数据的新可编辑输入框时，手机会自动弹出键盘。后台检测不读取框内内容；随后打开实时编辑会话时，会把受支持字段的完整文字和选区传到配对手机，因此退格、全选后删除也能修改电脑上的已有文字。焦点检测与实时编辑的支持范围不同：Windows 实时编辑当前限原生 Edit/RichEdit 控件；Mac 要求辅助功能提供可写的选中文字及选区。缺少相应能力的浏览器、自绘控件、Linux 及旧接收端采用检查草稿后发送。密码和只读字段不能开启实时编辑。参见[焦点检测、数据处理及平台限制](docs/TEXT-FOCUS.md)。

**Windows 锁屏 PIN 控制（验证中）：** 目标是用 iPhone 触控板操作锁屏并手动输入 PIN，再提供可选的 Face ID 授权自动输入已保存 PIN。Sofatap 不要求 Microsoft 账户密码。此前的账户密码实验已停用，普通接收器和 iPhone UI 不再提供入口。鼠标探测、原生 PIN 接受和手机联合实测分别验收，扫码配对或编译成功不代表已支持。参见[范围与验证](docs/FACE-ID-UNLOCK.md)。

构建 16 中，草稿模式的键盘退格先删除手机上未发送的文字；清空本地草稿后，键盘退格可删除电脑当前输入框中的文字。独立的“电脑退格”图标作用于电脑当前输入位置，不删除手机草稿。实时编辑继续正常同步删除。这些更新已通过[真 iPhone 到记录型接收器的检查](docs/verification/input-1.0-16.md)，不代表 Windows 应用端验收；旧构建 15 保持原有行为。

## 自定义手势（构建 18）

构建 18 在触控区新增齿轮入口。可以选择 Sofatap、触控板习惯或长按快捷操作预设，再为单击、左右区双击、双指/三指轻点、长按与滑动分别指定动作。电脑与电视的偏好在 iPhone 上独立保存；可以调整判定时间和滚动方向、恢复预设，或在离线练习区试用。电视可选动作受接收端能力限制。详情和验证范围见[手势设置说明](docs/GESTURES.md)。此功能已通过公开 TestFlight 1.0 (18) 提供。已在专用 iPhone 和 iPad 上通过设置与本地练习测试；接收端实际效果仍需单独验收。

## 安卓手机版本

原生 **Android 手机／平板控制端 0.1.0-beta.1** 位于 [`android/controller`](android/controller/README.md)，与电视接收器分开。要求 Android 8.0+，提供中、英、日三种语言。支持配对与设备管理、电脑和电视独立的手势配置、三套预设及本地练习；电脑接收器和输入框支持时，文字、选区与删除实时同步。其他电脑输入框及电视文字保留明确发送。已发布 APK 的前台听写向标准系统语音服务请求中间识别结果；服务不可用时显示提示。用户也可自行使用输入法的听写按钮。

**尚未发布的源码候选：**标准服务不可用时，Android 12 / API 31 及以上会尝试受支持的设备端识别。两者均不可用时，点击 Sofatap 麦克风会展开当前输入法，并提示点击输入法自己的麦克风，不会自动启动输入法听写。这些回退改进尚未包含在下方链接的 APK 中。

直接 APK 测试版：[版本说明](https://github.com/chekusu/sofatap/releases/tag/android-controller-v0.1.0-beta.1) · [Sofatap-Android-0.1.0-beta.1.apk](https://github.com/chekusu/sofatap/releases/download/android-controller-v0.1.0-beta.1/Sofatap-Android-0.1.0-beta.1.apk)。此版本未上架 Google Play，也没有自动更新器。公开安装包标识为 `com.chekusu.sofatap`，开发包为 `com.chekusu.sofatap.dev`。真机验收另行记录，不能由源码或模拟器检查推断。参见[安装、输入限制与验证说明](android/controller/README.md)。

## 平台进度

| 平台 | 当前状态 |
| --- | --- |
| Android 手机／平板 | **0.1.0-beta.1 预发布版**，Android 8.0+。自定义手势、受支持的电脑实时编辑、电视明确发送及依赖系统服务的听写。直接 APK 分发，无 Google Play 或自动更新器。[设置与验收范围](android/controller/README.md)。 |
| iPhone | iOS 17+。公开版 1.0 (22) 支持 12 种界面语言，可通过[公开 TestFlight](https://testflight.apple.com/join/e6MuKx9S)安装。已确认通过 TestFlight 将构建 16 安装到专用测试 iPhone；最终构建的 Windows 重启恢复与输入验收仍待完成。此前扫码和输入检查仍按实际测试版本记录在 [0.7.1 验证记录](docs/verification/receiver-0.7.1.md)与[构建 16 开发测试记录](docs/verification/input-1.0-16.md)中。 |
| Windows | 接收器 0.8.1 beta.1 已发布，支持原生 Edit/RichEdit 实时编辑。此前限定 RichEdit 真机键盘验收已通过，其他设备项目与本次重启恢复实测仍待完成。Windows 程序尚无 Authenticode 签名。 |
| Mac | macOS 15+。0.8.1 beta.1 的 Apple Silicon 和 Intel 包均已签名、公证，并提供签名 Sparkle 更新源。此前 Apple Silicon 完成部分输入验收；当前实时编辑及 Intel 输入仍待真机验收。 |
| Linux | 0.8.1 beta.1 的 x64、ARM64 GTK3 包已发布。此前 0.7.1 ARM64 接收器曾在隔离 Xvfb 中运行，真 iPhone 对该版本通过了限定的相机配对、Linux 识别、命名及重命名持久化检查。此前 X11 输入检查是独立结果；真实 Wayland 合成器及实体 Linux 桌面输入仍待验收，见 [0.7.1 设备测试记录](docs/verification/receiver-0.7.1.md)。 |

[Mac 验收记录](docs/verification/macos-0.3.0.md)覆盖了 2026-10-11 的真实相机扫码、TLS 连接、文字精确读回和部分按键、指针操作。[Linux 验收记录](docs/verification/linux-0.4.0.md)覆盖原生 GTK 渲染、独立 Xvfb 桌面上的 X11 输入，以及私有 D-Bus 上的模拟 Wayland portal。这些记录不代表所有应用的兼容性均已验证。

鼠标、快捷键和回退的整段文字输入在 Windows 使用 Win32 `SendInput`，Mac 在用户明确授予辅助功能权限后使用 Quartz。实时文字改用 Win32 Edit/RichEdit 消息或 Mac 辅助功能选中文字操作，修改后读回核对，并保留差异区段以外的文字。Linux X11 需要 libX11、libXtst 和 libxdo；Wayland 需要兼容的 RemoteDesktop portal 与系统原生权限授权。Linux 当前仍采用检查草稿后发送，每次文字操作最多 2,048 个 Unicode 标量值，不读取或替换剪贴板。未支持的 Wayland 会话保持不可用，不回退到 XWayland。参见 [Linux 要求与限制](desktop/linux/README.md)。

## 开始使用

### 安装电脑接收端

| 电脑 | 下载 | 安装说明 |
| --- | --- | --- |
| Windows x64 | [Windows ZIP](https://github.com/chekusu/sofatap/releases/download/v0.8.1-beta.1/SofaTap-Windows-x64.zip) | 解压并运行 `SofaTap.exe`，防火墙只允许可信家庭专用网络访问。[Windows 启动说明](docs/WINDOWS-START.md) |
| Mac | [Apple Silicon ZIP](https://github.com/chekusu/sofatap/releases/download/v0.8.1-beta.1/SofaTap-macOS-arm64-notarized.zip) · [Intel ZIP](https://github.com/chekusu/sofatap/releases/download/v0.8.1-beta.1/SofaTap-macOS-x64-notarized.zip) | 两者均已公证。见 [Mac 安装与授权说明](docs/MAC-START.md)。 |
| Linux x64 / ARM64 | [x64 压缩包](https://github.com/chekusu/sofatap/releases/download/v0.8.1-beta.1/SofaTap-Linux-x64.tar.gz) · [ARM64 压缩包](https://github.com/chekusu/sofatap/releases/download/v0.8.1-beta.1/SofaTap-Linux-arm64.tar.gz) | 安装系统 GTK 和输入依赖后，解压并运行 `./sofatap`；原生窗口包含 Wayland 授权入口。[Linux 启动说明](desktop/linux/README.md) |

以上均为 [0.8.1 beta.1，附对应 SHA256 文件与发布说明](https://github.com/chekusu/sofatap/releases/tag/v0.8.1-beta.1)。电脑端包已包含 .NET 运行时，Linux 仍需安装列出的系统依赖。`--dry-run` 可演练连接流程，不产生桌面输入。此前验收记录保留实际测试时的版本标签。

### 安装 iPhone App 并配对

1. [加入 TestFlight 公测](https://testflight.apple.com/join/e6MuKx9S)，安装 **iPhone 1.0 (22)** 和**接收器 0.8.1 beta.1**。TestFlight 内部与外部测试现均提供构建 22。接收器二维码最低要求 iPhone 构建 15。自行构建时，在 Xcode 中打开 `ios/SofaTap.xcodeproj`，选择自己的开发团队和已连接的 iPhone 后运行；这条安装路径需要有效开发签名、设备配对和开发者模式。见 [iOS 构建说明](ios/README.md)。
2. 将 iPhone 与电脑接入可互通的家庭网络。访客 Wi-Fi 的设备隔离可能阻止连接。
3. 点击左上角设备选择入口，在**添加设备**下选择**扫描二维码**。电脑与 Android/Google TV 共用扫码页，认证成功后进入命名步骤。扫描接收端原生窗口里的二维码，或粘贴完整配对链接。
4. 在电脑上选中输入框，再打开手机键盘或麦克风。受支持的字段自动同步打字、删除和识别文字；其他字段显示**发送**按钮，供检查草稿后发送。焦点冲突或断线导致实时输入暂停时，先检查电脑，再明确重新打开编辑器；不确定的编辑不会自动重放。

配对链接含有控制凭据，应只保留在自己的设备上。如果从最早使用 **Tiltro** 名称的版本升级，请阅读[升级说明](docs/WINDOWS-START.md#从旧名称版本升级)：这些版本的标识和存储位置不同，其配对和草稿不会自动迁移。本次 Sofatap 品牌拼写统一会保留现有 Sofatap 配对。

## 隐私与权限

Sofatap 通过局域网直接连接，项目没有云中继服务。配对使用固定证书校验；凭据保存在 iPhone Keychain、Windows DPAPI 或 Mac/Linux 上仅当前用户可读的接收端文件中。Mac 输入需要辅助功能权限，Wayland 输入需要用户明确授予 portal 权限。

iPhone App 的麦克风仅在明确点击或使用已配置的听写手势，并取得所需权限后启动。受支持的本机识别将音频保留在手机上；iPhone App 不上传音频，也不静默切换到云端识别。实时编辑时，识别过程中的文字和后续修正会同步到电脑；回退的草稿模式仍需点**发送**。系统听写和第三方输入法有各自的数据处理方式。

已发布的 Android APK 在明确点击麦克风或使用已配置的手势、授予麦克风权限后，调用标准系统语音服务。该服务可能在线处理音频，中间识别结果是否可用取决于识别器。Sofatap 在退出前台时取消自身的录音会话。

**尚未发布的源码候选**还会在标准服务不可用时，于 Android 12 / API 31 及以上尝试受支持的设备端识别。两种识别器均不可用时，展开当前输入法并提示点击它的麦克风。此候选版本的回退路径不会为 Sofatap 申请麦克风权限，也不会自动启动输入法录音；其可用性、权限和音频处理由输入法负责。参见 [Android 听写与隐私说明](android/controller/README.md#dictation)。

实时编辑通过固定证书校验的 TLS，把当前受支持输入框的完整文字及选区直接传到配对手机。导入的实时文字保留在手机内存中，不会自动保存为草稿。切换设备后，只有明确选择允许再次发送，才会把保留文字转为本地保存的检查后发送草稿；切换本身不会发送文字。接收端在当前连接的有界内存缓存中保留带文字的确认消息，用于防止重复编辑，连接结束后不再保留该缓存。独立的检查后发送草稿仍会保存在本机以便恢复。字段文字不记录日志、不发送到云服务；后台焦点提示仍只包含元数据。

二维码通过本机私有管道传给原生电脑 UI，不使用网页配对。不要公开配对码、凭据或签名材料。仓库不包含开发账号、签名证书或 provisioning profile。通信与输入行为见 [PROTOCOL.md](PROTOCOL.md)，待完成的设备检查见[实机验收清单](docs/ACCEPTANCE.md)。

## 从源码构建

接收端需要 **.NET 10 SDK** 和 Python 3。如果 SDK 在自定义位置，将 `SOFATAP_DOTNET` 设为 `dotnet` 可执行文件路径。

```sh
# 在 Mac/Unix 上构建 Windows 分发包
bash scripts/build-windows.sh

# 在 macOS 上构建 Mac 分发包
bash scripts/build-macos.sh arm64
bash scripts/build-macos.sh x64

# 构建 Linux 分发包，支持交叉构建
bash scripts/build-linux.sh x64
bash scripts/build-linux.sh arm64
```

产物写入 `artifacts/`，附带许可和 SHA256 文件。Windows 和 Mac 包分别命名为 `SofaTap-Windows-x64.zip`、`SofaTap-macOS-<architecture>.zip`；Linux 为 `SofaTap-Linux-<architecture>.tar.gz`。Mac 默认使用 ad-hoc 开发签名；分发签名和 Apple 公证流程见 [NOTARIZATION.md](docs/NOTARIZATION.md)。

Windows 开发者可在 PowerShell 中构建底层接收组件；上面的完整分发包还包含原生窗口：

```powershell
dotnet publish host/SofaTap.Host.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```

分发构建产物时需附上 `LICENSE`、`THIRD-PARTY-NOTICES.md` 和对应依赖许可。打包脚本会收集实际解析到的运行时及 NuGet 版本的许可。

iPhone 使用仓库中的 Xcode 工程。修改 `ios/project.yml` 后，运行 `xcodegen generate --spec ios/project.yml` 重新生成工程。[iOS 说明](ios/README.md)也介绍了直接编译方式；设备编译成功不等于签名和安装已完成。

## 开发验证

在装有 .NET 10、Python 3 和 Xcode 的 Mac 上运行：

```sh
python3 -m pip install websockets==16.0
dotnet run --project tests/host/SofaTap.Host.Tests.csproj -c Release
dotnet run --project desktop/windows-login/Tests/Sofatap.Login.Tests.csproj -c Release
SOFATAP_DOTNET="$(command -v dotnet)" python3 tests/smoke.py
swiftc ios/SofaTap/Core/Pairing.swift tests/PairingTests.swift -o /tmp/sofatap-pairing-tests
/tmp/sofatap-pairing-tests
swiftc ios/SofaTap/Core/ReceiverState.swift tests/ReceiverStateTests.swift -o /tmp/sofatap-receiver-tests
/tmp/sofatap-receiver-tests
swiftc ios/SofaTap/Core/GestureConfiguration.swift ios/SofaTap/Core/TouchGestureState.swift tests/TouchGestureTests.swift -o /tmp/sofatap-gesture-tests
/tmp/sofatap-gesture-tests
python3 tests/text_focus_linux.py
bash ios/scripts/build-manual.sh device
```

Host runner 使用模拟输入器。TLS/WebSocket 检查以 `--dry-run` 启动临时接收端，不向系统注入输入。最后一项编译未配置签名的 ARM64 iOS App，不安装到手机。CI 还执行各平台构建和隔离 Linux 桌面检查；相关命令见 [Linux 说明](desktop/linux/README.md#lifecycle-and-checks)。

构建、协议、虚拟桌面和物理设备检查分别证明不同层面的行为。[0.7.0 真机记录](docs/verification/realtime-input-0.7.0.md)确认 RichEdit 导入、追加、删除和选区同步。实时语音、普通 Edit、文字中段替换、冲突、重连、Mac 实时编辑、Typeless 及更多应用尚不在已完成范围内。

## 源码目录

| 路径 | 内容 |
| --- | --- |
| `ios/` | 原生 iPhone App、Xcode 工程和工程生成配置 |
| `android/controller/` | 原生 Android 手机／平板控制端 beta |
| `android/receiver/` | 实验性 Android/Google TV 接收器 |
| `host/` | 共用接收协议、Windows/Mac 输入后端和 Linux worker 桥接 |
| `desktop/` | 原生配对窗口和 Linux 输入 worker |
| `tests/` | 协议、认证和输入边界检查 |
| `PROTOCOL.md` | 通信协议 |
| `docs/` | 安装指南和验收记录 |
| `scripts/build-*.sh` | 电脑端分发包构建 |
| `licenses/` | 第三方许可与通知原文 |

本机构建产物、配对凭据和签名材料不属于源码。命名背景见 [NAME.md](docs/NAME.md)。

## 参与和许可

欢迎提交 Issue 和 Pull Request，参与前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

Sofatap 采用 [MIT 许可](LICENSE)。第三方依赖通知见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
