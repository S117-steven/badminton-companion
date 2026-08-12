import BadmintonCore
import SwiftUI
import UIKit

struct ResearchBatchExportView: View {
    @ObservedObject var model: PhoneResearchViewModel
    @State private var participantFilter = "all"
    @State private var labelFilter = "all"
    @State private var reviewFilter = "all"
    @State private var dateFilter = ResearchExportDateFilter.all
    @State private var showsDocumentPicker = false

    var body: some View {
        List {
            Section("筛选") {
                Picker("日期", selection: $dateFilter) {
                    ForEach(ResearchExportDateFilter.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                Picker("测试者", selection: $participantFilter) {
                    Text("全部").tag("all")
                    ForEach(captureParticipantIDs, id: \.self) { id in
                        Text(participantTitle(id)).tag(id.uuidString)
                    }
                }
                Picker("动作标签", selection: $labelFilter) {
                    Text("全部").tag("all")
                    Text("无逐拍标签").tag("none")
                    ForEach(ManualActionLabel.allCases, id: \.self) { label in
                        Text(label.title).tag(label.rawValue)
                    }
                }
                Picker("复核状态", selection: $reviewFilter) {
                    Text("全部").tag("all")
                    ForEach(ResearchReviewStatus.allCases, id: \.self) { status in
                        Text(status.title).tag(status.rawValue)
                    }
                }
            }

            Section("导出范围") {
                LabeledContent("采集数", value: "\(filteredCaptures.count)")
                LabeledContent(
                    "原始记录",
                    value: filteredCaptures.reduce(0) { $0 + $1.sampleCount }.formatted()
                )
                Button("准备当前筛选的批量导出") {
                    Task {
                        await model.prepareBatchExport(
                            captureIDs: filteredCaptures.map(\.id)
                        )
                    }
                }
                .disabled(filteredCaptures.isEmpty || model.isPreparingExport)
                if model.isPreparingExport {
                    ProgressView("正在逐条生成完整文件")
                }
            }

            if let batch = model.preparedBatchExport {
                Section("已准备") {
                    Text("\(batch.captureCount) 个文件 · \(batch.totalSampleCount) 条原始记录")
                    Button("保存到文件") {
                        showsDocumentPicker = true
                    }
                }
            }

            if let message = model.exportMessage {
                Section {
                    Text(message).font(.footnote)
                }
            }
        }
        .navigationTitle("研发数据导出")
        .sheet(isPresented: $showsDocumentPicker) {
            if let batch = model.preparedBatchExport {
                ResearchFilesDocumentPicker(fileURLs: batch.fileURLs)
            }
        }
    }

    private var filteredCaptures: [ResearchCaptureManifest] {
        model.captures.filter { capture in
            dateFilter.includes(capture.startedAt)
                && (participantFilter == "all"
                    || capture.participantID.uuidString == participantFilter)
                && (labelFilter == "all"
                    || (labelFilter == "none" && capture.manualLabel == nil)
                    || capture.manualLabel?.rawValue == labelFilter)
                && (reviewFilter == "all"
                    || capture.reviewStatus.rawValue == reviewFilter)
        }
    }

    private var captureParticipantIDs: [UUID] {
        Array(Set(model.captures.map(\.participantID)))
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func participantTitle(_ id: UUID) -> String {
        if let participant = model.participants.first(where: { $0.id == id }) {
            return "\(participant.skillLevelCode) · \(id.uuidString.prefix(8))…"
        }
        return "\(id.uuidString.prefix(8))…（资料缺失）"
    }
}

private enum ResearchExportDateFilter: String, CaseIterable {
    case all
    case today
    case lastSevenDays

    var title: String {
        switch self {
        case .all: "全部"
        case .today: "今天"
        case .lastSevenDays: "最近 7 天"
        }
    }

    func includes(_ date: Date, now: Date = Date()) -> Bool {
        switch self {
        case .all:
            true
        case .today:
            Calendar.current.isDate(date, inSameDayAs: now)
        case .lastSevenDays:
            date >= Calendar.current.date(
                byAdding: .day,
                value: -6,
                to: Calendar.current.startOfDay(for: now)
            ) ?? .distantPast
        }
    }
}

private struct ResearchFilesDocumentPicker: UIViewControllerRepresentable {
    let fileURLs: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: fileURLs, asCopy: true)
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}
}
