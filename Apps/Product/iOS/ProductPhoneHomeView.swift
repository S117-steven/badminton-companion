import BadmintonCore
import SwiftUI

struct ProductPhoneRootView: View {
    @ObservedObject var model: ProductPhoneViewModel
    @State private var presentsOnboarding = false

    var body: some View {
        ProductPhoneHomeView(model: model)
            .task {
                await model.reload()
                presentsOnboarding = model.needsOnboarding
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .productWorkoutImported)
            ) { _ in
                Task { await model.reload() }
            }
            .fullScreenCover(isPresented: $presentsOnboarding) {
                ProductOnboardingView(model: model) {
                    presentsOnboarding = false
                }
                .interactiveDismissDisabled(model.needsOnboarding)
            }
    }
}

struct ProductPhoneHomeView: View {
    @ObservedObject var model: ProductPhoneViewModel

    var body: some View {
        TabView {
            NavigationStack {
                ProductDashboardView(model: model)
            }
            .tabItem { Label("首页", systemImage: "house") }

            NavigationStack {
                ProductWorkoutHistoryView(model: model)
            }
            .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }

            NavigationStack {
                ProductSettingsView(model: model)
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}

private struct ProductDashboardView: View {
    @ObservedObject var model: ProductPhoneViewModel

    var body: some View {
        List {
            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section("最近运动") {
                if let recent = model.workouts.first {
                    NavigationLink {
                        ProductWorkoutReportView(workout: recent)
                    } label: {
                        ProductWorkoutRow(workout: recent)
                    }
                } else if model.isLoading {
                    ProgressView("正在读取本地运动")
                } else {
                    ContentUnavailableView(
                        "暂无运动",
                        systemImage: "figure.badminton",
                        description: Text("请先在 Apple Watch 上完成一次羽毛球运动。")
                    )
                }
            }

            Section("表现") {
                NavigationLink {
                    ProductPersonalRecordView()
                } label: {
                    LabeledContent("个人最快杀球", value: "暂无")
                }
                LabeledContent("已保存运动", value: "\(model.workouts.count) 场")
            }

            Section("个人动作校准") {
                NavigationLink {
                    ProductCalibrationStatusView(profile: model.profile)
                } label: {
                    LabeledContent(
                        "当前状态",
                        value: model.profile?.calibrationCompletedAt == nil
                            ? "未校准"
                            : "已校准"
                    )
                }
            }

#if targetEnvironment(simulator)
            Section("Simulator 验收") {
                Text("以下入口只存在于模拟器，生成的数据会永久标记为模拟流程数据，不写入 Apple 健康。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button("导入一场模拟运动") {
                    Task { await model.importSimulatorWorkout() }
                }
                if let message = model.simulatorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
#endif
        }
        .navigationTitle("羽毛球")
        .refreshable { await model.reload() }
    }
}

struct ProductWorkoutHistoryView: View {
    @ObservedObject var model: ProductPhoneViewModel

    var body: some View {
        Group {
            if model.workouts.isEmpty, !model.isLoading {
                ContentUnavailableView(
                    "暂无历史运动",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("手表运动同步成功后会保存在这里。")
                )
            } else {
                List(model.workouts) { workout in
                    NavigationLink {
                        ProductWorkoutReportView(workout: workout)
                    } label: {
                        ProductWorkoutRow(workout: workout)
                    }
                }
                .refreshable { await model.reload() }
            }
        }
        .navigationTitle("历史运动")
    }
}

private struct ProductWorkoutRow: View {
    let workout: BadmintonWorkoutRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Spacer()
                if workout.provenance != .healthKitDevice {
                    Text("模拟")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 18) {
                Label(productDuration(workout.accumulatedActiveDurationSeconds), systemImage: "timer")
                Label(productEnergy(workout.healthMetrics.activeEnergyKilocalories), systemImage: "flame")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if workout.lifecycleState == .interrupted {
                Label("运动异常中断，已保留检查点", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ProductWorkoutReportView: View {
    let workout: BadmintonWorkoutRecord

    var body: some View {
        List {
            if workout.provenance != .healthKitDevice {
                Section {
                    Label(
                        "Simulator 流程数据，不是实际运动，也未写入 Apple 健康。",
                        systemImage: "testtube.2"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("运动概览") {
                ProductMetricRow(
                    title: "运动时间",
                    value: productDuration(workout.accumulatedActiveDurationSeconds)
                )
                ProductMetricRow(title: "总击球数", value: "—")
                ProductMetricRow(title: "杀球数", value: "—")
                ProductMetricRow(title: "最快杀球", value: "暂无")
                ProductMetricRow(
                    title: "活动消耗",
                    value: productEnergy(workout.healthMetrics.activeEnergyKilocalories)
                )
            }

            Section("健康数据") {
                ProductMetricRow(
                    title: "平均心率",
                    value: productHeartRate(
                        workout.healthMetrics.averageHeartRateBeatsPerMinute
                    )
                )
                ProductMetricRow(
                    title: "最高心率",
                    value: productHeartRate(
                        workout.healthMetrics.maximumHeartRateBeatsPerMinute
                    )
                )
                ProductMetricRow(
                    title: "总消耗",
                    value: productEnergy(workout.healthMetrics.totalEnergyKilocalories)
                )
                ProductMetricRow(
                    title: "健康记录",
                    value: productHealthWriteState(workout.healthWriteState)
                )
            }

            Section("击球明细") {
                ContentUnavailableView(
                    "真实数据门禁尚未通过",
                    systemImage: "waveform.path.ecg",
                    description: Text("当前不会生成击球数量、分类或速度。")
                )
            }

            if workout.lifecycleState == .interrupted {
                Section("中断信息") {
                    Text(workout.failureMessage ?? "运动未正常结束，已保存可恢复的数据。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("运动报告")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProductMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title, value: value)
    }
}

private struct ProductPersonalRecordView: View {
    var body: some View {
        ContentUnavailableView(
            "暂无可靠杀球纪录",
            systemImage: "trophy",
            description: Text("只有经过真实数据验证且测速可信的杀球才能刷新个人纪录。")
        )
        .navigationTitle("个人纪录")
    }
}

func productDuration(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(0, seconds)).formatted(
        .time(pattern: .hourMinuteSecond(padHourToLength: 2))
    )
}

func productHeartRate(_ value: Double?) -> String {
    guard let value else { return "暂无" }
    return "\(value.formatted(.number.precision(.fractionLength(0)))) BPM"
}

func productEnergy(_ value: Double?) -> String {
    guard let value else { return "暂无" }
    return "\(value.formatted(.number.precision(.fractionLength(1)))) 千卡"
}

private func productHealthWriteState(_ state: WorkoutHealthWriteState) -> String {
    switch state {
    case .saved: "已写入 Apple 健康"
    case .failed: "写入失败"
    case .simulatedNotSaved: "模拟器未写入"
    case .collecting: "正在记录"
    case .notStarted: "尚未写入"
    }
}
