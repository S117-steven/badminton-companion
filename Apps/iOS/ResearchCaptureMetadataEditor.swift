import BadmintonCore
import SwiftUI

struct ResearchCaptureMetadataEditor: View {
    let capture: ResearchCaptureManifest
    @ObservedObject var model: PhoneResearchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var reviewStatus: ResearchReviewStatus
    @State private var invalidReason: String
    @State private var notes: String
    @State private var speedText: String
    @State private var speedUnit: ResearchSpeedUnit
    @State private var speedSource: String
    @State private var measurementStatus: ExternalMeasurementStatus
    @State private var pairingIdentifier: String
    @State private var isSaving = false

    init(capture: ResearchCaptureManifest, model: PhoneResearchViewModel) {
        self.capture = capture
        self.model = model
        _reviewStatus = State(initialValue: capture.reviewStatus)
        _invalidReason = State(initialValue: capture.invalidReason ?? "")
        _notes = State(initialValue: capture.notes ?? "")
        _speedText = State(
            initialValue: capture.externalSpeedReference.map {
                String($0.measuredValue)
            } ?? ""
        )
        _speedUnit = State(
            initialValue: capture.externalSpeedReference?.unit ?? .kilometersPerHour
        )
        _speedSource = State(
            initialValue: capture.externalSpeedReference?.sourceDescription ?? ""
        )
        _measurementStatus = State(
            initialValue: capture.externalSpeedReference?.status ?? .pendingReview
        )
        _pairingIdentifier = State(
            initialValue: capture.externalSpeedReference?.pairingIdentifier ?? ""
        )
    }

    var body: some View {
        Form {
            Section("有效性") {
                Picker("状态", selection: $reviewStatus) {
                    ForEach(ResearchReviewStatus.allCases, id: \.self) { status in
                        Text(status.title).tag(status)
                    }
                }
                if reviewStatus == .invalid {
                    TextField("无效原因", text: $invalidReason)
                }
                TextField("备注", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            }

            Section("外部真实测速") {
                if supportsOneToOneSpeedPairing {
                    TextField("测量值（留空表示无）", text: $speedText)
                        .keyboardType(.decimalPad)
                    Picker("单位", selection: $speedUnit) {
                        ForEach(ResearchSpeedUnit.allCases, id: \.self) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    TextField("测速设备或方法", text: $speedSource)
                    TextField("样本配对标识", text: $pairingIdentifier)
                        .textInputAutocapitalization(.never)
                    Picker("可信状态", selection: $measurementStatus) {
                        ForEach(ExternalMeasurementStatus.allCases, id: \.self) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    Text("只录入外部设备的真实测量，不得填入模型估算或人为数值。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else {
                    Text(speedPairingUnavailableMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.errorMessage {
                Section("错误") {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("研发元数据")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    isSaving = true
                    Task {
                        let saved = await model.saveResearchMetadata(
                            captureID: capture.id,
                            reviewStatus: reviewStatus,
                            invalidReason: invalidReason,
                            notes: notes,
                            speedText: supportsOneToOneSpeedPairing ? speedText : "",
                            speedUnit: speedUnit,
                            speedSource: supportsOneToOneSpeedPairing ? speedSource : "",
                            measurementStatus: measurementStatus,
                            pairingIdentifier: supportsOneToOneSpeedPairing ? pairingIdentifier : ""
                        )
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .disabled(isSaving)
            }
        }
    }

    private var supportsOneToOneSpeedPairing: Bool {
        capture.mode == .singleAction
            && capture.manualLabel == .smash
            && capture.provenance == .physicalSensor
    }

    private var speedPairingUnavailableMessage: String {
        if capture.provenance != .physicalSensor {
            return "Simulator 和自动测试数据不得录入外部真实速度。"
        }
        return "只有“单次动作 + 杀球”能与一条真实速度一对一配对。批量段不接受模糊的单值。"
    }
}

extension ExternalMeasurementStatus {
    var title: String {
        switch self {
        case .pendingReview: "待复核"
        case .verified: "已验证"
        case .rejected: "已拒绝"
        }
    }
}
