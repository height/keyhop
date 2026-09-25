import AppKit
import KeyHopCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: LauncherModel
    @State private var proxyProtocol: ProxyProtocol = .http
    @State private var address = ""
    @State private var editing: ProfileDraft?
    @State private var details = false

    private var proxyChanged: Bool {
        proxyProtocol != model.configuration.proxy.protocol || address != proxyAddress(model.configuration.proxy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.forward.circle.fill").font(.system(size: 24)).foregroundStyle(.teal)
                Text("KeyHop").font(.system(size: 20, weight: .semibold))
                Spacer()
            }
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .accessibilityLabel("关闭提示")
                }
            }
            if !model.configurationUsable {
                HStack {
                    Button("显示配置文件") { model.revealConfiguration() }
                    Button("重新载入") { model.reloadConfiguration() }
                }
            }
            HStack {
                Text("应用").font(.headline)
                Text("快捷键可在后台使用").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { editing = ProfileDraft(profile: AppProfile(name: "新应用", kind: .gui, path: "")) } label: {
                    Label("添加", systemImage: "plus")
                }.disabled(model.isBusy || !model.configurationUsable)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.configuration.profiles, id: \.id) { profile in
                        AppRow(model: model, profile: profile) { editing = ProfileDraft(profile: profile) }
                        if profile.id != model.configuration.profiles.last?.id { Divider().padding(.leading, 48) }
                    }
                    if model.configuration.profiles.isEmpty {
                        Text("添加一个 App，再为它录制快捷键。").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 50)
                    }
                }
            }.frame(maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("使用代理").font(.body.weight(.medium))
                    if model.configuration.proxy.enabled {
                        Circle().fill(model.proxyColor).frame(width: 6, height: 6)
                        Text(model.proxySummary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("使用代理", isOn: Binding(get: { model.configuration.proxy.enabled }, set: { model.setProxyEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(model.isBusy || !model.configurationUsable)
                }
                if model.configuration.proxy.enabled {
                    HStack(spacing: 8) {
                        Picker("代理协议", selection: $proxyProtocol) {
                            Text("HTTP").tag(ProxyProtocol.http)
                            Text("SOCKS5").tag(ProxyProtocol.socks5)
                        }.labelsHidden().frame(width: 100)
                        TextField("127.0.0.1:7897", text: $address).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("代理地址")
                        Button(proxyChanged ? "保存并检查" : "检查") {
                            if proxyChanged { model.saveProxy(address: address, protocol: proxyProtocol, bypass: model.configuration.proxy.bypass.joined(separator: ",")) }
                            else { Task { await model.checkProxy() } }
                        }.disabled(model.isBusy || model.isCheckingProxy || !model.configurationUsable)
                    }
                    HStack {
                        Text("App 流量未验证").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("连接详情") { details = true }.buttonStyle(.link).font(.caption)
                    }
                }
                Text("仅对之后新启动的应用生效。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22).frame(minWidth: 550, minHeight: 380)
        .onAppear { loadProxy() }
        .onChange(of: model.configuration.proxy) { _ in loadProxy() }
        .sheet(item: $editing) { ProfileEditor(model: model, original: $0.profile) }
        .sheet(isPresented: $details) { ConnectionDetails(model: model) }
    }

    private func proxyAddress(_ proxy: ProxyConfiguration) -> String {
        "\(proxy.host.contains(":") ? "[\(proxy.host)]" : proxy.host):\(proxy.port)"
    }
    private func loadProxy() { proxyProtocol = model.configuration.proxy.protocol; address = proxyAddress(model.configuration.proxy) }
}

private struct AppRow: View {
    @ObservedObject var model: LauncherModel
    let profile: AppProfile
    let edit: () -> Void
    @State private var deleting = false

    var body: some View {
        HStack(spacing: 10) {
            if profile.kind == .gui && FileManager.default.fileExists(atPath: profile.path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: profile.path)).resizable().frame(width: 30, height: 30)
            } else {
                Image(systemName: profile.kind == .cli ? "terminal" : "app.dashed")
                    .font(.system(size: 23)).foregroundStyle(.secondary).frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.body.weight(.medium)).lineLimit(1)
                if let error = model.hotKeyErrors[profile.id] {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(model.record(for: profile)?.message ?? profile.path)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(hotKey: Binding(get: { profile.hotKey }, set: { shortcut in
                var next = profile; next.hotKey = shortcut; model.saveProfile(next)
            }), onRecordingChanged: { model.setShortcutRecording($0) })
                .frame(width: 148)
                .disabled(model.isBusy || !model.configurationUsable)
            Button("打开") { Task { await model.launch(profile) } }
                .disabled(model.isBusy || !model.configurationUsable)
                .help("打开应用；已运行时切到前台")
            Menu {
                Button("编辑启动设置…", action: edit)
                if profile.hotKey != nil {
                    Button("清除快捷键") { var next = profile; next.hotKey = nil; model.saveProfile(next) }
                }
                if model.configuration.proxy.enabled {
                    Button("按当前设置启动") { Task { await model.launch(profile, activateExisting: false) } }
                }
                Divider()
                Button("移除", role: .destructive) { deleting = true }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(profile.name) 更多操作")
                .disabled(model.isBusy || !model.configurationUsable)
        }
        .padding(.vertical, 13).padding(.horizontal, 2)
        .confirmationDialog("移除“\(profile.name)”的启动配置？", isPresented: $deleting) {
            Button("移除", role: .destructive) { model.removeProfile(profile.id) }
        }
    }

    private var subtitle: String {
        if !FileManager.default.fileExists(atPath: profile.path) { return "未找到应用 · 编辑路径" }
        guard let record = model.record(for: profile) else { return profile.kind == .cli ? "在 Terminal 中启动" : "打开或切到前台" }
        switch record.state {
        case .launched: return model.configuration.proxy.enabled && record.proxy != nil ? "已按代理配置启动 · 流量未验证" : "已启动"
        case .activated: return model.configuration.proxy.enabled ? "已切到前台 · 原代理状态不变" : "已切到前台"
        case .requested: return "等待 Terminal 执行"
        case .alreadyRunning:
            if profile.kind == .cli { return "已运行 · 查看终端" }
            return model.configuration.proxy.enabled ? "已运行 · 需退出后应用新设置" : "已运行 · 可切到前台"
        case .proxyUnavailable: return model.configuration.proxy.enabled ? "代理不可用 · 未启动" : "点击打开"
        case .failed: return "启动失败"
        case .exited: return "进程已退出"
        }
    }
}

private struct ProfileDraft: Identifiable {
    var id: String { profile.id }
    var profile: AppProfile
}

private struct ProfileEditor: View {
    @ObservedObject var model: LauncherModel
    let original: AppProfile
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: AppKind = .gui
    @State private var path = ""
    @State private var arguments = ""
    @State private var notes = ""
    @State private var advanced = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("启动设置").font(.title3.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                Picker("类型", selection: $kind) {
                    Text("macOS App").tag(AppKind.gui)
                    Text("命令行工具").tag(AppKind.cli)
                }
                HStack {
                    TextField("路径", text: $path)
                    Button("选择…") { choosePath() }
                }
            }.textFieldStyle(.roundedBorder)
            DisclosureGroup("启动选项", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 10) {
                    if kind == .cli {
                        Text("命令会在 Terminal 中交互运行。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("额外参数 · 每行一个").font(.caption)
                    TextEditor(text: $arguments).font(.system(.body, design: .monospaced))
                        .frame(height: 64).border(Color.secondary.opacity(0.2))
                    TextField("备注", text: $notes).textFieldStyle(.roundedBorder)
                }.padding(.top, 8)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 480)
        .onAppear {
            name = original.name; kind = original.kind; path = original.path
            arguments = original.arguments.joined(separator: "\n"); notes = original.notes ?? ""
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if kind == .gui { panel.allowedContentTypes = [.applicationBundle] }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name == "新应用" || name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func save() {
        let profile = AppProfile(id: original.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                                 path: path.trimmingCharacters(in: .whitespacesAndNewlines),
                                 arguments: arguments.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
                                 bundleIdentifier: kind == .gui ? Bundle(path: path)?.bundleIdentifier : nil,
                                 notes: notes.isEmpty ? nil : notes, hotKey: original.hotKey)
        if model.saveProfile(profile) { dismiss() } else { error = model.errorMessage }
    }
}

private struct ConnectionDetails: View {
    @ObservedObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss
    @State private var bypass = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接详情").font(.title3.weight(.semibold))
            Text(model.endpointDescription).font(.system(.body, design: .monospaced))
            Text(model.proxyHeadline).foregroundStyle(model.proxyColor)
            if let proxy = model.status.proxy {
                Text(proxy.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text(proxy.checkedAt.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            TextField("直连地址", text: $bypass).textFieldStyle(.roundedBorder)
            Text("地址用逗号分隔。修改代理后，已有 App 需要退出重开才会采用新配置。")
                .font(.caption).foregroundStyle(.secondary)
            Text("KeyHop 使用已有代理，不修改系统代理。代理检查不代表目标 App 的全部流量经过代理。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("显示配置文件") { model.revealConfiguration() }
                Spacer()
                Button("完成") {
                    if bypass != model.configuration.proxy.bypass.joined(separator: ",") {
                        let p = model.configuration.proxy
                        let host = p.host.contains(":") ? "[\(p.host)]" : p.host
                        guard model.saveProxy(address: "\(host):\(p.port)", protocol: p.protocol, bypass: bypass) else { return }
                    }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 470)
        .onAppear { bypass = model.configuration.proxy.bypass.joined(separator: ",") }
    }
}
