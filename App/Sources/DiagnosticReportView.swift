import SwiftUI
import UIKit

struct DiagnosticReportView: View {
    @EnvironmentObject private var log: ProbeLog
    @EnvironmentObject private var account: PhotosAccount
    @EnvironmentObject private var queue: UploadQueue
    @EnvironmentObject private var preferences: BackupPreferences
    @EnvironmentObject private var albums: PhotoAlbumStore
    @EnvironmentObject private var automaticBackup: AutomaticBackupCoordinator
    @State private var report: DiagnosticReport?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showingShareSheet = false
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Label("Safe to share publicly", systemImage: "hand.raised.fill")
                    .foregroundStyle(.green)
                Text("The report leaves out credentials, account addresses, photo identifiers, filenames, media, and request URLs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    generate()
                } label: {
                    HStack {
                        Label(report == nil ? "Generate Report" : "Refresh Report", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if isGenerating { ProgressView() }
                    }
                }
                .disabled(isGenerating)

                if let report {
                    Button {
                        showingShareSheet = true
                    } label: {
                        Label("Share or Save Report", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = report.text
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Report Text", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Generate the report soon after a problem, then attach the text file to an issue at github.com/g8row/PhotosBackup/issues.")
            }

            if let report {
                Section {
                    ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                        Text(finding)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("What Stands Out")
                } footer: {
                    Text(report.url.lastPathComponent).font(.caption2.monospaced())
                }
            }

            Section {
                NavigationLink("Event Timeline") { DiagnosticEventsView() }
            } footer: {
                Text("What the app decided and why, including when iOS started background work and what it achieved.")
            }
        }
        .navigationTitle("Diagnostic Report")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            if let report {
                ActivityView(items: [report.url])
            }
        }
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        copied = false
        Task {
            do {
                report = try await DiagnosticReportBuilder.create(
                    log: log,
                    account: account,
                    queue: queue,
                    preferences: preferences,
                    albums: albums,
                    automaticBackup: automaticBackup
                )
            } catch {
                errorMessage = "Could not create the report: \(error.localizedDescription)"
                DiagnosticEventLog.shared.record("support", "Could not create a diagnostic report: \(error.localizedDescription)", level: .error)
            }
            isGenerating = false
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
