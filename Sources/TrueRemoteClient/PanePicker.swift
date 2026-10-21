import Foundation

public enum PanePicker {
    /// Rows that have a terminal pane, ordered: the last-opened pane first, then needs-you rows, then the rest (stable).
    public static func order(rows: [HubRow], lastPaneId: String?) -> [HubRow] {
        func rank(_ r: HubRow) -> Int {
            if let last = lastPaneId, r.pane == last { return 0 }
            return r.statusKey == "needsYou" ? 1 : 2
        }
        let withPane = rows.filter { $0.pane != nil }
        return withPane.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}
