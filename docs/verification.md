# 本地验收

## 自动检查

```sh
npm run check
npm test
npm run test:mac
npm run test:hotkeys
npm run build:mac
npm pack
npm run test:package
python3 apps/macos/Tests/cli_pty_integration.py dist/KeyHop.app/Contents/MacOS/KeyHopMenu
```

Swift 测试使用本地模拟代理端口，覆盖 HTTP / SOCKS5 协议差异、不可用端口、握手失败，以及配置和启动边界。测试探测不会将模拟成功解释为真实 App 流量验证。npm 打包前校验通用二进制、App 元数据和本地签名。

## 桌面流程

建议给验收使用独立的绝对配置目录，避免覆盖日常设置：

```sh
export KEYHOP_HOME=/tmp/keyhop-acceptance
proxy-launcher
proxy-launcher status --json
proxy-launcher
```

验收项目：

1. 首次运行显示菜单栏入口与设置，再次运行激活已有实例，PID 不变。名称只显示 KeyHop；菜单「添加新应用」打开设置窗口。
2. 新配置和没有 `proxy.enabled` 的旧配置均默认关闭代理，默认不绑定热键；无需代理服务即可启动受控测试 App。
3. 手动开启代理，设置本地实际代理（例如 HTTP `127.0.0.1:7897`），检查协议和时间。切换错误协议或无人监听端口时不可显示成功，也不创建新目标进程。
4. 对正在运行的 Codex 点击打开或使用快捷键，只切到前台，原应用不受影响；开关代理不重启已有进程。
5. 使用受控测试 App 记录启动环境和 argv，核对关闭代理、开启 HTTP / SOCKS5 及自动识别 Chromium / Electron 的行为；界面不出现代理方式选择。
6. 使用交互式 CLI 测试终端输入、带空格路径和特殊字符参数；只打开 Terminal 时不能标记已启动。
7. 开启代理后，启动或探测成功不表示 App 流量已验证；关闭时不会显示陈旧的代理可用结果。
8. 修改或关闭代理后保留旧运行记录的原始配置；新的探测结果只属于新的代理配置。CLI `status --json` 在关闭时为 `proxyEnabled: false`、`proxy: null`。
9. `proxy-launcher quit` 正常退出菜单栏，不结束任何目标 App；`status` 显示未运行。
10. 从本地 tarball 全局安装后，在无 Swift 构建步骤的情况下可启动；包不应依赖源码目录。

不使用自动强退或自动重启日常 Codex / ChatGPT 来测试。当前本地构建只有 ad hoc 签名；尚未执行 npm 发布、Developer ID 签名或 Apple 公证。

## 2026-09-25 初版验收结果

- 21 项 Node 测试、20 项 Swift 测试通过。
- PTY 集成验证键盘输入、Ctrl-C、代理变量、重复请求与并发实例保护通过。
- arm64 / x86_64 通用构建、签名验证和离线临时全局安装通过；桌面运行在 Apple Silicon 本机验证，未在 Intel 实机执行。
- 实际 HTTP `127.0.0.1:7897` 隧道探测通过；不可用端口 `127.0.0.1:1` 会阻止 App 启动。
- 设置窗口可添加 App 和保存逐行参数；受控 GUI App 实际收到大小写代理变量、直连规则、Chromium 参数，带空格和 `$(...)` 的参数保持字面值。
- 已运行 Codex 显示先退出提示，没有退出或重启用户的 Codex。
- 再次运行 CLI 后 PID 不变；`quit` 后启动器退出，受控 GUI App 保持运行。

验收使用隔离配置与自建 App；未把探测或配置传递结果当成真实 Codex 全量流量验证。

## 精简界面与快捷键更新

- 设置改为单窗口代理栏与应用列表；启动选项和连接详情按需打开，已移除启动记录入口及历史弹窗。
- 旧配置不需要迁移；每个应用可录制、取消或清除独立快捷键。
- 自动测试覆盖重复组合、键位/修饰键映射、旧配置读取，以及运行中 GUI 的前台激活与代理状态保持。
- `npm run test:hotkeys` 在真实 macOS 桌面会话验证注册、独占冲突、系统组合冲突、按住去重、录制暂停/恢复、过期事件忽略和释放。该测试直接发送 Carbon 事件，不模拟物理按键。
- 本机同源 Carbon 测试程序直接运行时上述断言通过；但独立脚本新编译的测试程序被 macOS 在进入 main 前以 SIGKILL（137）终止，该脚本本次未完整通过。产品 App 正常运行，真实键盘验证见下项。
- 用户已用真实键盘确认：从其他 App 按 Control + Option + C 能唤起已运行的 Codex。已有进程不重启，流量状态仍未验证。
- CLI 已在运行时仍保留重复启动保护；不会声称已经定位并切换其具体终端窗口。

## 可选代理与 KeyHop 界面更新

- 23 项 Node 测试、44 项 Swift 测试通过，覆盖默认关闭、旧 JSON 关闭、显式开启保存、自动识别应用框架，以及关闭时的 GUI / CLI 实际进程启动。
- 增强 PTY 集成通过：代理开启时传入配置；关闭且代理端口不可用时仍能运行，并清除继承代理变量；终端输入、Ctrl-C、重复请求与并发保护正常。
- 实际窗口验证名称为 KeyHop，原应用和快捷键保留；代理默认关闭，开启后显示连接设置，关闭后收起并清空检查结果。验收后已恢复关闭。
- arm64 / x86_64 通用构建与本地签名验证通过；未发布 npm。
