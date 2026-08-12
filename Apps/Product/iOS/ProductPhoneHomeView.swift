import SwiftUI

struct ProductPhoneHomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ContentUnavailableView(
                        "暂无运动",
                        systemImage: "figure.badminton",
                        description: Text("请先在 Apple Watch 上完成一次羽毛球运动。")
                    )
                }
                Section("开发状态") {
                    Label("基础运动记录 Simulator 基线", systemImage: "hammer")
                    Text("当前未启用击球识别或杀球测速，不显示模拟纪录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("羽毛球")
        }
    }
}
