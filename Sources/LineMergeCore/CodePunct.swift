import Foundation

/// Vision's Chinese model reads ASCII punctuation in code as full-width forms
/// ("merge（rows: List［dict］，key"). A line with no CJK text at all but
/// ASCII words and full-width punctuation is code or English; fold the
/// full-width punctuation back to ASCII there and leave every other line alone.
public enum CodePunct {
    public static func fold(_ line: String) -> String {
        var letters = 0
        var fullwidth = 0
        for scalar in line.unicodeScalars {
            if isCJK(scalar) { return line }
            if scalar.isASCII, CharacterSet.letters.contains(scalar) { letters += 1 }
            if isFullwidthPunct(scalar) { fullwidth += 1 }
        }
        guard fullwidth > 0, letters >= 3 else { return line }
        var out = String.UnicodeScalarView()
        for scalar in line.unicodeScalars {
            if isFullwidthPunct(scalar), let ascii = Unicode.Scalar(scalar.value - 0xFEE0) {
                out.append(ascii)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Folds each newline-separated line of a text.
    public static func foldText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { fold(String($0)) }
            .joined(separator: "\n")
    }

    /// Full-width ASCII punctuation and symbols (not letters or digits).
    private static func isFullwidthPunct(_ s: Unicode.Scalar) -> Bool {
        guard (0xFF01...0xFF5E).contains(s.value), let ascii = Unicode.Scalar(s.value - 0xFEE0) else { return false }
        return !CharacterSet.alphanumerics.contains(ascii)
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
