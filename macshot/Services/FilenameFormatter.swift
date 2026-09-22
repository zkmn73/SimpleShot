import Foundation

enum FilenameFormatter {
    static let defaultTemplate = "Screenshot {date} at {time}"
    static let userDefaultsKey = "filenameTemplate"

    /// Renders a filename *without* extension from a user-editable template.
    ///
    /// Supported tokens (case-sensitive, lowercase):
    ///   {date}       yyyy-MM-dd
    ///   {time}       HH-mm-ss
    ///   {timestamp}  {date}_{time}
    ///   {unix}       epoch seconds
    ///   {window}     sanitized window title, or "" when nil/empty
    ///   {index}      1, 2, …; "" when nil
    ///   {random}     8-char lowercase base36 (0-9a-z), fresh per call
    ///
    /// Unknown tokens are left verbatim so typos are visible.
    /// The result is sanitized for macOS filesystems (strips `/`, `:`, NUL,
    /// control characters, surrounding whitespace and trailing dots), capped
    /// to 200 UTF-8 bytes without splitting a Unicode character.
    /// If the final result is empty, the default template is re-rendered.
    static func format(
        template: String,
        windowTitle: String? = nil,
        index: Int? = nil,
        date: Date = Date(),
        fallback: String = defaultTemplate
    ) -> String {
        let effective = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : template
        let rendered = render(template: effective, windowTitle: windowTitle, index: index, date: date)
        let sanitized = FilenameSanitizer.sanitize(rendered)
        if sanitized.isEmpty && effective != fallback {
            return format(template: fallback, windowTitle: windowTitle, index: index, date: date, fallback: fallback)
        }
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    private static func render(template: String, windowTitle: String?, index: Int?, date: Date) -> String {
        let dateStr = dateFormatter("yyyy-MM-dd").string(from: date)
        let timeStr = dateFormatter("HH-mm-ss").string(from: date)
        let window = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let values: [String: String] = [
            "{date}": dateStr,
            "{time}": timeStr,
            "{timestamp}": "\(dateStr)_\(timeStr)",
            "{unix}": String(Int(date.timeIntervalSince1970)),
            "{window}": window,
            "{index}": index.map(String.init) ?? "",
        ]

        // Expand the template once. Inserted window titles are literal data,
        // even when a title itself contains a token such as {random} or {date}.
        var out = ""
        var cursor = template.startIndex
        while let open = template[cursor...].firstIndex(of: "{") {
            out += template[cursor..<open]
            guard let close = template[open...].firstIndex(of: "}") else {
                out += template[open...]
                cursor = template.endIndex
                break
            }
            let token = String(template[open...close])
            out += token == "{random}" ? randomToken() : (values[token] ?? token)
            cursor = template.index(after: close)
        }
        out += template[cursor...]
        return out
    }

    private static let randomAlphabet: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static func randomToken(length: Int = 8) -> String {
        var s = ""
        s.reserveCapacity(length)
        for _ in 0..<length {
            s.append(randomAlphabet[Int.random(in: 0..<randomAlphabet.count)])
        }
        return s
    }

    /// Convenience: current user screenshot template + extension.
    static func defaultImageFilename(windowTitle: String? = nil, index: Int? = nil, fileExtension: String = ImageEncoder.fileExtension) -> String {
        let template = UserDefaults.standard.string(forKey: userDefaultsKey) ?? defaultTemplate
        let base = format(template: template, windowTitle: windowTitle, index: index)
        return "\(base).\(fileExtension)"
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
