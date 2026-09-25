# KeyHop 开发指南

日常使用与 npm 安装见 [README](../README.md)。本页记录源码构建、配置、验证与分发细节。

## 环境与构建

运行需要 macOS 13+、Node.js 20+。从源码构建还需要 Swift 6 / Xcode Command Line Tools。

```sh
npm run build:mac          # 构建 Apple Silicon + Intel 通用 App
npm pack                  # 验证通用 App 并生成本地 npm 包
npm install -g ./keyhop-0.1.0.tgz
keyhop
```

`keyhop` 与 `proxy-launcher` 是等价命令。npm 包携带预构建的 App，安装或日常运行不需要 Swift，可直接通过 `npm install -g keyhop` 安装。

随包 App 使用 ad hoc 签名，尚未使用 Developer ID 签名或经过 Apple 公证，因此不具备 Apple 对开发者身份及公证结果的验证。构建脚本会校验签名完整性，但这不等同于公证；后续正式签名需要 Apple Developer 账号及相应证书。

## 配置与状态

共享配置位于 `~/Library/Application Support/KeyHop/`：

| 文件或目录 | 用途 |
| --- | --- |
| `config.json` | 版本化的代理、应用启动配置和可选全局快捷键 |
| `status.json` | 菜单栏 PID、代理检查与最近启动状态 |
| `requests/`、`receipts/` | CLI 启动请求与真实进程回执 |
| `logs/`、`launcher.log` | GUI 启动输出和启动器日志 |

`proxy.enabled` 默认为 `false`，旧配置缺少该字段时也保持关闭。快捷键默认不绑定。设置界面与 CLI 共用配置；无效配置会提示错误并保留原文件，修正后可重新载入。修改配置不会改变已经运行的目标进程。

可使用绝对路径的 `KEYHOP_HOME` 指定隔离配置目录：

```sh
KEYHOP_HOME=/tmp/keyhop-dev node bin/keyhop.mjs
KEYHOP_HOME=/tmp/keyhop-dev node bin/keyhop.mjs status
KEYHOP_HOME=/tmp/keyhop-dev node bin/keyhop.mjs quit
```

## CLI 管理

```sh
keyhop status
keyhop status --json
keyhop quit
keyhop --help
```

`status` 读取共享配置与运行记录，并核实菜单栏进程身份。关闭代理时显示「未开启」，JSON 返回 `proxyEnabled: false`、`proxy: null`。开启时显示最近一次协议检查及其时间，超过 60 秒的结果显示过期，不代表实时连通性。已有运行记录保留原始代理快照，不随当前开关改写。

`quit` 只正常退出 KeyHop，保留已启动的目标 App。更新或卸载前应先退出：

```sh
keyhop quit
npm install -g keyhop@latest
# 或卸载：npm uninstall -g keyhop
```

卸载包会保留个人配置，方便重新安装后继续使用。

## 快捷键与启动行为

快捷键使用 macOS 全局热键注册，无需辅助功能权限。普通按键须搭配 ⌘、⌃ 或 ⌥；F1–F20 可单独绑定，部分键盘需要按 Fn。绑定按物理键位保存，显示使用美式键盘标签。

同一配置内的重复绑定、已启用的 macOS 系统快捷键和系统报告的注册冲突会被拒绝。其他 App 的所有本地菜单快捷键无法完整检测，建议选择不常用的组合。录制时按 Esc 取消、Delete 清除；退出 KeyHop 后释放注册。

GUI App 已运行时直接切到前台，保留原网络设置，不自动退出或重启。CLI 在 Terminal 中交互运行；已有 CLI 实例不会重复启动，也不会猜测其终端窗口。通过改名或特殊包装器启动的 CLI 进程可能无法识别。

## 代理检查与边界

关闭代理时不探测代理，不为新进程注入代理变量或自动代理参数。开启后，CLI 使用代理环境变量；自动识别为 Chromium / Electron 的 GUI App 还会收到对应启动参数，其他 GUI App 使用环境变量。界面不暴露实现方式的选择。

HTTP 与 SOCKS5 分别请求建立到 `example.com:443` 的代理隧道，不互相回退。TCP 端口可连接但隧道失败、协议不匹配、要求认证或超时，都不会标记为代理可用。检查可能受到代理域名规则或网络状态影响；第一版不支持带认证的代理。

| 状态 | 能证明什么 |
| --- | --- |
| 代理服务可用 | 最近一次使用所选协议的隧道握手成功 |
| 已按配置启动 | 确实创建了目标进程并传入配置；仅打开 Terminal 时显示等待回执 |
| App 流量未验证 | 未进行流量接管或请求审计，不能证明每条请求经过代理 |

原生 App 可能不采用代理环境变量，其他进程也可能使用独立网络栈。KeyHop 不提供系统强制分流或全量流量验证。

## 开发与验证命令

```sh
npm run build:mac:native    # 仅编译当前架构，加快开发；不能直接打通用 npm 包
node bin/keyhop.mjs
npm run check
npm test                   # Node CLI、进程身份与旧状态测试
npm run test:mac            # Swift 配置、启动及真实 socket 协议测试
npm run test:hotkeys        # 当前 macOS 桌面会话中的全局热键注册、冲突与事件测试
npm run test:package        # 临时全局安装验收，生成 dist/keyhop-0.1.0.tgz
python3 apps/macos/Tests/cli_pty_integration.py dist/KeyHop.app/Contents/MacOS/KeyHopMenu
```

测试的环境要求与已知限制见 [本地验收](verification.md)，实现范围见 [产品说明](product.md)。
