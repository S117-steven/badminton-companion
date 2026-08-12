import BadmintonCore
import SwiftUI

struct PhoneResearchHomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("当前研发阶段") {
                    LabeledContent("阶段", value: "0 → 1")
                    LabeledContent("数据结构", value: "v\(ResearchCaptureManifest.currentSchemaVersion)")
                    Text("先建立真实传感器数据链路，不运行未验证的击球识别或测速算法。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("内部采集模式") {
                    ForEach(ResearchCaptureMode.allCases, id: \.self) { mode in
                        NavigationLink(mode.title) {
                            ResearchModeDetailView(mode: mode)
                        }
                    }
                }
            }
            .navigationTitle("羽毛球研发")
        }
    }
}

private struct ResearchModeDetailView: View {
    let mode: ResearchCaptureMode

    var body: some View {
        List {
            Section("用途") {
                Text(mode.purpose)
            }

            Section {
                Text("传感器适配器和真机权限将在下一步接入。当前工程不会创建空白样本或模拟数据。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(mode.title)
    }
}

private extension ResearchCaptureMode {
    var title: String {
        switch self {
        case .singleAction: "单次击球采集"
        case .normalShotBatch: "普通击球批量采集"
        case .smashBatch: "杀球批量采集"
        case .freePlay: "自由连续采集"
        case .interference: "空挥与干扰采集"
        }
    }

    var purpose: String {
        switch self {
        case .singleAction: "保存一次人工已知动作的完整原始时间序列。"
        case .normalShotBatch: "连续保存一组人工标注为普通击球的原始数据。"
        case .smashBatch: "连续保存一组人工标注为杀球的原始数据。"
        case .freePlay: "记录自然打球环境，不生成未经人工确认的逐拍标签。"
        case .interference: "采集空挥、跑动、捡球、甩手、擦汗等非击球动作。"
        }
    }
}
