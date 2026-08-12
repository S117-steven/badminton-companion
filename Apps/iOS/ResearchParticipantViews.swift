import BadmintonCore
import SwiftUI

struct ResearchParticipantListView: View {
    @ObservedObject var model: PhoneResearchViewModel
    @State private var presentsEditor = false

    var body: some View {
        List {
            if model.participants.isEmpty {
                ContentUnavailableView(
                    "暂无测试者",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("先创建测试者，再将采集与稳定的 UUID 关联。")
                )
            } else {
                ForEach(model.participants) { participant in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(participant.id.uuidString.prefix(8))
                            .font(.headline.monospaced())
                        Text(
                            "身高 \(participant.heightCentimeters, specifier: "%.1f") cm · 臂展 \(participant.armSpanCentimeters, specifier: "%.1f") cm"
                        )
                        .font(.subheadline)
                        Text("\(participant.skillLevelCode) · 定义 v\(participant.skillLevelDefinitionVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("测试者")
        .toolbar {
            Button {
                presentsEditor = true
            } label: {
                Label("新建测试者", systemImage: "plus")
            }
        }
        .sheet(isPresented: $presentsEditor) {
            ResearchParticipantEditor(model: model, isPresented: $presentsEditor)
        }
    }
}

private struct ResearchParticipantEditor: View {
    @ObservedObject var model: PhoneResearchViewModel
    @Binding var isPresented: Bool
    @State private var height = ""
    @State private var armSpan = ""
    @State private var skillLevel = "research_v1_regular"

    private let skillLevels = [
        ("research_v1_beginner", "初学（研发定义 v1）"),
        ("research_v1_regular", "普通（研发定义 v1）"),
        ("research_v1_advanced", "进阶（研发定义 v1）"),
        ("research_v1_competitive", "竞技（研发定义 v1）"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("身体资料") {
                    TextField("身高（厘米）", text: $height)
                        .keyboardType(.decimalPad)
                    TextField("臂展（厘米）", text: $armSpan)
                        .keyboardType(.decimalPad)
                }

                Section("羽毛球水平") {
                    Picker("水平", selection: $skillLevel) {
                        ForEach(skillLevels, id: \.0) { code, title in
                            Text(title).tag(code)
                        }
                    }
                }

                Section {
                    Text("当前分级只用于内部研发数据并带定义版本，不锁定正式产品分级。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新建测试者")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if await model.saveParticipant(
                                heightText: height,
                                armSpanText: armSpan,
                                skillLevelCode: skillLevel
                            ) {
                                isPresented = false
                            }
                        }
                    }
                }
            }
        }
    }
}

