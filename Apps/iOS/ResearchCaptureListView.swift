import BadmintonCore
import SwiftUI

struct ResearchCaptureListView: View {
    @ObservedObject var model: PhoneResearchViewModel

    var body: some View {
        List {
            Section {
                if model.captures.isEmpty {
                    ContentUnavailableView(
                        "暂无研发采集",
                        systemImage: "waveform",
                        description: Text("等待手表传入，或运行 Simulator 入站验收。")
                    )
                } else {
                    ForEach(model.captures) { capture in
                        NavigationLink {
                            ResearchCaptureDetailView(capture: capture, model: model)
                        } label: {
                            ResearchCaptureRow(capture: capture)
                        }
                    }
                }
            }

#if targetEnvironment(simulator)
            Section("Simulator 验收") {
                Button("运行合成采集入站检查") {
                    Task { await model.runSimulatorInboundCheck() }
                }
                Text("生成的数据会标记为 simulator_synthetic，不具备真机研究资格。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let message = model.simulatorImportMessage {
                    Text(message)
                        .font(.footnote)
                }
            }
#endif
        }
        .navigationTitle("研发采集")
        .refreshable { await model.reload() }
        .overlay {
            if model.isLoading && model.captures.isEmpty {
                ProgressView()
            }
        }
    }
}

private struct ResearchCaptureRow: View {
    let capture: ResearchCaptureManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(capture.mode.title)
                    .font(.headline)
                Spacer()
                Text(capture.reviewStatus.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(capture.startedAt, format: .dateTime.month().day().hour().minute())
                .font(.subheadline)
            HStack {
                Text("\(capture.sampleCount) 个样本")
                Text(capture.provenance.rawValue)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ResearchCaptureDetailView: View {
    let capture: ResearchCaptureManifest
    @ObservedObject var model: PhoneResearchViewModel

    var body: some View {
        List {
            Section("采集") {
                LabeledContent("模式", value: capture.mode.title)
                LabeledContent(
                    "人工标签",
                    value: capture.manualLabel?.title ?? "无逐拍标签"
                )
                LabeledContent("样本数", value: "\(capture.sampleCount)")
                LabeledContent("状态", value: capture.state.rawValue)
                LabeledContent("来源", value: capture.provenance.rawValue)
                LabeledContent("Schema", value: "v\(capture.schemaVersion)")
            }

            Section("采样质量") {
                LabeledContent(
                    "请求间隔",
                    value: intervalText(capture.quality.requestedIntervalSeconds)
                )
                LabeledContent(
                    "平均间隔",
                    value: intervalText(capture.quality.averageActualIntervalSeconds)
                )
                LabeledContent(
                    "最大间隔",
                    value: intervalText(capture.quality.maximumActualIntervalSeconds)
                )
                if let sourceSummaries = capture.quality.sourceSummaries {
                    ForEach(sourceSummaries, id: \.source) { summary in
                        LabeledContent(
                            summary.source.title,
                            value: "\(summary.sampleCount) 条 · \(intervalText(summary.averageActualIntervalSeconds))"
                        )
                    }
                }
            }

            Section("检查与导出") {
                NavigationLink("查看原始曲线") {
                    ResearchCaptureChartsView(capture: capture, model: model)
                }
                Button("准备完整 NDJSON 导出") {
                    Task { await model.prepareExport(captureID: capture.id) }
                }
                .disabled(model.isPreparingExport)
                if model.isPreparingExport {
                    ProgressView("正在生成")
                }
                if let export = model.preparedExport,
                   export.captureID == capture.id {
                    ShareLink(item: export.fileURL) {
                        Label("共享导出文件", systemImage: "square.and.arrow.up")
                    }
                }
                if let message = model.exportMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("人工复核") {
                Button("标记有效") {
                    Task { await model.updateReview(captureID: capture.id, status: .valid) }
                }
                Button("标记待检查") {
                    Task { await model.updateReview(captureID: capture.id, status: .pending) }
                }
                Button("标记无效", role: .destructive) {
                    Task { await model.updateReview(captureID: capture.id, status: .invalid) }
                }
            }

            if !capture.provenance.isEligibleForPhysicalDataAnalysis {
                Section {
                    Label("此采集不能用于真机算法研究。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("采集详情")
    }

    private func intervalText(_ interval: TimeInterval?) -> String {
        guard let interval else { return "暂无" }
        return String(format: "%.3f ms", interval * 1_000)
    }
}

private extension ResearchSensorSource {
    var title: String {
        switch self {
        case .accelerometer: "加速度计"
        case .gyroscope: "陀螺仪"
        case .deviceMotion: "设备运动"
        }
    }
}
