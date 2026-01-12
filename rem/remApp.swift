//
//  remApp.swift
//  rem
//
//  Created by Jason McGhee on 12/16/23.
//

import AppKit
import CryptoKit

// MARK: - Data Exporter for Claude Access

struct CaptureData: Codable {
    let timestamp: String
    let app: String
    let windowTitle: String?
    let url: String?
    let ocrText: String
    let frameId: Int64
    let sessionId: String?      // Groups related captures
    let sessionDuration: Int?   // Seconds in current session
}

// Activity entry for timeline - captures what you were actually doing
struct ActivityEntry: Codable {
    let time: String           // "21:30"
    let app: String
    let windowTitle: String?
    let url: String?
    let keyContent: [String]   // Important text from this moment
}

// Hourly summary with full recall capability
struct HourlySummary: Codable {
    let hour: String
    let date: String
    let timeline: [ActivityEntry]       // What you did, in order
    let urlsVisited: [String]           // All URLs this hour
    let appsUsed: [String: Int]         // app -> minutes
    let keyTopics: [String]             // Extracted topics/titles
    let workingSummary: String          // "What was I working on" blurb
    let domains: [String: Int]          // Domain -> visit count
}

// Daily journal for end-of-day recall
struct DailyJournal: Codable {
    let date: String
    let timeline: [ActivityEntry]       // Full day timeline
    let allUrls: [URLVisit]             // Every URL with context
    let appSummary: [String: Int]       // Time per app in minutes
    let keyMoments: [String]            // Notable things you saw
    let daySummary: String              // "What did I do today" blurb
    let topDomains: [String: Int]       // Most visited domains
    let projectsWorkedOn: [String]      // Detected project/repo names
}

struct URLVisit: Codable {
    let url: String
    let title: String?
    let firstSeen: String
    let visitCount: Int
}

struct SessionInfo {
    var id: String
    var app: String
    var startTime: Date
    var captureCount: Int
}

class DataExporter {
    static let shared = DataExporter()

    private let exportBaseDir: URL
    private let fileManager = FileManager.default
    private var dailyStats: [String: Int] = [:]  // app -> capture count
    private var dailyUrls: [String: Int] = [:]   // url -> visit count
    private var lastDigestDate: String = ""

    // Production-ready logging
    private let logger = RemLogger.shared.export

    // Deduplication - using deterministic hash (not Swift's hashValue which changes per session)
    private var lastOcrHash: String = ""
    private var lastApp: String = ""
    private var lastWindowTitle: String = ""
    private var duplicateSkipCount: Int = 0

    // Session tracking
    private var currentSession: SessionInfo?
    private let sessionTimeoutSeconds: TimeInterval = 300  // 5 min gap = new session
    private var lastCaptureTime: Date?

    // Hourly tracking - for perfect recall
    private var hourlyTimeline: [ActivityEntry] = []
    private var hourlyUrls: Set<String> = []
    private var hourlyStats: [String: Int] = [:]
    private var hourlyTopics: Set<String> = []
    private var lastHour: Int = -1

    // Daily tracking - accumulated for journal
    private var dailyTimeline: [ActivityEntry] = []
    private var dailyUrlVisits: [String: (title: String?, firstSeen: String, count: Int)] = [:]
    private var dailyKeyMoments: [String] = []
    private var dailyProjects: Set<String> = []

    // Domain tracking
    private var hourlyDomains: [String: Int] = [:]
    private var dailyDomains: [String: Int] = [:]

    // Thread synchronization for hourly/daily data
    private let dataLock = NSLock()

    // Retention settings
    let videoRetentionHours: Int = 1

    // AppleScript cache - compiled scripts are expensive (50-200ms each)
    private var windowTitleScripts: [String: NSAppleScript] = [:]
    private var browserUrlScripts: [String: NSAppleScript] = [:]
    private let scriptCacheLock = NSLock()

    init() {
        let homeDir = fileManager.homeDirectoryForCurrentUser
        exportBaseDir = homeDir.appendingPathComponent("rem-data")

        // Create export directory with proper error handling
        do {
            try fileManager.createDirectory(at: exportBaseDir, withIntermediateDirectories: true)
            RemLogger.shared.logInfo("Export directory ready: \(exportBaseDir.path)", context: "init", logger: RemLogger.shared.export)
        } catch {
            RemLogger.shared.logError(error, context: "DataExporter.init:createDirectory", logger: RemLogger.shared.export)
        }

        // Pre-compile common browser URL scripts
        precompileBrowserScripts()
    }

    private func precompileBrowserScripts() {
        let scripts: [(String, String)] = [
            ("Safari", """
            tell application "Safari"
                try
                    return URL of current tab of front window
                on error
                    return ""
                end try
            end tell
            """),
            ("Google Chrome", """
            tell application "Google Chrome"
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """),
            ("Arc", """
            tell application "Arc"
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """)
        ]

        for (app, source) in scripts {
            if let script = NSAppleScript(source: source) {
                browserUrlScripts[app] = script
            }
        }
    }

    // MARK: - Window Title Extraction (with caching)

    func getWindowTitle(for appName: String?) -> String? {
        guard let app = appName else { return nil }

        scriptCacheLock.lock()
        var cachedScript = windowTitleScripts[app]
        scriptCacheLock.unlock()

        // Compile and cache script if not already cached
        if cachedScript == nil {
            let source = """
            tell application "System Events"
                tell process "\(app)"
                    try
                        return name of front window
                    on error
                        return ""
                    end try
                end tell
            end tell
            """
            if let newScript = NSAppleScript(source: source) {
                scriptCacheLock.lock()
                windowTitleScripts[app] = newScript
                cachedScript = newScript
                scriptCacheLock.unlock()
            }
        }

        guard let script = cachedScript else { return nil }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if error == nil, let title = output.stringValue, !title.isEmpty {
            return title
        }
        return nil
    }

    // MARK: - Browser URL Extraction (with caching)

    func getBrowserURL(for appName: String?) -> String? {
        guard let app = appName else { return nil }

        // Firefox doesn't support AppleScript well, skip
        if app == "Firefox" { return nil }

        // Handle Chrome alias
        let lookupApp = (app == "Chrome") ? "Google Chrome" : app

        scriptCacheLock.lock()
        let cachedScript = browserUrlScripts[lookupApp]
        scriptCacheLock.unlock()

        guard let script = cachedScript else { return nil }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if error == nil, let url = output.stringValue, !url.isEmpty {
            return url
        }
        return nil
    }

    // MARK: - Deduplication & Cleaning

    private func isDuplicate(ocrText: String, appName: String?) -> Bool {
        // Use SHA256 for deterministic hash (Swift's hashValue changes per session)
        let hash = SHA256.hash(data: Data(ocrText.utf8)).description
        let app = appName ?? "Unknown"

        // Same app and same content = duplicate
        if hash == lastOcrHash && app == lastApp {
            duplicateSkipCount += 1
            return true
        }

        lastOcrHash = hash
        lastApp = app
        duplicateSkipCount = 0
        return false
    }

    private func cleanOcrText(_ text: String) -> String {
        var cleaned = text

        // Remove single character lines (OCR noise)
        let lines = cleaned.components(separatedBy: "\n")
        let filteredLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 2 || trimmed.isEmpty
        }
        cleaned = filteredLines.joined(separator: "\n")

        // Collapse multiple newlines
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        // Remove common OCR artifacts
        let artifacts = ["￿", "�", "|||", "•••", "....", "____"]
        for artifact in artifacts {
            cleaned = cleaned.replacingOccurrences(of: artifact, with: "")
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasMinimumContent(_ text: String) -> Bool {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 }
        return words.count >= 5  // At least 5 meaningful words
    }

    // MARK: - Session Tracking

    private func updateSession(app: String, timestamp: Date) -> (sessionId: String, duration: Int) {
        let timeSinceLastCapture = lastCaptureTime.map { timestamp.timeIntervalSince($0) } ?? 0

        // Start new session if: different app, or timeout exceeded, or first capture
        if currentSession == nil ||
           currentSession?.app != app ||
           timeSinceLastCapture > sessionTimeoutSeconds {

            // Generate session ID: app-HHMM
            let formatter = DateFormatter()
            formatter.dateFormat = "HHmm"
            let sessionId = "\(app)-\(formatter.string(from: timestamp))"

            currentSession = SessionInfo(
                id: sessionId,
                app: app,
                startTime: timestamp,
                captureCount: 1
            )
        } else {
            currentSession?.captureCount += 1
        }

        lastCaptureTime = timestamp

        // Safe unwrap - guaranteed to exist after the above logic
        guard let session = currentSession else {
            return ("unknown-session", 0)
        }
        let duration = Int(timestamp.timeIntervalSince(session.startTime))
        return (session.id, duration)
    }

    // MARK: - Activity Tracking for Perfect Recall

    private func trackActivity(app: String, windowTitle: String?, url: String?, ocrText: String, timestamp: Date) {
        dataLock.lock()
        defer { dataLock.unlock() }

        let hour = Calendar.current.component(.hour, from: timestamp)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: timestamp)

        // New hour? Snapshot and generate summary for previous hour
        if lastHour != -1 && hour != lastHour {
            // CRITICAL: Snapshot data BEFORE clearing to prevent race condition
            let snapshotTimeline = hourlyTimeline
            let snapshotUrls = hourlyUrls
            let snapshotStats = hourlyStats
            let snapshotTopics = hourlyTopics
            let snapshotDomains = hourlyDomains
            let previousHour = lastHour

            // Reset hourly tracking immediately
            hourlyTimeline.removeAll()
            hourlyUrls.removeAll()
            hourlyStats.removeAll()
            hourlyTopics.removeAll()
            hourlyDomains.removeAll()

            // Generate summary async with snapshot data (doesn't block captures)
            DispatchQueue.global(qos: .background).async { [weak self] in
                self?.generateHourlySummaryFromSnapshot(
                    hour: previousHour,
                    date: timestamp,
                    timeline: snapshotTimeline,
                    urls: snapshotUrls,
                    stats: snapshotStats,
                    topics: snapshotTopics
                )
            }
        }
        lastHour = hour

        // Extract intents from this capture (what Gokul DID, not pixels)
        let keyContent = extractIntents(from: ocrText, windowTitle: windowTitle, app: app)

        // Only add to timeline if something meaningful changed
        let titleChanged = windowTitle != nil && windowTitle != lastWindowTitle
        let isNewActivity = titleChanged || hourlyTimeline.isEmpty ||
                           (hourlyTimeline.last?.app != app)

        if isNewActivity {
            let activity = ActivityEntry(
                time: timeStr,
                app: app,
                windowTitle: windowTitle,
                url: url,
                keyContent: keyContent
            )
            hourlyTimeline.append(activity)
            dailyTimeline.append(activity)

            // Track key moment if title is interesting
            if let title = windowTitle, title.count > 10 {
                let moment = "\(timeStr) - \(app): \(title)"
                if dailyKeyMoments.count < 100 {
                    dailyKeyMoments.append(moment)
                }
            }
        }

        if let title = windowTitle {
            lastWindowTitle = title
        }

        // Track URL visits and domains
        // Use AppleScript URL if available, otherwise extract from OCR
        let urlsToTrack: [String]
        if let urlStr = url {
            urlsToTrack = [urlStr]
        } else {
            // Fallback: extract URLs from OCR text (AppleScript often fails due to permissions)
            urlsToTrack = extractUrlsFromOCR(ocrText)
        }

        for urlStr in urlsToTrack {
            hourlyUrls.insert(urlStr)
            if var existing = dailyUrlVisits[urlStr] {
                existing.count += 1
                dailyUrlVisits[urlStr] = existing
            } else {
                dailyUrlVisits[urlStr] = (title: windowTitle, firstSeen: timeStr, count: 1)
            }

            // Track domain for aggregated view
            if let domain = extractDomain(from: urlStr) {
                hourlyDomains[domain, default: 0] += 1
                dailyDomains[domain, default: 0] += 1
            }
        }

        // Track time per app (2 seconds per capture)
        hourlyStats[app, default: 0] += 2

        // Track topics
        for content in keyContent {
            hourlyTopics.insert(content)
        }

        // Track projects from window titles and URLs
        let detectedProjects = extractProjects(
            from: [windowTitle],
            urls: url != nil ? [url!] : []
        )
        for project in detectedProjects {
            dailyProjects.insert(project)
        }
    }

    // MARK: - Intent-Based Extraction (CEO-approved: surface what Gokul DID, not pixels)

    private func extractIntents(from text: String, windowTitle: String?, app: String) -> [String] {
        var intents: [String] = []

        // 1. ACTIVE PROJECTS - from IDE/Terminal context
        if let project = extractActiveProject(windowTitle: windowTitle, app: app, ocrText: text) {
            intents.append(project)
        }

        // 2. FILES EDITED - from window titles and OCR patterns
        let files = extractFilesEdited(windowTitle: windowTitle, ocrText: text)
        if !files.isEmpty {
            intents.append("Edited: \(files.prefix(3).joined(separator: ", "))")
        }

        // 3. SEARCHES PERFORMED - from browser search bars
        let searches = extractSearches(app: app, ocrText: text)
        for search in searches.prefix(2) {
            intents.append("Searched: \(search)")
        }

        // 4. KEY ACTIONS - builds, commits, installs
        let actions = extractKeyActions(ocrText: text)
        intents.append(contentsOf: actions.prefix(3))

        return intents
    }

    private func extractActiveProject(windowTitle: String?, app: String, ocrText: String) -> String? {
        let ideApps = ["Xcode", "Visual Studio Code", "Code", "Cursor", "IntelliJ IDEA", "WebStorm", "PyCharm", "Android Studio"]
        let terminalApps = ["Terminal", "iTerm2", "iTerm", "Warp", "Alacritty", "kitty"]

        // IDE: Extract project from window title pattern "file.ext - ProjectName - App"
        if ideApps.contains(where: { app.contains($0) }), let title = windowTitle {
            let parts = title.components(separatedBy: " - ")
            if parts.count >= 2 {
                // Find the project name (usually second to last, before IDE name)
                let projectPart = parts.count >= 3 ? parts[parts.count - 2] : parts[0]
                let fileName = parts[0].trimmingCharacters(in: .whitespaces)

                // Clean project name
                let project = projectPart.trimmingCharacters(in: .whitespaces)
                if !ideApps.contains(where: { project.contains($0) }) && project.count < 50 {
                    return "Working on \(project): \(fileName)"
                }
            }
        }

        // Terminal: Look for project context in OCR
        if terminalApps.contains(where: { app.contains($0) }) {
            // Look for cd commands
            if let cdMatch = ocrText.range(of: #"cd\s+([~/\w.-]+)"#, options: .regularExpression) {
                let path = String(ocrText[cdMatch]).replacingOccurrences(of: "cd ", with: "")
                let projectName = path.components(separatedBy: "/").last ?? path
                return "Working in: \(projectName)"
            }

            // Look for xcodebuild
            if ocrText.contains("xcodebuild") {
                if let schemeMatch = ocrText.range(of: #"-scheme\s+(\w+)"#, options: .regularExpression) {
                    let scheme = String(ocrText[schemeMatch]).replacingOccurrences(of: "-scheme ", with: "")
                    return "Building: \(scheme)"
                }
                return "Building Xcode project"
            }

            // Look for npm/yarn
            if ocrText.contains("npm run") || ocrText.contains("yarn") {
                if let runMatch = ocrText.range(of: #"(npm run|yarn)\s+(\w+)"#, options: .regularExpression) {
                    let script = String(ocrText[runMatch])
                    return "Running: \(script)"
                }
            }

            // Look for Claude Code
            if ocrText.contains("claude") || ocrText.contains("Claude Code") {
                return "Using Claude Code"
            }
        }

        // Xcode: Extract from window title
        if app.contains("Xcode"), let title = windowTitle {
            if title.contains(".xcodeproj") || title.contains(".xcworkspace") {
                let projectName = title.components(separatedBy: ".xc").first ?? title
                return "Working on: \(projectName)"
            }
            // Xcode file view: "FileName.swift — ProjectName"
            if title.contains("—") {
                let parts = title.components(separatedBy: "—")
                if parts.count >= 2 {
                    let project = parts[1].trimmingCharacters(in: .whitespaces)
                    let file = parts[0].trimmingCharacters(in: .whitespaces)
                    return "Working on \(project): \(file)"
                }
            }
        }

        return nil
    }

    private func extractFilesEdited(windowTitle: String?, ocrText: String) -> [String] {
        var files: Set<String> = []

        // Whitelist of real code file extensions (no single-letter ambiguous ones like .c .h)
        let safeExtensions = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "kt",
                              "cpp", "hpp", "css", "scss", "html", "json", "yaml", "yml", "md",
                              "sql", "rb", "vue", "svelte", "astro", "prisma", "graphql"]

        // Pattern that requires at least 2 chars before extension
        let filePattern = #"[\w][\w-]+\.(swift|ts|tsx|js|jsx|py|rs|go|java|kt|cpp|hpp|css|scss|html|json|yaml|yml|md|sql|rb|vue|svelte|astro|prisma|graphql)"#

        // Extract from window title (high confidence)
        if let title = windowTitle {
            if let range = title.range(of: filePattern, options: .regularExpression) {
                let file = String(title[range])
                if isValidSourceFile(file) {
                    files.insert(file)
                }
            }
        }

        // Extract from OCR - look for file operation patterns
        let fileOperationPatterns = [
            #"(?:Read|Edit|Update|Write|Modified|Created|Deleted)(?:\s+file)?:?\s*([\w/.-]+\.(?:swift|ts|tsx|js|py|rs|go|java|json|md|yml))"#,
            #"modified:\s*([\w/.-]+\.(?:swift|ts|tsx|js|py|rs|go|java|json|md|yml))"#,
            #"new file:\s*([\w/.-]+\.(?:swift|ts|tsx|js|py|rs|go|java|json|md|yml))"#,
        ]

        for pattern in fileOperationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(ocrText.startIndex..., in: ocrText)
                let matches = regex.matches(in: ocrText, range: range)
                for match in matches.prefix(5) {
                    if match.numberOfRanges > 1, let fileRange = Range(match.range(at: 1), in: ocrText) {
                        let file = String(ocrText[fileRange])
                        let filename = file.components(separatedBy: "/").last ?? file
                        if isValidSourceFile(filename) {
                            files.insert(filename)
                        }
                    }
                }
            }
        }

        // Also look for simple file mentions in OCR (stricter matching)
        if let regex = try? NSRegularExpression(pattern: filePattern, options: []) {
            let range = NSRange(ocrText.startIndex..., in: ocrText)
            let matches = regex.matches(in: ocrText, range: range)
            for match in matches.prefix(10) {
                if let matchRange = Range(match.range, in: ocrText) {
                    let file = String(ocrText[matchRange])
                    if isValidSourceFile(file) {
                        files.insert(file)
                    }
                }
            }
        }

        return Array(files).sorted()
    }

    /// Filter out OCR garbage that looks like files but isn't
    private func isValidSourceFile(_ filename: String) -> Bool {
        // Must be reasonable length
        guard filename.count >= 3 && filename.count < 60 else { return false }

        // Filter out reverse domain patterns (com.apple.*, org.*, etc.)
        let reverseDomainPrefixes = ["com.", "org.", "net.", "io.", "dev.", "co.", "app.", "eom.", "eo."]
        for prefix in reverseDomainPrefixes {
            if filename.lowercased().hasPrefix(prefix) {
                return false
            }
        }

        // Filter out patterns that look like bundle IDs or process names
        if filename.contains(".apple.") || filename.contains(".google.") || filename.contains(".microsoft.") {
            return false
        }

        // Filter OCR garbage patterns (random short words + extension)
        let garbagePatterns = [
            #"^[a-z]{1,3}\.[a-z]+$"#,           // Single/double letter files like "c.c", "go.ts"
            #"^[A-Z][a-z]{0,2}\.[a-z]+$"#,      // "On.js", "Co.py" - OCR artifacts
            #"mailout|ollabstr|hotmail"#,       // Email/company OCR noise
            #"^Il[a-z]"#,                       // OCR misread of "// " or "| "
        ]

        for pattern in garbagePatterns {
            if filename.range(of: pattern, options: .regularExpression) != nil {
                return false
            }
        }

        // Must have a recognizable code file extension
        let validExtensions = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "kt",
                               "cpp", "hpp", "css", "scss", "html", "json", "yaml", "yml", "md",
                               "sql", "rb", "vue", "svelte", "astro", "prisma", "graphql", "sh"]
        let ext = (filename as NSString).pathExtension.lowercased()
        guard validExtensions.contains(ext) else { return false }

        // Filename before extension should be at least 2 real chars
        let nameWithoutExt = (filename as NSString).deletingPathExtension
        guard nameWithoutExt.count >= 2 else { return false }

        return true
    }

    private func extractSearches(app: String, ocrText: String) -> [String] {
        var searches: [String] = []
        let browserApps = ["Safari", "Google Chrome", "Chrome", "Arc", "Firefox", "Brave", "Edge"]

        guard browserApps.contains(where: { app.contains($0) }) else { return [] }

        // Google search URL pattern
        let googlePattern = #"google\.com/search\?q=([^&\s]+)"#
        if let regex = try? NSRegularExpression(pattern: googlePattern, options: []) {
            let range = NSRange(ocrText.startIndex..., in: ocrText)
            let matches = regex.matches(in: ocrText, range: range)
            for match in matches.prefix(3) {
                if match.numberOfRanges > 1, let queryRange = Range(match.range(at: 1), in: ocrText) {
                    let rawQuery = String(ocrText[queryRange]).replacingOccurrences(of: "+", with: " ")
                    let query = rawQuery.removingPercentEncoding ?? rawQuery
                    if query.count > 2 && query.count < 100 {
                        searches.append(query)
                    }
                }
            }
        }

        // DuckDuckGo pattern
        let ddgPattern = #"duckduckgo\.com/\?q=([^&\s]+)"#
        if let regex = try? NSRegularExpression(pattern: ddgPattern, options: []) {
            let range = NSRange(ocrText.startIndex..., in: ocrText)
            let matches = regex.matches(in: ocrText, range: range)
            for match in matches.prefix(3) {
                if match.numberOfRanges > 1, let queryRange = Range(match.range(at: 1), in: ocrText) {
                    let rawQuery = String(ocrText[queryRange]).replacingOccurrences(of: "+", with: " ")
                    let query = rawQuery.removingPercentEncoding ?? rawQuery
                    if query.count > 2 && query.count < 100 {
                        searches.append(query)
                    }
                }
            }
        }

        // Generic "Search:" pattern in OCR
        let searchLabelPattern = #"Search:?\s+([^\n]{3,50})"#
        if let regex = try? NSRegularExpression(pattern: searchLabelPattern, options: .caseInsensitive) {
            let range = NSRange(ocrText.startIndex..., in: ocrText)
            let matches = regex.matches(in: ocrText, range: range)
            for match in matches.prefix(2) {
                if match.numberOfRanges > 1, let queryRange = Range(match.range(at: 1), in: ocrText) {
                    let query = String(ocrText[queryRange]).trimmingCharacters(in: .whitespaces)
                    if query.count > 2 && !searches.contains(query) {
                        searches.append(query)
                    }
                }
            }
        }

        return searches
    }

    private func extractKeyActions(ocrText: String) -> [String] {
        var actions: [String] = []

        // Build outcomes
        if ocrText.contains("Build Succeeded") || ocrText.contains("BUILD SUCCEEDED") {
            actions.append("Build succeeded")
        }
        if ocrText.contains("Build Failed") || ocrText.contains("BUILD FAILED") {
            actions.append("Build failed")
        }
        if let match = ocrText.range(of: #"Compiled \d+ (files?|source files?)"#, options: .regularExpression) {
            actions.append(String(ocrText[match]))
        }

        // Git operations
        if ocrText.contains("git commit") || ocrText.range(of: #"\[[\w-]+\s+[\w\d]+\]"#, options: .regularExpression) != nil {
            // Try to extract commit message
            if let msgMatch = ocrText.range(of: #"-m [\"']([^\"']+)[\"']"#, options: .regularExpression) {
                let msg = String(ocrText[msgMatch])
                    .replacingOccurrences(of: "-m ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if msg.count < 80 {
                    actions.append("Committed: \(msg.prefix(50))")
                }
            } else {
                actions.append("Git commit")
            }
        }
        if ocrText.contains("git push") || ocrText.contains("pushed to") {
            actions.append("Pushed to remote")
        }
        if ocrText.contains("git pull") || ocrText.contains("Already up to date") {
            actions.append("Git pull")
        }

        // Install operations
        if ocrText.contains("installed to /Applications") || ocrText.contains("Successfully installed") {
            actions.append("Installed application")
        }
        if ocrText.contains("npm install") || ocrText.contains("yarn add") {
            actions.append("Installed dependencies")
        }

        // Test outcomes
        if ocrText.contains("Tests Passed") || ocrText.contains("All tests passed") {
            actions.append("Tests passed")
        }
        if ocrText.contains("Test Failed") || ocrText.contains("FAILED") && ocrText.contains("test") {
            actions.append("Tests failed")
        }

        // Deploy operations
        if ocrText.contains("deployed to") || ocrText.contains("Deployment successful") {
            actions.append("Deployed")
        }

        // Download/upload
        if ocrText.contains("Download complete") || ocrText.contains("Downloaded") {
            actions.append("Downloaded file")
        }

        return actions
    }

    /// Extract URLs from OCR text as fallback when AppleScript fails (permission issues)
    /// Looks for: full URLs, search URLs with queries, common domains
    private func extractUrlsFromOCR(_ ocrText: String) -> [String] {
        var urls: Set<String> = []

        // Full URL pattern (https:// or http://)
        let fullUrlPattern = #"https?://[^\s\"\'\<\>\)\]\}]+"#
        if let regex = try? NSRegularExpression(pattern: fullUrlPattern, options: []) {
            let range = NSRange(ocrText.startIndex..., in: ocrText)
            let matches = regex.matches(in: ocrText, range: range)
            for match in matches.prefix(10) {
                if let matchRange = Range(match.range, in: ocrText) {
                    var url = String(ocrText[matchRange])
                    // Clean trailing punctuation
                    while url.hasSuffix(".") || url.hasSuffix(",") || url.hasSuffix(":") {
                        url = String(url.dropLast())
                    }
                    if url.count > 10 && url.count < 500 && isValidUrl(url) {
                        urls.insert(url)
                    }
                }
            }
        }

        // Domain patterns commonly seen in browser OCR (without protocol)
        // These often appear in Safari's address bar
        let domainPattern = #"(?:^|\s)((?:[\w-]+\.)+(?:com|org|net|io|dev|ai|co|app|me|tv|edu|gov)(?:/[^\s]*)?)"#
        if let regex = try? NSRegularExpression(pattern: domainPattern, options: .caseInsensitive) {
            let range = NSRange(ocrText.startIndex..., in: ocrText)
            let matches = regex.matches(in: ocrText, range: range)
            for match in matches.prefix(5) {
                if match.numberOfRanges > 1, let domainRange = Range(match.range(at: 1), in: ocrText) {
                    var domain = String(ocrText[domainRange])
                    // Clean trailing punctuation
                    while domain.hasSuffix(".") || domain.hasSuffix(",") {
                        domain = String(domain.dropLast())
                    }
                    let url = "https://\(domain)"
                    if domain.count > 5 && domain.count < 200 && isValidUrl(url) {
                        urls.insert(url)
                    }
                }
            }
        }

        return Array(urls).sorted()
    }

    /// Filter out OCR garbage that looks like URLs but isn't
    private func isValidUrl(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host else { return false }
        let lowerHost = host.lowercased()

        // Filter out reverse domain OCR noise (com.apple.*, eom.apple.*, etc.)
        let reverseDomainPrefixes = ["com.", "org.", "net.", "io.", "dev.", "co.", "app.", "eom.", "eo."]
        for prefix in reverseDomainPrefixes {
            if lowerHost.hasPrefix(prefix) && lowerHost.contains(".apple") {
                return false
            }
        }

        // Filter out system bundle ID patterns
        if lowerHost.hasPrefix("com.") || lowerHost.hasPrefix("org.") || lowerHost.hasPrefix("eom.") {
            return false
        }

        // Filter out short nonsense domains (OCR typos)
        // These are often OCR misreads: "sereen.dev", "logger.de", "parts.app"
        let domainParts = lowerHost.components(separatedBy: ".")
        if let firstPart = domainParts.first {
            // Very short first part is suspicious unless it's a known site
            let knownShortDomains = ["x", "t", "fb", "g", "yt", "ok", "vk", "wa", "me", "be", "go", "so", "is"]
            if firstPart.count <= 2 && !knownShortDomains.contains(firstPart) {
                return false
            }
        }

        // Filter out common OCR garbage patterns
        let garbagePatterns = [
            "apple.co", "apple.me",           // OCR of com.apple.*
            "logger.de", "sereen.dev",        // Known typos
            "intents.app", "parts.app",       // macOS process names
            "shared.fr", "frame.c",           // OCR noise
            "httpjlwww", "httpllwww",         // OCR misread of http://www
        ]
        for pattern in garbagePatterns {
            if lowerHost.contains(pattern) || urlString.lowercased().contains(pattern) {
                return false
            }
        }

        // Must have a proper TLD structure (at least x.y format)
        if domainParts.count < 2 {
            return false
        }

        return true
    }

    // MARK: - Enhanced Analysis

    private func extractDomain(from url: String) -> String? {
        guard let urlObj = URL(string: url),
              let host = urlObj.host else { return nil }
        // Remove www. prefix for cleaner grouping
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func extractProjects(from windowTitles: [String?], urls: [String]) -> [String] {
        var projects: Set<String> = []

        // Extract from window titles (look for common patterns)
        for title in windowTitles.compactMap({ $0 }) {
            // Git repo pattern: "folder - app" or "repo/file"
            if title.contains("/") {
                let parts = title.components(separatedBy: "/")
                if let first = parts.first, first.count > 2 && first.count < 30 {
                    let cleaned = first.trimmingCharacters(in: .whitespaces)
                    if !cleaned.contains(" ") || cleaned.contains("-") {
                        projects.insert(cleaned)
                    }
                }
            }

            // VS Code / IDE pattern: "filename - ProjectName"
            if title.contains(" - ") {
                let parts = title.components(separatedBy: " - ")
                if parts.count >= 2 {
                    let projectPart = parts.last ?? ""
                    // Filter out app names
                    let appNames = ["Visual Studio Code", "Xcode", "Cursor", "IntelliJ", "WebStorm", "PyCharm"]
                    if !appNames.contains(where: { projectPart.contains($0) }) && projectPart.count < 40 {
                        projects.insert(projectPart.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }

        // Extract from GitHub/GitLab URLs
        for url in urls {
            if url.contains("github.com") || url.contains("gitlab.com") {
                if let urlObj = URL(string: url) {
                    let pathParts = urlObj.path.components(separatedBy: "/").filter { !$0.isEmpty }
                    if pathParts.count >= 2 {
                        projects.insert("\(pathParts[0])/\(pathParts[1])")
                    }
                }
            }
        }

        return Array(projects).sorted()
    }

    private func generateWorkingSummary(apps: [String: Int], topics: [String], urls: [String]) -> String {
        var parts: [String] = []

        // Top apps by time
        let topApps = apps.sorted { $0.value > $1.value }.prefix(3)
        if !topApps.isEmpty {
            let appList = topApps.map { "\($0.key) (\($0.value) min)" }.joined(separator: ", ")
            parts.append("Used \(appList)")
        }

        // Categorize activity
        let browserApps = ["Safari", "Google Chrome", "Arc", "Firefox", "Brave Browser"]
        let devApps = ["Xcode", "Visual Studio Code", "Cursor", "Terminal", "iTerm2", "IntelliJ IDEA"]
        let commApps = ["Slack", "Discord", "Messages", "Mail", "Microsoft Teams", "Zoom"]

        let browserTime = apps.filter { browserApps.contains($0.key) }.values.reduce(0, +)
        let devTime = apps.filter { devApps.contains($0.key) }.values.reduce(0, +)
        let commTime = apps.filter { commApps.contains($0.key) }.values.reduce(0, +)

        if devTime > 10 {
            parts.append("coding/development")
        }
        if browserTime > 10 {
            parts.append("browsing/research")
        }
        if commTime > 5 {
            parts.append("communication")
        }

        // Add key topics
        let relevantTopics = topics.prefix(3)
        if !relevantTopics.isEmpty {
            parts.append("Topics: \(relevantTopics.joined(separator: ", "))")
        }

        // Domain summary
        let domains = urls.compactMap { extractDomain(from: $0) }
        let domainCounts = Dictionary(grouping: domains, by: { $0 }).mapValues { $0.count }
        let topDomains = domainCounts.sorted { $0.value > $1.value }.prefix(3)
        if !topDomains.isEmpty {
            let domainList = topDomains.map { $0.key }.joined(separator: ", ")
            parts.append("Sites: \(domainList)")
        }

        return parts.isEmpty ? "Light activity" : parts.joined(separator: ". ")
    }

    private func generateDaySummary(apps: [String: Int], urls: [URLVisit], projects: [String], moments: [String]) -> String {
        var parts: [String] = []

        // Total active time
        let totalMinutes = apps.values.reduce(0, +)
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        if hours > 0 {
            parts.append("Active for \(hours)h \(mins)m")
        } else if mins > 0 {
            parts.append("Active for \(mins) minutes")
        }

        // Main activities
        let topApps = apps.sorted { $0.value > $1.value }.prefix(3)
        if !topApps.isEmpty {
            let appList = topApps.map { $0.key }.joined(separator: ", ")
            parts.append("mainly in \(appList)")
        }

        // Projects
        if !projects.isEmpty {
            let projectList = projects.prefix(3).joined(separator: ", ")
            parts.append("Worked on: \(projectList)")
        }

        // Top sites
        let topUrls = urls.prefix(3)
        if !topUrls.isEmpty {
            let sites = topUrls.compactMap { extractDomain(from: $0.url) }.joined(separator: ", ")
            if !sites.isEmpty {
                parts.append("Visited: \(sites)")
            }
        }

        // Key moments
        if !moments.isEmpty {
            parts.append("Notable: \(moments.prefix(2).joined(separator: "; "))")
        }

        return parts.isEmpty ? "No significant activity recorded" : parts.joined(separator: ". ")
    }

    // MARK: - Summary Generation (Thread-Safe)

    private func generateHourlySummaryFromSnapshot(
        hour: Int,
        date: Date,
        timeline: [ActivityEntry],
        urls: Set<String>,
        stats: [String: Int],
        topics: Set<String>
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dayFolder = formatter.string(from: date)
        let dayDir = exportBaseDir.appendingPathComponent(dayFolder)

        // Create directory with proper error handling
        do {
            try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create day directory \(dayFolder): \(error.localizedDescription)")
            return
        }

        let hourStr = String(format: "%02d:00", hour)

        // Fix integer division: ensure at least 1 minute if any time was recorded
        let appsUsedMinutes = stats.mapValues { seconds in
            let minutes = seconds / 60
            return minutes > 0 ? minutes : (seconds > 0 ? 1 : 0)
        }

        // Calculate domain visits
        let urlArray = Array(urls)
        var domainCounts: [String: Int] = [:]
        for url in urlArray {
            if let domain = extractDomain(from: url) {
                domainCounts[domain, default: 0] += 1
            }
        }

        // Generate working summary
        let workingSummary = generateWorkingSummary(
            apps: appsUsedMinutes,
            topics: Array(topics),
            urls: urlArray
        )

        let summary = HourlySummary(
            hour: hourStr,
            date: dayFolder,
            timeline: timeline,
            urlsVisited: urlArray,
            appsUsed: appsUsedMinutes,
            keyTopics: Array(topics.prefix(30)),
            workingSummary: workingSummary,
            domains: domainCounts
        )

        let filename = "hour-\(String(format: "%02d", hour))-summary.json"
        let filePath = dayDir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(summary)
            try data.write(to: filePath)
            logger.info("Saved hourly summary: \(filename)")
        } catch {
            logger.error("Failed to save hourly summary \(filename): \(error.localizedDescription)")
        }
    }

    private func generateHourlySummary(hour: Int, date: Date) {
        // Use current data (called when not using snapshot approach)
        generateHourlySummaryFromSnapshot(
            hour: hour,
            date: date,
            timeline: hourlyTimeline,
            urls: hourlyUrls,
            stats: hourlyStats,
            topics: hourlyTopics
        )
    }

    private func generateDailyJournal(for date: String) {
        dataLock.lock()
        // Snapshot daily data to prevent race condition
        let snapshotTimeline = dailyTimeline
        let snapshotUrlVisits = dailyUrlVisits
        let snapshotKeyMoments = dailyKeyMoments
        let snapshotStats = dailyStats
        let snapshotProjects = Array(dailyProjects)
        let snapshotDomains = dailyDomains

        // Reset daily tracking immediately
        dailyTimeline.removeAll()
        dailyUrlVisits.removeAll()
        dailyKeyMoments.removeAll()
        dailyProjects.removeAll()
        dailyDomains.removeAll()
        dataLock.unlock()

        let dayDir = exportBaseDir.appendingPathComponent(date)

        // Create directory with proper error handling
        do {
            try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create daily journal directory \(date): \(error.localizedDescription)")
            return
        }

        // Convert URL visits to array
        let urlVisits = snapshotUrlVisits.map { (url, info) in
            URLVisit(url: url, title: info.title, firstSeen: info.firstSeen, visitCount: info.count)
        }.sorted { $0.visitCount > $1.visitCount }

        // Fix integer division: captures * 2 / 60 → ensure at least 1 minute
        let appSummaryMinutes = snapshotStats.mapValues { captures in
            let seconds = captures * 2
            let minutes = seconds / 60
            return minutes > 0 ? minutes : (seconds > 0 ? 1 : 0)
        }

        // Generate day summary blurb
        let daySummary = generateDaySummary(
            apps: appSummaryMinutes,
            urls: urlVisits,
            projects: snapshotProjects,
            moments: snapshotKeyMoments
        )

        // Top domains sorted by visit count
        let topDomains = snapshotDomains.sorted { $0.value > $1.value }
            .prefix(10)
            .reduce(into: [String: Int]()) { $0[$1.key] = $1.value }

        let journal = DailyJournal(
            date: date,
            timeline: snapshotTimeline,
            allUrls: urlVisits,
            appSummary: appSummaryMinutes,
            keyMoments: snapshotKeyMoments,
            daySummary: daySummary,
            topDomains: topDomains,
            projectsWorkedOn: snapshotProjects
        )

        let filename = "\(date)-journal.json"
        let filePath = dayDir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(journal)
            try data.write(to: filePath)
            logger.info("Saved daily journal: \(filename)")
        } catch {
            logger.error("Failed to save daily journal \(filename): \(error.localizedDescription)")
        }
    }

    // MARK: - Export to Markdown

    func exportCapture(timestamp: Date, appName: String?, ocrText: String, frameId: Int64) {
        // Clean the OCR text first
        let cleanedText = cleanOcrText(ocrText)

        // Skip if no meaningful content
        guard hasMinimumContent(cleanedText) else { return }

        // Skip duplicates
        guard !isDuplicate(ocrText: cleanedText, appName: appName) else { return }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayFolder = dateFormatter.string(from: timestamp)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"
        let timeString = timeFormatter.string(from: timestamp)

        let dayDir = exportBaseDir.appendingPathComponent(dayFolder)

        // Create directory with proper error handling
        do {
            try fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create export directory \(dayFolder): \(error.localizedDescription)")
            return
        }

        // Get window title and URL
        let windowTitle = getWindowTitle(for: appName)
        let url = getBrowserURL(for: appName)

        // Update session tracking
        let app = appName ?? "Unknown"
        let (sessionId, sessionDuration) = updateSession(app: app, timestamp: timestamp)

        // Track activity for perfect recall summaries
        trackActivity(app: app, windowTitle: windowTitle, url: url, ocrText: cleanedText, timestamp: timestamp)

        // Build markdown with YAML frontmatter
        let safeAppName = app
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(30)

        let filename = "\(timeString)_\(safeAppName).md"
        let filePath = dayDir.appendingPathComponent(filename)

        // Build YAML frontmatter
        var frontmatter = """
            ---
            timestamp: \(timestamp.ISO8601Format())
            app: \(app)
            frame_id: \(frameId)
            """

        // Add optional fields
        if let windowTitle = windowTitle, !windowTitle.isEmpty {
            // Escape quotes in window title for YAML
            let escapedTitle = windowTitle.replacingOccurrences(of: "\"", with: "\\\"")
            frontmatter += "\nwindow_title: \"\(escapedTitle)\""
        }

        if let url = url, !url.isEmpty {
            frontmatter += "\nurl: \(url)"
        }

        if let sessionId = sessionId {
            frontmatter += "\nsession_id: \(sessionId)"
        }

        if let sessionDuration = sessionDuration {
            frontmatter += "\nsession_duration: \(sessionDuration)"
        }

        frontmatter += "\n---"

        // Combine frontmatter and OCR text
        let markdown = "\(frontmatter)\n\n\(cleanedText)"

        do {
            try markdown.write(to: filePath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to save capture \(filename): \(error.localizedDescription)")
        }

        // Track stats for daily digest
        trackStats(app: appName, url: url, date: dayFolder)

        // Generate journal and digest if day changed
        if dayFolder != lastDigestDate && !lastDigestDate.isEmpty {
            generateDailyJournal(for: lastDigestDate)
            generateDigest(for: lastDigestDate)
        }
        lastDigestDate = dayFolder
    }

    // MARK: - Stats Tracking

    private func trackStats(app: String?, url: String?, date: String) {
        if let appName = app {
            dailyStats[appName, default: 0] += 1
        }
        if let urlString = url, let host = URL(string: urlString)?.host {
            dailyUrls[host, default: 0] += 1
        }
    }

    // MARK: - Daily Digest

    func generateDigest(for date: String) {
        let dayDir = exportBaseDir.appendingPathComponent(date)

        // Count files and calculate time (2 sec per capture)
        var appTimes: [String: [String: Any]] = [:]
        for (app, count) in dailyStats {
            appTimes[app] = [
                "captures": count,
                "minutes": count * 2 / 60  // 2 seconds per capture
            ]
        }

        // Top URLs
        let topUrls = dailyUrls.sorted { $0.value > $1.value }.prefix(20).map { ["url": $0.key, "visits": $0.value] }

        let digest: [String: Any] = [
            "date": date,
            "total_captures": dailyStats.values.reduce(0, +),
            "apps": appTimes,
            "top_urls": topUrls
        ]

        let digestPath = dayDir.appendingPathComponent("\(date)-digest.json")

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: digest, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: digestPath)
            logger.info("Saved digest: \(date)-digest.json")
        } catch {
            logger.error("Failed to save digest for \(date): \(error.localizedDescription)")
        }

        // Reset stats for new day
        dailyStats.removeAll()
        dailyUrls.removeAll()
    }

    // MARK: - Cleanup

    func performCleanup() {
        cleanupOldVideos()
        // Generate digest for today if needed
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        let todayStr = today.string(from: Date())
        if !dailyStats.isEmpty {
            generateDigest(for: todayStr)
        }
    }

    private func cleanupOldVideos() {
        guard videoRetentionHours > 0 else { return }

        guard let cutoffDate = Calendar.current.date(byAdding: .hour, value: -videoRetentionHours, to: Date()) else {
            logger.error("Failed to calculate cutoff date for video cleanup")
            return
        }

        guard let saveDir = RemFileManager.shared.getSaveDir() else {
            logger.warning("No save directory available for video cleanup")
            return
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: [.creationDateKey])
            var deletedCount = 0

            for file in files where file.pathExtension == "mp4" {
                do {
                    let attrs = try fileManager.attributesOfItem(atPath: file.path)
                    if let creationDate = attrs[.creationDate] as? Date, creationDate < cutoffDate {
                        try fileManager.removeItem(at: file)
                        deletedCount += 1
                        logger.debug("Deleted old video: \(file.lastPathComponent)")
                    }
                } catch {
                    logger.warning("Failed to process video file \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }

            if deletedCount > 0 {
                logger.info("Video cleanup completed: \(deletedCount) files removed")
            }
        } catch {
            logger.error("Video cleanup error: \(error.localizedDescription)")
        }
    }

    func getExportDir() -> URL { return exportBaseDir }
}
import CoreGraphics
import os
import ScreenCaptureKit
import ScriptingBridge
import SwiftUI
import Vision
import VisionKit

final class MainWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
}

enum CaptureState {
    case recording
    case stopped
    case paused
}

@main
struct remApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Empty scene - settings are opened via menu bar
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AppDelegate.self)
    )
    
    var imageAnalyzer = ImageAnalyzer()
    var timelineViewWindow: NSWindow?
    var timelineView: TimelineView?
    
    var settingsManager = SettingsManager()
    var settingsViewWindow: NSWindow?

    var statusBarItem: NSStatusItem!
    var popover: NSPopover!
    
    var searchViewWindow: NSWindow?
    var searchView: SearchView?

    var lastCaptureTime = Date()
    
    var screenCaptureSession: SCStream?
    var captureOutputURL: URL?
    
    var lastVideoEncodingTime = Date()
    
    let idleStatusImage = NSImage(named: "StatusIdle")
    let recordingStatusImage = NSImage(named: "StatusRecording")
    let idleStatusImageDark = NSImage(named: "StatusIdleDark")
    let recordingStatusImageDark = NSImage(named: "StatusRecordingDark")
    
    let ocrQueue = DispatchQueue(label: "today.jason.ocrQueue", attributes: .concurrent)
    var imageBufferQueue = DispatchQueue(label: "today.jason.imageBufferQueue", attributes: .concurrent)
    var imageDataBuffer = [Data]()
    
    var ffmpegTimer: Timer?
    var screenshotTimer: Timer?
        
    private let frameThreshold = 30 // Number of frames after which FFmpeg processing is triggered
    private var ffmpegProcess: Process?
    private var ffmpegInputPipe: Pipe?
    
    private var pendingScreenshotURLs = [URL]()
    
    private var isCapturing: CaptureState = .stopped
    private let screenshotQueue = DispatchQueue(label: "today.jason.screenshotQueue")
    
    private var wasRecordingBeforeSleep: Bool = false
    private var wasRecordingBeforeTimelineView: Bool = false
    private var wasRecordingBeforeSearchView: Bool = false
    
    private var lastImageData: Data? = nil
    private var lastActiveApplication: String? = nil
    private var lastDisplayID: UInt32? = nil
    private var screenCaptureRetries: Int = 0
    
    
    private var imageResizer = ImageResizer(
        targetWidth: Int(NSScreen.main!.frame.width * NSScreen.main!.backingScaleFactor),
        targetHeight: Int(NSScreen.main!.frame.height * NSScreen.main!.backingScaleFactor)
    )

    // Event monitors - stored so we can remove them later to prevent memory leaks
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    // Screenshot scheduling - track work item for proper cancellation
    private var screenshotWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let _ = DatabaseManager.shared

        // Initialize the popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 360)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView())

        // Create the status bar item
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Setup Menu
        setupMenu()
        
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if (self?.searchViewWindow?.isVisible ?? false) && event.keyCode == 53 {
                DispatchQueue.main.async { [weak self] in
                    self?.closeSearchView()
                }
            }

            if (self?.isTimelineOpen() ?? false) && event.keyCode == 53 {
                DispatchQueue.main.async { [weak self] in
                    self?.closeTimelineView()
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 3 {
                DispatchQueue.main.async { [weak self] in
                    self?.closeTimelineView()
                    self?.showSearchView()
                }
            }

            if (self?.searchViewWindow?.isVisible ?? false) && event.keyCode == 53 {
                DispatchQueue.main.async { [weak self] in
                    self?.closeSearchView()
                }
            }

            if (self?.isTimelineOpen() ?? false) && event.keyCode == 53 {
                DispatchQueue.main.async { [weak self] in
                    self?.closeTimelineView()
                }
            }
            return event
        }

        // Initialize the search view
        searchView = SearchView(onThumbnailClick: openFullView)
        observeSystemNotifications()

        // Schedule cleanup every hour (delete old videos/images)
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            DataExporter.shared.performCleanup()
        }
        // Run cleanup once on launch
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) {
            DataExporter.shared.performCleanup()
        }

        // Auto-start remembering on launch (no user action needed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.enableRecording()
        }
    }

func drawStatusBarIcon(rect: CGRect) -> Bool {
    // More robust dark mode detection
    let isDarkMode = self.statusBarItem.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

    // Icon logic: normal icon when ON/recording, crossed-out when OFF/idle
    let icon = self.isCapturing == .recording ? (
        isDarkMode ? self.idleStatusImageDark : self.idleStatusImage
    ) : (
        isDarkMode ? self.recordingStatusImageDark : self.recordingStatusImage
    )

    icon?.draw(in: rect)

    return true
}
    
    func setupMenu() {
        DispatchQueue.main.async {
            if let button = self.statusBarItem.button {
                button.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { [weak self] rect in
                    return self?.drawStatusBarIcon(rect: rect) ?? false
                }
                button.action = #selector(self.togglePopover(_:))
            }
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings", action: #selector(self.openSettings), keyEquivalent: ",")
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(self.quitApp), keyEquivalent: "q"))
            self.statusBarItem.menu = menu
        }
    }
    
    @objc func showMeMyData() {
        if let saveDir = RemFileManager.shared.getSaveDir() {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: saveDir.path)
        }
    }

    @objc func toggleTimeline() {
        if isTimelineOpen() {
            closeTimelineView()
        } else {
            let frame = DatabaseManager.shared.getMaxChunksFramesIndex()
            showTimelineView(with: frame)
        }
    }
    
    @objc func openSettings() {
        // Update recording state before showing settings
        settingsManager.updateRecordingState(isCapturing == .recording)

        if settingsViewWindow == nil {
            let settingsView = SettingsView(
                settingsManager: settingsManager,
                onToggleRecording: { [weak self] in
                    guard let self = self else { return }
                    if self.isCapturing == .recording {
                        self.userDisableRecording()
                    } else {
                        self.enableRecording()
                    }
                    self.settingsManager.updateRecordingState(self.isCapturing == .recording)
                },
                onShowData: { [weak self] in
                    self?.showMeMyData()
                },
                onPurgeData: { [weak self] in
                    self?.forgetEverything()
                }
            )
            settingsViewWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsViewWindow?.isReleasedWhenClosed = false
            settingsViewWindow?.center()
            settingsViewWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsViewWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                self.settingsViewWindow?.orderFrontRegardless()
            }
        } else {
            // Update the content view with fresh state
            let settingsView = SettingsView(
                settingsManager: settingsManager,
                onToggleRecording: { [weak self] in
                    guard let self = self else { return }
                    if self.isCapturing == .recording {
                        self.userDisableRecording()
                    } else {
                        self.enableRecording()
                    }
                    self.settingsManager.updateRecordingState(self.isCapturing == .recording)
                },
                onShowData: { [weak self] in
                    self?.showMeMyData()
                },
                onPurgeData: { [weak self] in
                    self?.forgetEverything()
                }
            )
            settingsViewWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsViewWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                self.settingsViewWindow?.orderFrontRegardless()
            }
        }
    }
    
    @objc func confirmPurgeAllData() {
        let alert = NSAlert()
        alert.messageText = "Purge all data?"
        alert.informativeText = "This is a permanent action and will delete everything rem has every seen."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Yes, delete everything")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            alert.window.close()
            forgetEverything()
        } else {
            alert.window.close()
        }
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusBarItem.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
            }
        }
    }
    
    private func observeSystemNotifications() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    @objc private func systemWillSleep() {
        logger.info("Detected sleep!")
        // Logic to handle system going to sleep
        wasRecordingBeforeSleep = (isCapturing == .recording)
        if wasRecordingBeforeSleep {
            pauseRecording()
        }
    }

    @objc private func systemDidWake() {
        logger.info("Detected wake!")
        // Logic to handle system wake up
        if wasRecordingBeforeSleep {
            enableRecording()
        }
    }

    func startScreenCapture() async {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            setupMenu()
            screenshotQueue.async { [weak self] in
                self?.scheduleScreenshot(shareableContent: shareableContent)
            }
        } catch {
            logger.error("Error starting screen capture: \(error.localizedDescription)")
        }
    }
    
    @objc private func copyRecentContext() {
        let texts = DatabaseManager.shared.getRecentTextContext()
        let text = TextMerger.shared.mergeTexts(texts: texts)
        ClipboardManager.shared.replaceClipboardContents(with: text)
    }
    
    private func displayImageChangedFromLast(imageData: Data) -> Bool {
        if let prevImage = lastImageData {
            return prevImage.withUnsafeBytes { ptr1 in
                imageData.withUnsafeBytes { ptr2 in
                    memcmp(ptr1.baseAddress, ptr2.baseAddress, imageData.count) != 0
                }
            }
        }
        return false
    }
    
    private func retryScreenCapture() {
        if screenCaptureRetries < 3 {
            screenCaptureRetries += 1
            Task {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                await startScreenCapture()
            }
        } else {
            disableRecording()
            screenCaptureRetries = 0
        }
    }

    private func scheduleScreenshot(shareableContent: SCShareableContent) {
        Task {
            do {
                guard isCapturing == .recording else {
                    logger.debug("Stopped Recording")
                    return }
                
                var displayID: CGDirectDisplayID? = nil
                if let screenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    displayID = CGDirectDisplayID(screenID.uint32Value)
                    logger.debug("Active Display ID: \(displayID ?? 999)")
                }
                
                guard displayID != nil else {
                    logger.debug("DisplayID is nil")
                    retryScreenCapture()
                    return
                }
                
                guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
                    logger.debug("Display could not be retrieved")
                    retryScreenCapture()
                    return
                }
                
                let activeApplicationName = NSWorkspace.shared.frontmostApplication?.localizedName
                
                logger.debug("Active Application: \(activeApplicationName ?? "<undefined>")")
                
                // Do we want to record the timeline being searched?
                guard let image = CGDisplayCreateImage(display.displayID) else {
                    logger.error("Failed to create a screenshot for the display!")
                    return
                }
                guard let resizedImage = imageResizer.resizeAndPad(image: image) else {
                    logger.error("Failed to resize the image!")
                    return
                }
                
                let bitmapRep = NSBitmapImageRep(cgImage: resizedImage)
                guard let imageData = bitmapRep.representation(using: .png, properties: [:]) else {
                    logger.error("Failed to create a PNG from the screenshot!")
                    return
                }
                
                // Might as well only check if the applications are the same, otherwise obviously different
                if activeApplicationName != lastActiveApplication || lastDisplayID != displayID || displayImageChangedFromLast(imageData: imageData) {
                    lastImageData = imageData;
                    lastActiveApplication = activeApplicationName;
                    lastDisplayID = displayID;
                    
                    let frameId = DatabaseManager.shared.insertFrame(activeApplicationName: activeApplicationName)
                    
                    if settingsManager.settings.onlyOCRFrontmostWindow && displayID == CGMainDisplayID() {
                        // default: User wants to perform OCR on only active window.
                        
                        // We need to determine the scale factor for cropping.  CGImage is
                        // measured in pixels, display sizes are measured in points.
                        let scale = max(CGFloat(image.width) / CGFloat(display.width), CGFloat(image.height) / CGFloat(display.height))
                        
                        if
                            let window = shareableContent.windows.first(where: { $0.isOnScreen && $0.owningApplication?.processID == NSWorkspace.shared.frontmostApplication?.processIdentifier }),
                            let cropped = ImageHelper.cropImage(image: image, frame: window.frame, scale: scale)
                        {
                            self.performOCR(frameId: frameId, on: cropped)
                        }
                    } else {
                        // User wants to perform OCR on full display.
                        self.performOCR(frameId: frameId, on: image)
                    }
                    
                    await processScreenshot(frameId: frameId, imageData: imageData, frame: display.frame)
                } else {
                    logger.info("Screen didn't change! Not processing frame.")
                }
            } catch {
                logger.error("Error taking screenshot: \(error)")
            }
            
            screenCaptureRetries = 0

            // Use cancellable work item for proper cleanup when stopping
            screenshotWorkItem?.cancel()
            screenshotWorkItem = DispatchWorkItem { [weak self] in
                self?.scheduleScreenshot(shareableContent: shareableContent)
            }
            if let workItem = screenshotWorkItem {
                screenshotQueue.asyncAfter(deadline: .now() + 2, execute: workItem)
            }
        }
    }
    
    @objc func forgetEverything() {
        if let savedir = RemFileManager.shared.getSaveDir() {
            if FileManager.default.fileExists(atPath: savedir.path) {
                do {
                    try FileManager.default.subpathsOfDirectory(atPath: savedir.path).forEach { path in
                        if !path.hasSuffix(".sqlite3") {
                            let fileToDelete = savedir.appendingPathComponent(path)
                            try FileManager.default.removeItem(at: fileToDelete)
                        }
                    }
                } catch {
                    logger.error("Error deleting folder: \(error)")
                }
            } else {
                logger.error("Error finding folder.")
            }
        }
        DatabaseManager.shared.purge()
    }
    
    func stopScreenCapture() {
        isCapturing = .stopped
        // Cancel any pending screenshot work to stop the recursive loop
        screenshotWorkItem?.cancel()
        screenshotWorkItem = nil
        logger.info("Screen capture stopped")
    }
    
    func pauseScreenCapture() {
        isCapturing = .paused
        logger.info("Screen capture paused")
    }
    
//    // Old method
//    func takeScreenshot(filter: SCContentFilter, configuration: SCStreamConfiguration, frame: CGRect) async {
//        do {
//            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
//            await processScreenshot(image: image, frame: frame)
//        } catch {
//            print("Error taking screenshot: \(error.localizedDescription)")
//        }
//    }
    
    private func processScreenshot(frameId: Int64, imageData: Data, frame: CGRect) async {
        imageBufferQueue.async(flags: .barrier) { [weak self] in
            guard let strongSelf = self else { return }

            // CRITICAL: Add buffer limit to prevent unbounded memory growth
            // Each frame is ~5MB, so 100 frames = ~500MB max buffer
            let maxBufferSize = 100
            if strongSelf.imageDataBuffer.count >= maxBufferSize {
                strongSelf.logger.warning("Image buffer full (\(strongSelf.imageDataBuffer.count) frames), dropping oldest frame")
                strongSelf.imageDataBuffer.removeFirst()
            }

            strongSelf.imageDataBuffer.append(imageData)

            // Quickly move the images to a temporary buffer if the threshold is reached
            var tempBuffer: [Data] = []
            if strongSelf.imageDataBuffer.count >= strongSelf.frameThreshold {
                tempBuffer = Array(strongSelf.imageDataBuffer.prefix(strongSelf.frameThreshold))
                strongSelf.imageDataBuffer.removeFirst(strongSelf.frameThreshold)
            }

            // Process the images outside of the critical section
            if !tempBuffer.isEmpty {
                strongSelf.processChunk(tempBuffer)
            }
        }
    }
    
    private func processChunk(_ chunk: [Data]) {
        // Create a unique output file for each chunk
        if let savedir = RemFileManager.shared.getSaveDir() {
            let outputPath = savedir.appendingPathComponent("output-\(Date().timeIntervalSince1970).mp4").path
            
            // Setup the FFmpeg process for the chunk
            let ffmpegProcess = Process()
            let bundleURL = Bundle.main.bundleURL
            ffmpegProcess.executableURL = bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg")
            ffmpegProcess.arguments = [
                "-f", "image2pipe",
                "-vcodec", "png",
                "-i", "-",
                "-power_efficient", "1",
                "-color_trc", "iec61966_2_1", // Set transfer characteristics for sRGB (approximates 2.2 gamma)
                "-c:v", "h264_videotoolbox",
                "-q:v", "25",
                outputPath
            ]
            let ffmpegInputPipe = Pipe()
            ffmpegProcess.standardInput = ffmpegInputPipe
            
            // Ignore SIGPIPE
            signal(SIGPIPE, SIG_IGN)
            
            // Setup logging for FFmpeg's output
            let ffmpegOutputPipe = Pipe()
            let ffmpegErrorPipe = Pipe()
            ffmpegProcess.standardOutput = ffmpegOutputPipe
            ffmpegProcess.standardError = ffmpegErrorPipe

            // Start the FFmpeg process
            do {
                try ffmpegProcess.run()
            } catch {
                logger.error("Failed to start FFmpeg process for chunk: \(error)")
                return
            }

            // Write the chunk data to the FFmpeg process
            for (_, data) in chunk.enumerated() {
                do {
                    try ffmpegInputPipe.fileHandleForWriting.write(contentsOf: data)
                } catch {
                    logger.error("Error writing to FFmpeg process: \(error)")
                    break
                }
            }

            // Close the pipe and handle the process completion with timeout
            ffmpegInputPipe.fileHandleForWriting.closeFile()

            // Add timeout to prevent indefinite hang if FFmpeg gets stuck
            let timeoutSeconds: Double = 30.0
            var didTimeout = false
            let timeoutWorkItem = DispatchWorkItem {
                if ffmpegProcess.isRunning {
                    self.logger.warning("FFmpeg process timed out after \(timeoutSeconds)s, terminating")
                    ffmpegProcess.terminate()
                    didTimeout = true
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
            ffmpegProcess.waitUntilExit()
            timeoutWorkItem.cancel()

            // Check if FFmpeg process completed successfully
            if didTimeout {
                logger.error("FFmpeg timed out and was terminated")
            } else if ffmpegProcess.terminationStatus == 0 {
                // Start new video chunk in database only if FFmpeg succeeds
                let _ = DatabaseManager.shared.startNewVideoChunk(filePath: outputPath)
                logger.info("Video successfully saved and registered.")
            } else {
                logger.error("FFmpeg failed to process video chunk (exit code: \(ffmpegProcess.terminationStatus))")
            }

            
            // Read FFmpeg's output and error
            let outputData = ffmpegOutputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = ffmpegErrorPipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: outputData, encoding: .utf8) {
                logger.info("FFmpeg (stdout pipe): \(output)")
            }
            // Not differentiating as ffmpeg is outputting standard output on error pipe?
            if let errorOutput = String(data: errorData, encoding: .utf8) {
                logger.info("FFmpeg (stderror pipe): \(errorOutput)")
            }
        } else {
            logger.error("Failed to save ffmpeg video")
        }
    }

    @objc func enableRecording() {
        if isCapturing == .recording {
            return
        }
        isCapturing = .recording

        Task {
            await startScreenCapture()
        }
    }
    
    @objc func pauseRecording() {
        isCapturing = .paused
        logger.info("Screen capture paused")
    }
    
    @objc func userDisableRecording() {
        wasRecordingBeforeSearchView = false
        wasRecordingBeforeTimelineView = false
        disableRecording()
    }
    
    @objc func disableRecording() {
        if isCapturing != .recording {
            return
        }
        
        // Stop screen capture
        stopScreenCapture()
        
        // Process any remaining frames in the buffer
        imageBufferQueue.sync { [weak self] in
            guard let strongSelf = self else { return }
            
            // Move the images to a temporary buffer if the threshold is reached
            let tempBuffer: [Data] = Array(strongSelf.imageDataBuffer.prefix(strongSelf.frameThreshold))
            strongSelf.imageDataBuffer.removeAll()

            // Process the images outside of the critical section
            if !tempBuffer.isEmpty {
                strongSelf.processChunk(tempBuffer)
            }
        }
        
        timelineView?.viewModel.setIndexToLatest()
        
        setupMenu()
    }

    @objc func quitApp() {
        // Clean up event monitors to prevent memory leaks
        cleanupEventMonitors()
        // Cancel any pending screenshot work
        screenshotWorkItem?.cancel()
        NSApplication.shared.terminate(self)
    }

    private func cleanupEventMonitors() {
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    private func performOCR(frameId: Int64, on image: CGImage) {
        ocrQueue.async {
            Task {
                let request = VNRecognizeTextRequest { request, error in
                    guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                        self.logger.error("OCR error: \(error?.localizedDescription ?? "Unknown error")")
                        return
                    }
                    
                    let candidateConfidenceThreshold: Float = 0.35
                    var textEntries = [(frameId: Int64, text: String, x: Double, y: Double, w: Double, h: Double)]()
                    for observation in observations {
                        if let candidate = observation.topCandidates(1).first, candidate.confidence > candidateConfidenceThreshold {
                            let string = candidate.string
                            let stringRange = string.startIndex..<string.endIndex
                            let box = try? candidate.boundingBox(for: stringRange)
                            let boundingBox = box?.boundingBox ?? .zero
                            textEntries.append((frameId: frameId, text: string, x: boundingBox.minX, y: boundingBox.minY,
                                                w: boundingBox.width, h: boundingBox.height))
                        }
                    }
                    DatabaseManager.shared.insertTextsForFrames(entries: textEntries)

                    var texts = textEntries.map { $0.text }
                    if self.settingsManager.settings.saveEverythingCopiedToClipboard {
                        let newClipboardText = ClipboardManager.shared.getClipboardIfChanged() ?? ""
                        texts.append(newClipboardText)
                    }
                    let cleanText = TextMerger.shared.mergeTexts(texts: texts)
                    DatabaseManager.shared.insertAllTextForFrame(frameId: frameId, text: cleanText)

                    // Export to ~/rem-data for Claude access
                    let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName
                    DataExporter.shared.exportCapture(
                        timestamp: Date(),
                        appName: activeApp,
                        ocrText: cleanText,
                        frameId: frameId
                    )
                }
                
                if self.settingsManager.settings.fastOCR {
                    request.recognitionLevel = .fast
                } else {
                    request.recognitionLevel = .accurate
                }

                let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try requestHandler.perform([request])
                } catch {
                    self.logger.error("Failed to perform OCR: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func analyzeImage(frameId: Int64, image: CGImage) {}
    
    private func processImageDataBuffer() {
        // Temporarily store the buffered data and clear the buffer
        let tempBuffer = imageDataBuffer
        imageDataBuffer.removeAll()

        // Write the buffered data to the FFmpeg process
        tempBuffer.forEach {
            ffmpegInputPipe?.fileHandleForWriting.write($0)
        }
    }
    
    @objc func showTimelineView(with index: Int64) {
        wasRecordingBeforeTimelineView = (isCapturing == .recording) || wasRecordingBeforeSearchView // handle going from search to TL
        disableRecording()
        wasRecordingBeforeSearchView = false
        closeSearchView()
        if timelineViewWindow == nil {
            let screenRect = NSScreen.main?.frame ?? NSRect.zero
            timelineViewWindow = MainWindow(
                contentRect: screenRect,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            timelineViewWindow?.hasShadow = false
            timelineViewWindow?.level = .normal

            timelineViewWindow?.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .participatesInCycle]
            timelineViewWindow?.ignoresMouseEvents = false
            timelineView = TimelineView(viewModel: TimelineViewModel(), settingsManager: settingsManager, onClose: {
                DispatchQueue.main.async { [weak self] in
                    self?.closeTimelineView()
                }
            })
            timelineView?.viewModel.updateIndex(withIndex: index)

            timelineViewWindow?.contentView = NSHostingView(rootView: timelineView)
            timelineView?.viewModel.setIsOpen(isOpen: true)
            timelineViewWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                self.timelineViewWindow?.orderFrontRegardless() // Ensure it comes to the front
            }
        } else if !isTimelineOpen() {
            timelineView?.viewModel.updateIndex(withIndex: index)
            timelineView?.viewModel.setIsOpen(isOpen: true)
            timelineViewWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                self.timelineViewWindow?.orderFrontRegardless() // Ensure it comes to the front
            }
        }
    }
    
    private func isTimelineOpen() -> Bool {
        return timelineViewWindow?.isVisible ?? false
    }
    
    func openFullView(atIndex index: Int64) {
        // Needed since Search returns a frameId but Timeline runs on chunksFramesIndexes
        if let chunksFramesIndex = DatabaseManager.shared.getChunksFramesIndex(frameId: index) {
            showTimelineView(with: chunksFramesIndex)
        } else {
            logger.warning("No chunksFramesIndex found for frameId \(index)")
        }
    }
    
    func closeSearchView() {
        searchViewWindow?.isReleasedWhenClosed = false
        searchViewWindow?.close()
        if wasRecordingBeforeSearchView {
            enableRecording()
        }
    }
    
    func closeTimelineView() {
        timelineViewWindow?.isReleasedWhenClosed = false
        timelineViewWindow?.close()
        timelineView?.viewModel.setIsOpen(isOpen: false)
        if wasRecordingBeforeTimelineView {
            enableRecording()
        }
    }
    
    @objc func showSearchView() {
        wasRecordingBeforeSearchView = (isCapturing == .recording) || wasRecordingBeforeTimelineView
        disableRecording()
        wasRecordingBeforeTimelineView = false
        closeTimelineView()
        // Ensure that the search view window is created and shown
        if searchViewWindow == nil {
            let screenRect = NSScreen.main?.frame ?? NSRect.zero
            searchViewWindow = MainWindow(
                contentRect: screenRect,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            searchViewWindow?.hasShadow = false
            searchViewWindow?.ignoresMouseEvents = false
            
            searchViewWindow?.center()
            searchViewWindow?.contentView = NSHostingView(rootView: searchView)
            
            searchViewWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                self.searchViewWindow?.orderFrontRegardless() // Ensure it comes to the front
            }
        } else if !(searchViewWindow?.isVisible ?? false) {
            searchViewWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                self.searchViewWindow?.orderFrontRegardless() // Ensure it comes to the front
            }
        }
    }
}
