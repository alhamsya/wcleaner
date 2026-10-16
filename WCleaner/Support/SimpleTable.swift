import AppKit

/// A plain, accessible NSTableView wrapper for small lists (accounts, repositories, history).
@MainActor
final class SimpleTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Column {
        let title: String
        let width: CGFloat
    }

    struct Row: Equatable {
        let id: String
        let cells: [String]
        var toolTip: String?
        var secondary: [Bool] = []
    }

    let scrollView = NSScrollView()
    let tableView = NSTableView()
    private(set) var rows: [Row] = []
    var onSelectionChange: ((Row?) -> Void)?
    var onDoubleClick: ((Row) -> Void)?

    init(columns: [Column], accessibilityLabel: String, height: CGFloat = 200) {
        super.init()
        for (index, column) in columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col\(index)"))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.resizingMask = index == columns.count - 1 ? .autoresizingMask : .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.setAccessibilityLabel(accessibilityLabel)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    var selectedRow: Row? {
        let index = tableView.selectedRow
        return rows.indices.contains(index) ? rows[index] : nil
    }

    func setRows(_ newRows: [Row]) {
        guard newRows != rows else { return }
        let selectedID = selectedRow?.id
        rows = newRows
        tableView.reloadData()
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            onSelectionChange?(selectedRow)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let model = rows[row]
        let value = columnIndex < model.cells.count ? model.cells[columnIndex] : ""
        cell.textField?.stringValue = value
        let secondary = columnIndex < model.secondary.count && model.secondary[columnIndex]
        cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
        cell.toolTip = model.toolTip ?? value
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelectionChange?(selectedRow)
    }

    @objc private func doubleClicked() {
        let index = tableView.clickedRow
        guard rows.indices.contains(index) else { return }
        onDoubleClick?(rows[index])
    }
}
