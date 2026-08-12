import BadmintonCore
import SwiftUI

struct ResearchCaptureSetupView: View {
    let mode: ResearchCaptureMode
    @State private var selectedLabel: ManualActionLabel

    init(mode: ResearchCaptureMode) {
        self.mode = mode
        _selectedLabel = State(initialValue: mode.fixedManualLabel ?? mode.availableLabels.first ?? .airSwing)
    }

    var body: some View {
        List {
            Section {
                Text("请确认手表佩戴在持拍手，并保持表带稳固贴合。")
                    .font(.footnote)
            }

            if mode == .freePlay {
                Section("标签") {
                    Text("自由打球不生成伪造的逐拍人工标签。")
                        .font(.footnote)
                }
            } else if let fixed = mode.fixedManualLabel {
                Section("人工标签") {
                    Text(fixed.shortTitle)
                }
            } else {
                Section("人工标签") {
                    Picker("动作", selection: $selectedLabel) {
                        ForEach(mode.availableLabels, id: \.self) { label in
                            Text(label.shortTitle).tag(label)
                        }
                    }
                }
            }

            NavigationLink("进入采集") {
                ResearchCaptureSessionView(
                    mode: mode,
                    manualLabel: mode == .freePlay
                        ? nil
                        : mode.fixedManualLabel ?? selectedLabel
                )
            }
        }
        .navigationTitle(mode.shortTitle)
    }
}

private struct ResearchCaptureSessionView: View {
    @StateObject private var model: WatchCaptureViewModel

    init(mode: ResearchCaptureMode, manualLabel: ManualActionLabel?) {
        _model = StateObject(
            wrappedValue: WatchCaptureViewModel(mode: mode, manualLabel: manualLabel)
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(model.mode.shortTitle)
                    .font(.headline)

                if let label = model.manualLabel {
                    Text("人工标签：\(label.shortTitle)")
                        .font(.caption)
                } else {
                    Text("无逐拍人工标签")
                        .font(.caption)
                }

                sourceBadge

                switch model.snapshot.phase {
                case .idle:
                    Button("开始采集") {
                        Task { await model.start() }
                    }
                    .buttonStyle(.borderedProminent)

                case .preparing:
                    ProgressView("准备中")

                case .collecting, .stopping:
                    Text(model.elapsedSeconds, format: .number.precision(.fractionLength(1)))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("秒 · \(model.snapshot.receivedSampleCount) 样本")
                        .font(.caption)
                    Button("停止并保存", role: .destructive) {
                        Task { await model.stop() }
                    }
                    .disabled(model.snapshot.phase == .stopping)

                case .completed:
                    Label("已保存 \(model.snapshot.persistedSampleCount) 个样本", systemImage: "checkmark.circle")
                    reviewButtons

                case .failed:
                    Label("采集中断，已保留落盘数据", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                if let error = model.errorMessage ?? model.snapshot.failure?.message {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationBarBackButtonHidden(model.snapshot.phase == .collecting)
        .onDisappear {
            Task { await model.interruptIfNeeded() }
        }
    }

    private var sourceBadge: some View {
#if targetEnvironment(simulator)
        Text("SIMULATOR 合成数据")
            .font(.caption2.bold())
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.orange.opacity(0.15), in: Capsule())
#else
        Text("真实传感器")
            .font(.caption2.bold())
            .foregroundStyle(.green)
#endif
    }

    private var reviewButtons: some View {
        VStack {
            Button("有效") { Task { await model.mark(.valid) } }
            Button("待检查") { Task { await model.mark(.pending) } }
            Button("无效", role: .destructive) { Task { await model.mark(.invalid) } }
            Text("当前：\(model.reviewStatus.shortTitle)")
                .font(.caption2)
        }
    }
}

extension ResearchCaptureMode {
    var shortTitle: String {
        switch self {
        case .singleAction: "单次动作"
        case .normalShotBatch: "普通击球"
        case .smashBatch: "杀球"
        case .freePlay: "自由打球"
        case .interference: "空挥与干扰"
        }
    }

    var availableLabels: [ManualActionLabel] {
        switch self {
        case .singleAction:
            [.normalShot, .smash, .airSwing]
        case .interference:
            [.airSwing, .running, .pickingUpShuttle, .shakingArm, .wipingSweat, .otherInterference]
        case .normalShotBatch:
            [.normalShot]
        case .smashBatch:
            [.smash]
        case .freePlay:
            []
        }
    }
}

extension ManualActionLabel {
    var shortTitle: String {
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
    var shortTitle: String {
        switch self {
        case .pending: "待检查"
        case .valid: "有效"
        case .invalid: "无效"
        }
    }
}
