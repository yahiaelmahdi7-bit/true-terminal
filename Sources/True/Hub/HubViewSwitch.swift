import Foundation

/// The Hub's top switch: Work · Chat. All / Agents / Crew are filters inside Work, so the switch maps onto
/// `HubFilter` without owning any state of its own. Pure and testable; picking a side never runs an action.
enum HubView: Hashable {
    case work, chat

    init(filter: HubFilter) { self = filter == .chat ? .chat : .work }

    /// The filter to show after switching to this view. Work returns to the filter the user last had there.
    func filter(workFilter: HubFilter) -> HubFilter {
        switch self {
        case .chat: return .chat
        case .work: return workFilter == .chat ? .all : workFilter
        }
    }
}
