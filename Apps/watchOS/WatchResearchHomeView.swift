import BadmintonCore
import SwiftUI

struct WatchResearchHomeView: View {
    var body: some View {
        NavigationStack {
            List(ResearchCaptureMode.allCases, id: \.self) { mode in
                NavigationLink(mode.shortTitle) {
                    ResearchModeStatusView(mode: mode)
                }
            }
            .navigationTitle("研发采集")
        }
    }
}

private struct ResearchModeStatusView: View {
    let mode: ResearchCaptureMode

    var body: some View {
        VStack(spacing: 10) {
            Text(mode.shortTitle)
                .font(.headline)
            Text("请确认手表佩戴在持拍手，并保持表带稳固贴合。")
                .font(.footnote)
                .multilineTextAlignment(.center)
            Button("采集器待接入") {}
                .disabled(true)
            Text("不会保存模拟数据")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private extension ResearchCaptureMode {
    var shortTitle: String {
        switch self {
        case .singleAction: "单次动作"
        case .normalShotBatch: "普通击球"
        case .smashBatch: "杀球"
        case .freePlay: "自由打球"
        case .interference: "空挥与干扰"
        }
    }
}
