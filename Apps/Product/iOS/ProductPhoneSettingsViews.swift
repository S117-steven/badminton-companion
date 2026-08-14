import BadmintonCore
import SwiftUI

private struct ProductSkillOption: Identifiable, Hashable {
    let id: String
    let title: String
}

private let productSkillOptions = [
    ProductSkillOption(id: "", title: "稍后填写"),
    ProductSkillOption(id: "product_v1_beginner", title: "初学"),
    ProductSkillOption(id: "product_v1_regular", title: "普通"),
    ProductSkillOption(id: "product_v1_advanced", title: "进阶"),
    ProductSkillOption(id: "product_v1_competitive", title: "竞技"),
]

struct ProductOnboardingView: View {
    @ObservedObject var model: ProductPhoneViewModel
    let onCompletion: () -> Void
    @State private var heightText = ""
    @State private var armSpanText = ""
    @State private var skillCode = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Apple Watch 自动记录羽毛球运动", systemImage: "applewatch")
                    Label("iPhone 长期保存运动历史", systemImage: "iphone")
                    Label("真实数据通过验证后再启用击球分析", systemImage: "checkmark.shield")
                } header: {
                    Text("欢迎使用羽毛球")
                } footer: {
                    Text("运动时请将 Apple Watch 佩戴在持拍手，并保证表带稳固贴合。")
                }

                ProductProfileFields(
                    heightText: $heightText,
                    armSpanText: $armSpanText,
                    skillCode: $skillCode
                )

                Section("权限说明") {
                    Text("健康权限会在 Apple Watch 首次开始运动前申请，用于记录运动、心率和能量。权限被拒绝时会明确提示。")
                    Text("个人资料与运动历史只保存在你的设备中，第一版没有账号和自建云端。")
                }

                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("保存并进入应用") {
                        Task {
                            isSaving = true
                            let saved = await model.saveProfile(
                                heightText: heightText,
                                armSpanText: armSpanText,
                                skillLevelCode: skillCode.isEmpty ? nil : skillCode,
                                onboardingCompleted: true
                            )
                            isSaving = false
                            if saved { onCompletion() }
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .navigationTitle("开始使用")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("稍后填写") {
                        Task {
                            await model.skipOnboarding()
                            if !model.needsOnboarding { onCompletion() }
                        }
                    }
                }
            }
        }
    }
}

struct ProductSettingsView: View {
    @ObservedObject var model: ProductPhoneViewModel

    var body: some View {
        List {
            Section("个人资料") {
                NavigationLink {
                    ProductProfileEditorView(model: model)
                } label: {
                    LabeledContent(
                        "身高与臂展",
                        value: profileSummary(model.profile)
                    )
                }
                NavigationLink {
                    ProductCalibrationStatusView(profile: model.profile)
                } label: {
                    LabeledContent(
                        "个人动作校准",
                        value: model.profile?.calibrationCompletedAt == nil
                            ? "未校准"
                            : "已校准"
                    )
                }
            }

            Section("权限") {
                Label("健康权限由 Apple Watch 在开始运动前申请", systemImage: "heart.text.square")
                Text("手机端不会假装知道每一项健康读取权限是否已授权。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("数据与隐私") {
                NavigationLink("数据保存说明") {
                    ProductDataPrivacyView()
                }
                LabeledContent("账号与云端", value: "不使用")
            }

            Section("当前能力") {
                Label("基础运动记录代码基线", systemImage: "checkmark.circle")
                Label("真实击球与测速等待真机研究", systemImage: "hourglass")
            }
        }
        .navigationTitle("设置")
    }

    private func profileSummary(_ profile: BadmintonUserProfile?) -> String {
        guard let profile else { return "未填写" }
        let values = [profile.heightCentimeters, profile.armSpanCentimeters]
            .compactMap { $0 }
        return values.isEmpty ? "未填写" : "已保存"
    }
}

private struct ProductProfileEditorView: View {
    @ObservedObject var model: ProductPhoneViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var heightText: String
    @State private var armSpanText: String
    @State private var skillCode: String
    @State private var isSaving = false

    init(model: ProductPhoneViewModel) {
        self.model = model
        _heightText = State(initialValue: model.profile?.heightCentimeters.map {
            $0.formatted(.number.precision(.fractionLength(0...1)))
        } ?? "")
        _armSpanText = State(initialValue: model.profile?.armSpanCentimeters.map {
            $0.formatted(.number.precision(.fractionLength(0...1)))
        } ?? "")
        _skillCode = State(initialValue: model.profile?.skillLevelCode ?? "")
    }

    var body: some View {
        Form {
            ProductProfileFields(
                heightText: $heightText,
                armSpanText: $armSpanText,
                skillCode: $skillCode
            )
            Section {
                Text("这些资料只用于未来动作识别和速度估算。是否必填仍是待确认的产品决定，因此现在可以留空。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("个人资料")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task {
                        isSaving = true
                        let saved = await model.saveProfile(
                            heightText: heightText,
                            armSpanText: armSpanText,
                            skillLevelCode: skillCode.isEmpty ? nil : skillCode,
                            onboardingCompleted: true
                        )
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .disabled(isSaving)
            }
        }
    }
}

private struct ProductProfileFields: View {
    @Binding var heightText: String
    @Binding var armSpanText: String
    @Binding var skillCode: String

    var body: some View {
        Section("个人资料（可稍后填写）") {
            TextField("身高（厘米）", text: $heightText)
                .keyboardType(.decimalPad)
            TextField("臂展（厘米）", text: $armSpanText)
                .keyboardType(.decimalPad)
            Picker("羽毛球水平", selection: $skillCode) {
                ForEach(productSkillOptions) { option in
                    Text(option.title).tag(option.id)
                }
            }
        }
    }
}

struct ProductCalibrationStatusView: View {
    let profile: BadmintonUserProfile?

    var body: some View {
        List {
            Section("当前状态") {
                if let date = profile?.calibrationCompletedAt {
                    LabeledContent(
                        "最近完成",
                        value: date.formatted(date: .abbreviated, time: .shortened)
                    )
                    LabeledContent(
                        "校准版本",
                        value: profile?.calibrationVersion ?? "未知"
                    )
                } else {
                    ContentUnavailableView(
                        "尚未校准",
                        systemImage: "figure.badminton",
                        description: Text("未校准用户未来仍可使用通用模型。")
                    )
                }
            }
            Section("真机前限制") {
                Text("校准必须包含 10 次真实普通击球和 10 次真实杀球，不能用空挥或模拟器数据代替。真机数据门禁通过前不会开放开始按钮。")
            }
        }
        .navigationTitle("个人动作校准")
    }
}

private struct ProductDataPrivacyView: View {
    var body: some View {
        List {
            Section("保存位置") {
                Text("运动历史与个人资料保存在 iPhone 本地。运动产生时，Apple Watch 会在手机离线的情况下保留副本并稍后重试同步。")
            }
            Section("不会使用") {
                Label("没有自建账号或服务器", systemImage: "person.crop.circle.badge.xmark")
                Label("不使用摄像头或麦克风分析", systemImage: "video.slash")
                Label("不保存球拍资料", systemImage: "xmark.circle")
            }
            Section("研发隔离") {
                Text("原始曲线、人工标签和外部真实测速只存在于内部研发版，不会编译进正式版。")
            }
        }
        .navigationTitle("数据与隐私")
    }
}
