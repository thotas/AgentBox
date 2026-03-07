import AppKit
import SwiftUI

struct MissionControlView: View {
    @ObservedObject var viewModel: MissionControlViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                header

                if let info = viewModel.infoMessage {
                    BannerView(text: info, tint: Color.blue.opacity(0.25), border: .blue)
                }

                if let error = viewModel.errorMessage {
                    BannerView(text: error, tint: Color.red.opacity(0.22), border: .red)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pendingSection
                        awaitingApprovalSection
                        activeSection
                        completedSection
                    }
                    .padding(.bottom, 30)
                }
            }
            .padding(24)
        }
        .sheet(item: $viewModel.selectedMissionForPlan) { mission in
            PlanArtifactView(
                mission: mission,
                onApprove: {
                    viewModel.approveMission(mission)
                    viewModel.selectedMissionForPlan = nil
                },
                onReject: {
                    viewModel.rejectMission(mission)
                    viewModel.selectedMissionForPlan = nil
                },
                onClose: {
                    viewModel.selectedMissionForPlan = nil
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AgentBox Mission Control")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)

                HStack(spacing: 12) {
                    if let lastPoll = viewModel.missionState.lastPollAt {
                        Label("Last Poll: \(lastPoll.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    } else {
                        Label("Last Poll: never", systemImage: "clock")
                    }

                    if let nextPoll = viewModel.nextScheduledPollAt {
                        Label("Next Poll: \(nextPoll.formatted(date: .omitted, time: .shortened))", systemImage: "timer")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.blue.opacity(0.9))
            }

            Spacer()

            Button {
                Task { await viewModel.pollNow() }
            } label: {
                if viewModel.isPolling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Poll Now", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(viewModel.isPolling)
        }
    }

    private var pendingSection: some View {
        SectionCard(title: "Pending (Inbox)", color: .purple) {
            if viewModel.pendingFileNames.isEmpty {
                EmptyStateView(text: "No pending instruction files in 01_Inbox.")
            } else {
                ForEach(viewModel.pendingFileNames, id: \.self) { file in
                    HStack {
                        Image(systemName: "doc.text")
                        Text(file)
                        Spacer()
                        Text("Waiting for next poll")
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                    .font(.system(.body, design: .rounded))
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var awaitingApprovalSection: some View {
        SectionCard(title: "Awaiting Plan Approval", color: .blue) {
            if viewModel.awaitingApprovalMissions.isEmpty {
                EmptyStateView(text: "No missions waiting for manager plan review.")
            } else {
                ForEach(viewModel.awaitingApprovalMissions) { mission in
                    MissionRow(
                        mission: mission,
                        statusLabel: "Plan Ready",
                        statusColor: .blue,
                        trailingButtonLabel: "Review Plan",
                        trailingAction: {
                            viewModel.selectedMissionForPlan = mission
                        }
                    )
                }
            }
        }
    }

    private var activeSection: some View {
        SectionCard(title: "Active Missions", color: .mint) {
            if viewModel.activeMissions.isEmpty {
                EmptyStateView(text: "No active worker execution right now.")
            } else {
                ForEach(viewModel.activeMissions) { mission in
                    MissionRow(
                        mission: mission,
                        statusLabel: "Thinking",
                        statusColor: .mint,
                        trailingButtonLabel: nil,
                        trailingAction: nil
                    )
                }
            }
        }
    }

    private var completedSection: some View {
        SectionCard(title: "Completed History", color: .indigo) {
            if viewModel.completedMissions.isEmpty {
                EmptyStateView(text: "No completed mission history yet.")
            } else {
                ForEach(viewModel.completedMissions) { mission in
                    MissionRow(
                        mission: mission,
                        statusLabel: statusLabel(for: mission.status),
                        statusColor: statusColor(for: mission.status),
                        trailingButtonLabel: mission.completedArtifactPath == nil ? nil : "View Result",
                        trailingAction: {
                            if let path = mission.completedArtifactPath {
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                        }
                    )
                }
            }
        }
    }

    private func statusLabel(for status: MissionStatus) -> String {
        switch status {
        case .pending: return "Pending"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .rejected: return "Rejected"
        case .active: return "Active"
        case .awaitingApproval: return "Awaiting Approval"
        }
    }

    private func statusColor(for status: MissionStatus) -> Color {
        switch status {
        case .pending: return .gray
        case .completed: return .green
        case .failed: return .red
        case .rejected: return .orange
        case .active: return .mint
        case .awaitingApproval: return .blue
        }
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }

            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.5), lineWidth: 1)
        )
    }
}

private struct MissionRow: View {
    let mission: MissionRecord
    let statusLabel: String
    let statusColor: Color
    let trailingButtonLabel: String?
    let trailingAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mission.fileName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)

                Text("Updated \(mission.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let summary = mission.resultSummary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.85))
                }

                if let error = mission.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text(statusLabel.uppercased())
                    .font(.caption.bold())
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(statusColor.opacity(0.25), in: Capsule())
                    .foregroundStyle(statusColor)

                if let label = trailingButtonLabel, let trailingAction {
                    Button(label) {
                        trailingAction()
                    }
                    .buttonStyle(.bordered)
                    .tint(statusColor)
                } else if mission.status == .active {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct EmptyStateView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}

private struct BannerView: View {
    let text: String
    let tint: Color
    let border: Color

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(border.opacity(0.7), lineWidth: 1)
            )
    }
}

private struct PlanArtifactView: View {
    let mission: MissionRecord
    let onApprove: () -> Void
    let onReject: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Artifact: Manager Plan")
                .font(.title2.bold())
                .foregroundStyle(.white)

            Text("Mission: \(mission.fileName)")
                .foregroundStyle(.secondary)

            ScrollView {
                Text(mission.managerPlan)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.04))
                    )
            }

            HStack {
                Button("Reject") {
                    onReject()
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button("Approve and Dispatch Workers") {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Spacer()

                Button("Close") {
                    onClose()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
        .background(Color.black)
    }
}
