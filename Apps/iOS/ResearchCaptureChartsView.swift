import BadmintonCore
import Charts
import SwiftUI

struct ResearchCaptureChartsView: View {
    let capture: ResearchCaptureManifest
    @ObservedObject var model: PhoneResearchViewModel

    @State private var samples: [ResearchMotionSample] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("读取抽样曲线")
            } else if let loadError {
                ContentUnavailableView(
                    "曲线读取失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                Section {
                    Text("为控制内存，界面最多均匀抽取 4,500 条记录；导出文件仍包含全部原始记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                vectorSection(
                    title: "原始加速度（m/s²）",
                    points: samples.compactMap { sample in
                        guard sample.source == .accelerometer,
                              let vector = sample.accelerationMetersPerSecondSquared else {
                            return nil
                        }
                        return VectorSample(
                            id: sample.sequenceNumber,
                            elapsed: sample.elapsedTimeSeconds,
                            vector: vector
                        )
                    }
                )

                vectorSection(
                    title: "原始角速度（rad/s）",
                    points: samples.compactMap { sample in
                        guard sample.source == .gyroscope,
                              let vector = sample.angularVelocityRadiansPerSecond else {
                            return nil
                        }
                        return VectorSample(
                            id: sample.sequenceNumber,
                            elapsed: sample.elapsedTimeSeconds,
                            vector: vector
                        )
                    }
                )

                intervalSection
            }
        }
        .navigationTitle("原始曲线")
        .task(id: capture.id) {
            isLoading = true
            do {
                samples = try await model.loadChartSamples(captureID: capture.id)
                loadError = nil
            } catch {
                loadError = String(describing: error)
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private func vectorSection(
        title: String,
        points: [VectorSample]
    ) -> some View {
        Section(title) {
            if points.isEmpty {
                Text("无该通道数据")
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("时间", point.elapsed),
                        y: .value("值", point.vector.x),
                        series: .value("轴", "X")
                    )
                    .foregroundStyle(by: .value("轴", "X"))
                    LineMark(
                        x: .value("时间", point.elapsed),
                        y: .value("值", point.vector.y),
                        series: .value("轴", "Y")
                    )
                    .foregroundStyle(by: .value("轴", "Y"))
                    LineMark(
                        x: .value("时间", point.elapsed),
                        y: .value("值", point.vector.z),
                        series: .value("轴", "Z")
                    )
                    .foregroundStyle(by: .value("轴", "Z"))
                }
                .chartXAxisLabel("秒")
                .frame(height: 220)
            }
        }
    }

    private var intervalSection: some View {
        Section("实际采样间隔（ms）") {
            let points = samples.compactMap { sample -> IntervalSample? in
                guard let interval = sample.actualIntervalSeconds else { return nil }
                return IntervalSample(
                    id: sample.sequenceNumber,
                    elapsed: sample.elapsedTimeSeconds,
                    source: sample.source.rawValue,
                    milliseconds: interval * 1_000
                )
            }
            if points.isEmpty {
                Text("无间隔数据")
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("时间", point.elapsed),
                        y: .value("间隔", point.milliseconds),
                        series: .value("来源", point.source)
                    )
                    .foregroundStyle(by: .value("来源", point.source))
                }
                .chartXAxisLabel("秒")
                .frame(height: 220)
            }
        }
    }
}

private struct VectorSample: Identifiable {
    let id: UInt64
    let elapsed: TimeInterval
    let vector: SensorVector3
}

private struct IntervalSample: Identifiable {
    let id: UInt64
    let elapsed: TimeInterval
    let source: String
    let milliseconds: Double
}
