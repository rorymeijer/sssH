import Foundation

extension String {
    /// Column alignment for the check-results table.
    func padded(to width: Int, alignRight: Bool = false) -> String {
        guard count < width else { return self }
        let padding = String(repeating: " ", count: width - count)
        return alignRight ? padding + self : self + padding
    }
}
