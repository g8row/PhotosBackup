import SwiftUI
import UIKit

/// The event timeline, newest first, so a user can see why the app did what
/// it did without generating and reading a whole report.
struct DiagnosticEventsView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case problems = "Problems"
        var id: Self { self }
    }

    @State private var events: [DiagnosticEvent] = []
    @State private var filter: Filter = .all
    @State private var confirmingClear = false

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Up to \(DiagnosticEventLog.defaultLimit) events from the last two weeks. Warnings and errors are kept longer than routine entries. Filenames, photo identifiers, addresses and links are removed.")
            }

            Section {
                if visible.isEmpty {
                    Text(filter == .all ? "No events recorded yet." : "No warnings or errors.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(visible.enumerated()), id: \.offset) { _, event in
                    DiagnosticEventRow(event: event)
                }
            }
        }
        .navigationTitle("Event Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        let formatter = ISO8601DateFormatter()
                        UIPasteboard.general.string = events.map { $0.line(formatter) }.joined(separator: "\n")
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Clear Timeline", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Clear the event timeline?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Timeline", role: .destructive) {
                DiagnosticEventLog.shared.clear()
                reload()
            }
        } message: {
            Text("A later diagnostic report will not be able to explain what happened before now.")
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private var visible: [DiagnosticEvent] {
        let newestFirst = events.reversed()
        return filter == .all ? Array(newestFirst) : newestFirst.filter { $0.level != .info }
    }

    private func reload() {
        events = DiagnosticEventLog.shared.snapshot()
    }
}

private struct DiagnosticEventRow: View {
    let event: DiagnosticEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(event.category.capitalized).font(.caption.weight(.semibold))
                    Spacer()
                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(event.message)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if event.occurrences > 1 {
                    Text("Repeated \(event.occurrences) times"
                         + (event.firstDate.map { " since \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch event.level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch event.level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// One backup run: what started it, when, under which conditions, and what
/// it achieved.
struct AutomaticRunRow: View {
    let run: AutomaticBackupRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(run.source.rawValue).font(.subheadline.weight(.medium))
                Spacer()
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let summary = run.summary {
                Text(summary.prefix(1).uppercased() + summary.dropFirst())
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Still running, or the app was stopped before it finished.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let context = run.context {
                Text(context).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let duration = run.duration {
                Text("Took \(AutomaticBackupCoordinator.describeInterval(duration))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch run.success {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "exclamationmark.triangle.fill"
        case .none: return "clock.badge.exclamationmark"
        }
    }

    private var tint: Color {
        switch run.success {
        case .some(true): return .green
        case .some(false), .none: return .orange
        }
    }
}
