import Foundation

struct BearerAuth: Sendable {
    let token: String

    func allows(_ headers: [String: String]) -> Bool {
        guard let header = headers["authorization"] else {
            _ = constantTimeEquals("", token)
            return false
        }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, String(parts[0]).caseInsensitiveCompare("Bearer") == .orderedSame else {
            _ = constantTimeEquals(header, token)
            return false
        }
        let presented = String(parts[1]).trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(presented, token)
    }
}

/// Compares the full buffers even when the lengths differ.
func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    let count = max(a.count, b.count)
    if count == 0 {
        return true
    }
    var diff: UInt8 = a.count == b.count ? 0 : 1
    for index in 0..<count {
        let left: UInt8 = index < a.count ? a[index] : 0
        let right: UInt8 = index < b.count ? b[index] : 0
        diff |= left ^ right
    }
    return diff == 0
}
