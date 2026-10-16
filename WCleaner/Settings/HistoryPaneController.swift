import AppKit
import WCleanerCore

@MainActor
final class HistoryPaneController: SettingsPaneViewController {
    private let table = SimpleTable(
        columns: [
            .init(title: "Date", width: 140),
            .init(title: "Result", width: 90),
            .init(title: "Worktree", width: 210),
            .init(title: "Pull Request", width: 130),
        ],
        accessibilityLabel: "Cleanup history",
        height: 220
    )
    private let detailLabel = UIFactory.note("")

    override func buildContent() {
        addSection("Cleanup History")
        addFullWidth(UIFactory.note("A local log of every removal attempt and review. It is stored only on this Mac and never contains tokens."))
        addFullWidth(table.scrollView)
        table.onSelectionChange = { [weak self] _ in self?.updateDetail() }
        addFullWidth(detailLabel)
        let clear = UIFactory.button("Clear History…", target: self, action: #selector(clearHistory))
        let reveal = UIFactory.button("Show Data Folder in Finder", target: self, action: #selector(revealFolder))
        stack.addArrangedSubview(UIFactory.hStack([clear, reveal]))
    }

    override func refresh() {
        table.setRows(model.history.map { entry in
            SimpleTable.Row(
                id: entry.id.uuidString,
                cells: [
                    EnglishDateFormat.dateTime.format(entry.timestamp),
                    Self.resultTitle(entry),
                    "\(entry.repositoryName) · \(entry.branch ?? (entry.worktreePath as NSString).lastPathComponent)",
                    entry.pullRequestNumber.map { "#\($0)" } ?? "—",
                ],
                toolTip: entry.worktreePath,
                secondary: [true, false, false, true]
            )
        })
        updateDetail()
    }

    override func shouldRefresh(for change: AppModel.Change) -> Bool { change == .history }

    static func resultTitle(_ entry: CleanupHistoryEntry) -> String {
        let mode = entry.mode == .automatic ? "Auto" : "Manual"
        switch entry.result {
        case .removed: return "\(mode): Removed"
        case .refused: return "\(mode): Stopped"
        case .failed: return "\(mode): Failed"
        case .reviewed: return "Reviewed"
        }
    }

    private func updateDetail() {
        guard let row = table.selectedRow, let entry = model.history.first(where: { $0.id.uuidString == row.id }) else {
            detailLabel.stringValue = model.history.isEmpty ? "No cleanup activity yet." : "Select an entry to see details."
            return
        }
        var lines = [
            "Worktree: \(entry.worktreePath)",
            "Repository: \(entry.repositoryName)\(entry.githubRepository.map { " (\($0))" } ?? "")",
        ]
        if let head = entry.headSHA { lines.append("HEAD: \(head)") }
        if let url = entry.pullRequestURL { lines.append("Pull request: \(url)") }
        if let login = entry.accountLogin { lines.append("Account: @\(login)") }
        if let size = entry.estimatedSizeBytes { lines.append("Estimated size: \(ByteFormatter.string(size))") }
        lines += entry.rationale.map { "• \($0)" }
        if let error = entry.errorMessage { lines.append("Error: \(error)") }
        detailLabel.stringValue = lines.joined(separator: "\n")
    }

    @objc private func clearHistory() { model.actions?.clearHistory() }
    @objc private func revealFolder() { model.actions?.revealDataFolder() }
}
