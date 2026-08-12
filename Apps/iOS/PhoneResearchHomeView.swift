import BadmintonCore
import SwiftUI

struct PhoneResearchHomeView: View {
    @StateObject private var model = PhoneResearchViewModel()

    var body: some View {
        TabView {
            NavigationStack {
                ResearchCaptureListView(model: model)
            }
            .tabItem {
                Label("采集", systemImage: "waveform.path.ecg")
            }

            NavigationStack {
                ResearchParticipantListView(model: model)
            }
            .tabItem {
                Label("测试者", systemImage: "person.crop.circle")
            }

            NavigationStack {
                List {
                    Section("研发状态") {
                        LabeledContent("阶段", value: "1")
                        LabeledContent(
                            "数据结构",
                            value: "v\(ResearchCaptureManifest.currentSchemaVersion)"
                        )
                        LabeledContent("本地采集", value: "\(model.captures.count)")
                        LabeledContent("测试者", value: "\(model.participants.count)")
                    }

                    Section("数据原则") {
                        Text("Simulator 数据始终标记为合成来源，不参与真机研究结论。")
                        Text("当前不运行击球识别、杀球分类或测速算法。")
                    }

                    if let error = model.errorMessage {
                        Section("最近错误") {
                            Text(error)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle("研发状态")
            }
            .tabItem {
                Label("状态", systemImage: "checklist")
            }
        }
        .task { await model.reload() }
    }
}

extension ResearchCaptureMode {
    var title: String {
        switch self {
        case .singleAction: "单次击球采集"
        case .normalShotBatch: "普通击球批量采集"
        case .smashBatch: "杀球批量采集"
        case .freePlay: "自由连续采集"
        case .interference: "空挥与干扰采集"
        }
    }
}

extension ManualActionLabel {
    var title: String {
        switch self {
        case .normalShot: "普通击球"
        case .smash: "杀球"
        case .airSwing: "空挥"
        case .running: "跑动"
        case .pickingUpShuttle: "捡球"
        case .shakingArm: "甩手"
        case .wipingSweat: "擦汗"
        case .otherInterference: "其他干扰"
        }
    }
}

extension ResearchReviewStatus {
    var title: String {
        switch self {
        case .pending: "待检查"
        case .valid: "有效"
        case .invalid: "无效"
        }
    }
}
