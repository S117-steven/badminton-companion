import BadmintonCore
import SwiftUI

struct WatchResearchHomeView: View {
    @State private var pendingCount = 0
    @State private var activeParticipantID = WatchResearchConnectivityController
        .shared.activeParticipantID

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ResearchCaptureMode.allCases, id: \.self) { mode in
                        NavigationLink(mode.shortTitle) {
                            ResearchCaptureSetupView(mode: mode)
                        }
                    }
                }

                Section("本地状态") {
                    LabeledContent(
                        "当前测试者",
                        value: activeParticipantID.map {
                            "\($0.uuidString.prefix(8))…"
                        } ?? "未同步"
                    )
                    LabeledContent("待同步采集", value: "\(pendingCount)")
                    Text("Simulator 数据仅用于流程验收")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("研发采集")
        }
        .task {
            let documents = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let store = ResearchCaptureFileStore(
                baseDirectory: documents
                    .appendingPathComponent("ResearchData", isDirectory: true)
                    .appendingPathComponent("Captures", isDirectory: true)
            )
            _ = try? await store.recoverUnfinishedCaptures()
            WatchResearchConnectivityController.shared.queuePendingCaptures()
            let manifests = (try? await store.listManifests()) ?? []
            pendingCount = manifests.filter { $0.syncState != .acknowledged }.count
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchCaptureSyncChanged)) { _ in
            Task {
                let documents = FileManager.default.urls(
                    for: .documentDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
                let store = ResearchCaptureFileStore(
                    baseDirectory: documents
                        .appendingPathComponent("ResearchData", isDirectory: true)
                        .appendingPathComponent("Captures", isDirectory: true)
                )
                let manifests = (try? await store.listManifests()) ?? []
                pendingCount = manifests.filter { $0.syncState != .acknowledged }.count
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .researchActiveParticipantChanged)) { _ in
            activeParticipantID = WatchResearchConnectivityController.shared
                .activeParticipantID
        }
    }
}
