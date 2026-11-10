import Foundation

public enum Template {

    /// Substitutes the `{key}` tokens.
    ///
    /// An unknown token is left **as-is** rather than replaced by nothing. On a
    /// dialog shown to the user, a visible `{deferrals}` is an obvious bug fixed the
    /// same day; a silent hole ships to production and no one notices it.
    public static func render(_ template: String, values: [String: String]) -> String {
        var result = template
        for key in values.keys.sorted() {
            result = result.replacingOccurrences(of: "{\(key)}", with: values[key]!)
        }
        return result
    }

    /// Application list as markdown bullets — swiftDialog renders markdown.
    public static func appList(_ apps: [BlockingAppSpec]) -> String {
        apps.map { "- \($0.displayName)" }.joined(separator: "\n")
    }

    /// Explicit date format and `en_US_POSIX` locale, so that the output does not
    /// depend on the device's regional settings: a dialog must display the same
    /// across the whole fleet, and the format must be testable.
    public static func formatDeadline(
        _ date: Date,
        languageCode: String,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = languageCode.hasPrefix("fr")
            ? "dd/MM/yyyy 'à' HH:mm"
            : "yyyy-MM-dd 'at' HH:mm"
        return formatter.string(from: date)
    }

    /// Tokens available in the manifest's texts.
    public static func values(
        manifest: Manifest,
        request: PromptRequest,
        languageCode: String,
        timeZone: TimeZone
    ) -> [String: String] {
        var values: [String: String] = [
            "name": manifest.displayName,
            "version": manifest.version,
            "apps": appList(request.apps),
            "deferrals": String(request.deferralsRemaining),
        ]
        // No deadline: we substitute an empty string rather than leave "{deadline}"
        // on screen. This is the only exception to the rule above, and it is
        // deliberate — the absence of a deadline is a normal case, not a manifest
        // error.
        values["deadline"] = request.deadline.map {
            formatDeadline($0, languageCode: languageCode, timeZone: timeZone)
        } ?? ""
        return values
    }
}
