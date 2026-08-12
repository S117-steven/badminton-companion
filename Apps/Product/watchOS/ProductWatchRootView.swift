import BadmintonCore
import SwiftUI

struct ProductWatchRootView: View {
    @StateObject private var model = ProductWorkoutViewModel()
    @State private var confirmsEnd = false

    var body: some View {
        Group {
            switch model.snapshot.phase {
            case .running, .pausing, .paused, .resuming, .ending:
                workoutPages
            case .completed:
                summary
            default:
                startPage
            }
        }
        .task { await model.prepare() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .productActiveWorkoutRecoveryRequested
            )
        ) { _ in
            Task { await model.prepare() }
        }
    }

    private var startPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "figure.badminton")
                    .font(.system(size: 42))
                    .foregroundStyle(.green)
                Text("羽毛球")
                    .font(.title3.bold())
                Text("请确认手表佩戴在持拍手，并保持表带稳固贴合。")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
#if targetEnvironment(simulator)
                Text("SIMULATOR 流程数据 · 不写入健康")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
#endif
                Button("开始羽毛球运动") {
                    Task { await model.start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled([
                    BadmintonWorkoutSessionPhase.recovering,
                    BadmintonWorkoutSessionPhase.requestingAuthorization,
                    .starting,
                ].contains(model.snapshot.phase))

                if [.recovering, .requestingAuthorization, .starting]
                    .contains(model.snapshot.phase) {
                    ProgressView(
                        model.snapshot.phase == .recovering ? "正在恢复运动" : "正在准备"
                    )
                }
                if let recovered = model.recoveredWorkout {
                    Text("已保护上次异常中断运动：\(duration(recovered.accumulatedActiveDurationSeconds))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                errorText
            }
            .padding()
        }
    }

    private var workoutPages: some View {
        TabView {
            basicMetrics
            smashMetrics
            controls
        }
        .tabViewStyle(.verticalPage)
        .confirmationDialog("结束并保存这次运动？", isPresented: $confirmsEnd) {
            Button("结束运动", role: .destructive) {
                Task { await model.end() }
            }
            Button("继续运动", role: .cancel) {}
        }
    }

    private var basicMetrics: some View {
        VStack(spacing: 8) {
            metric("时间", duration(model.snapshot.activeDurationSeconds), tint: .green)
            metric("心率", heartRateText, suffix: "BPM", tint: .red)
            metric("活动能量", activeEnergyText, suffix: "千卡", tint: .orange)
            metric("总击球", "—", tint: .secondary)
        }
        .padding(.horizontal)
    }

    private var smashMetrics: some View {
        VStack(spacing: 10) {
            metric("本场杀球", "—", tint: .secondary)
            metric("最近速度", "暂无", tint: .secondary)
            metric("最快速度", "暂无", tint: .secondary)
            Text("真实数据门禁通过前不生成击球或速度。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Button(model.snapshot.phase == .paused ? "继续" : "暂停") {
                Task { await model.pauseOrResume() }
            }
            .buttonStyle(.borderedProminent)
            .tint(model.snapshot.phase == .paused ? .green : .yellow)
            .disabled([.pausing, .resuming, .ending].contains(model.snapshot.phase))

            Button("结束", role: .destructive) {
                confirmsEnd = true
            }
            .disabled(model.snapshot.phase == .ending)
            errorText
        }
        .padding()
    }

    private var summary: some View {
        ScrollView {
            VStack(spacing: 9) {
                Label("运动已保存", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                metric("运动时间", duration(model.snapshot.activeDurationSeconds), tint: .green)
                metric("总击球", "—", tint: .secondary)
                metric("杀球", "—", tint: .secondary)
                metric("最快杀球", "暂无", tint: .secondary)
#if targetEnvironment(simulator)
                Text("模拟数据未写入 Apple 健康")
                    .font(.caption2)
                    .foregroundStyle(.orange)
#endif
                Button("完成") { Task { await model.reset() } }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func metric(
        _ title: String,
        _ value: String,
        suffix: String? = nil,
        tint: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(tint)
            if let suffix {
                Text(suffix)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let error = model.errorMessage ?? model.snapshot.failure?.message {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private var heartRateText: String {
        guard let value = model.snapshot.record?.healthMetrics
            .currentHeartRateBeatsPerMinute else { return "等待" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    private var activeEnergyText: String {
        guard let value = model.snapshot.record?.healthMetrics
            .activeEnergyKilocalories else { return "等待" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds)).formatted(
            .time(pattern: .hourMinuteSecond(padHourToLength: 2))
        )
    }
}
