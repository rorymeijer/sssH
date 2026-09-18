import Foundation
import SwiftData

/// A folder in the sidebar. Nestable, because people organise by customer,
/// then environment, then role.
@Model
final class HostGroup {
    var name: String = ""
    var parent: HostGroup?
    /// Manual ordering; the sidebar sorts by this, then by name.
    var order: Int = 0
    var colorName: String?
    var createdAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \HostGroup.parent)
    var children: [HostGroup]? = []

    /// Deleting a group must not delete the hosts in it — that would turn a
    /// tidy-up into data loss. They become ungrouped instead.
    @Relationship(deleteRule: .nullify, inverse: \Host.group)
    var hosts: [Host]? = []

    init(name: String = "", parent: HostGroup? = nil, order: Int = 0) {
        self.name = name
        self.parent = parent
        self.order = order
    }
}

extension HostGroup {
    /// Group path for display, outermost first.
    var breadcrumb: [String] {
        var names: [String] = []
        var seen: Set<PersistentIdentifier> = []
        var current: HostGroup? = self
        while let group = current, !seen.contains(group.persistentModelID) {
            seen.insert(group.persistentModelID)
            names.append(group.name)
            current = group.parent
        }
        return names.reversed()
    }
}
