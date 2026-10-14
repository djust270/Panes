import AppKit
import ExplorerCore

/// Opt-in crash reporting without a server: at launch, if macOS wrote a crash report for
/// Explorer since the last launch, offer to open a prefilled GitHub issue with a summary
/// (versions, exception, crashed thread). Nothing is sent unless the user submits the issue.
@MainActor
enum CrashReporter {
    private static let checkedUntilKey = "CrashReportsCheckedUntil"
    /// GitHub rejects longer "new issue" URLs.
    private static let maxURLLength = 7500

    static func checkAtLaunch() {
        let defaults = UserDefaults.standard
        let now = Date()
        let since = defaults.object(forKey: checkedUntilKey) as? Date
        defaults.set(now, forKey: checkedUntilKey)
        // First launch: crashes of some earlier install aren't ours to report.
        guard let since, AppSettings.offersCrashReports else { return }

        let processName = ProcessInfo.processInfo.processName
        Task {
            let found = await Task.detached(priority: .utility) { () -> (URL, CrashReport)? in
                for (url, _) in CrashReport.reports(for: processName, after: since) {
                    if let data = try? Data(contentsOf: url), let report = CrashReport(data: data) {
                        return (url, report)
                    }
                }
                return nil
            }.value
            guard let (url, report) = found else { return }
            offer(report, file: url)
        }
    }

    private static func offer(_ report: CrashReport, file: URL) {
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.name) quit unexpectedly the last time it was used."
        alert.informativeText = """
            You can report the problem on GitHub. The report says which versions of \(AppInfo.name) and \
            macOS you use and where in \(AppInfo.name) the crash happened. It opens in your browser for \
            you to review before you submit it.
            """
        alert.addButton(withTitle: "Report…")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Show Crash Log")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t offer to report crashes"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            AppSettings.offersCrashReports = false
        }
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(issueURL(for: report))
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(file)
        default:
            break
        }
    }

    /// The issue, with as many stack frames as fit in a URL GitHub accepts.
    static func issueURL(for report: CrashReport) -> URL {
        let title = "Crash: \(report.exception) in \(report.appVersion.isEmpty ? AppInfo.version : report.appVersion)"
        var frames = 40
        while true {
            let url = AppInfo.newIssueURL(title: title, body: report.issueBody(maxFrames: frames), labels: ["crash"])
            if url.absoluteString.count <= maxURLLength || frames <= 5 { return url }
            frames -= 5
        }
    }

    /// Help › Report a Problem…: a blank issue with the versions filled in.
    static func reportProblem() {
        let body = """
            **Version:** \(AppInfo.version) (\(AppInfo.build))
            **macOS:** \(AppInfo.osVersion)

            **What happened:**


            **What you expected:**


            **Steps to reproduce:**

            """
        NSWorkspace.shared.open(AppInfo.newIssueURL(title: "", body: body))
    }
}
