import BadmintonCore
import SwiftUI

struct WatchResearchHomeView: View {
    @State private var pendingCount = 0

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
            let manifests = (try? await store.listManifests()) ?? []
            pendingCount = manifests.filter { $0.syncState != .acknowledged }.count
        }
    }
}
