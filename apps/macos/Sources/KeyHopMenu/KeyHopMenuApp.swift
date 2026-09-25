import AppKit
import SwiftUI

@main
struct KeyHopMenuApp: App {
    var body: some Scene {
        MenuBarExtra("KeyHop", systemImage: "arrow.left.arrow.right") {
            Text("KeyHop 已启动")
            Text("代理与快捷键配置将在后续版本加入")
                .foregroundStyle(.secondary)

            Divider()

            Button("退出 KeyHop") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
