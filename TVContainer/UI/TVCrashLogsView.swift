#if DEBUG
import SwiftUI

private struct TVCrashReport: Identifiable {
    let id: String
    let date: String
    let context: String
    let body: String
    init?(_ value: [AnyHashable: Any]) {
        guard let id = value["id"] as? String, let body = value["body"] as? String else { return nil }
        self.id = id; self.body = body
        date = value["date"] as? String ?? ""
        context = value["context"] as? String ?? "TVContainer"
    }
}

struct TVCrashLogsView: View {
    @State private var reports: [TVCrashReport] = []
    @State private var clear = false
    private func refresh() { reports = TVCrashReports().compactMap { TVCrashReport($0) } }
    var body: some View {
        NavigationStack {
            List {
                Section("Crash logs") {
                    if reports.isEmpty { Text("No captured crashes.").foregroundStyle(.secondary) }
                    ForEach(reports) { report in
                        NavigationLink {
                            List {
                                Text(report.body).font(.system(size: 24, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .navigationTitle("Crash report")
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(report.context).font(.headline)
                                Text(report.date).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 12)
                        }
                    }
                }
                Section {
                    Button("Refresh") { refresh() }
                    Button("Clear Crash Logs", role: .destructive) { clear = true }.disabled(reports.isEmpty)
                } footer: {
                    Text("Reports stay on this Apple TV. Reopen TVContainer after a crash to see its report. Exception stacks and basic fatal-signal details are captured when available. System kills, memory-pressure terminations, and crashes before logging starts may not produce a report. Keep the matching debug symbols when diagnosing a crash.")
                }
            }
            .navigationTitle("Logs")
            .onAppear { refresh() }
            .alert("Clear crash logs?", isPresented: $clear) {
                Button("Clear", role: .destructive) { TVCrashDeleteReports(); refresh() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Saved crash reports will be deleted from this Apple TV.") }
        }
    }
}
#endif
