//
//  remApp.swift
//  rem
//
//  Created by Jason McGhee on 12/16/23.
//

import AppKit

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
}

// Daily journal for end-of-day recall
struct DailyJournal: Codable {
    let date: String
    let timeline: [ActivityEntry]       // Full day timeline
    let allUrls: [URLVisit]             // Every URL with context
    let appSummary: [String: Int]       // Time per app in minutes
    let keyMoments: [String]            // Notable things you saw
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

    // Deduplication
    private var lastOcrHash: Int = 0
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

    // Retention settings
    let videoRetentionHours: Int = 1

    init() {
        let homeDir = fileManager.homeDirectoryForCurrentUser
        exportBaseDir = homeDir.appendingPathComponent("rem-data")
        try? fileManager.createDirectory(at: exportBaseDir, withIntermediateDirectories: true)
    }

    // MARK: - Window Title Extraction

    func getWindowTitle(for appName: String?) -> String? {
        guard let app = appName else { return nil }

        let script = """
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

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)
            if error == nil, let title = output.stringValue, !title.isEmpty {
                return title
            }
        }
        return nil
    }

    // MARK: - Browser URL Extraction

    func getBrowserURL(for appName: String?) -> String? {
        guard let app = appName else { return nil }

        var script: String?

        if app == "Safari" {
            script = """
            tell application "Safari"
                try
                    return URL of current tab of front window
                on error
                    return ""
                end try
            end tell
            """
        } else if app == "Google Chrome" || app == "Chrome" {
            script = """
            tell application "Google Chrome"
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """
        } else if app == "Arc" {
            script = """
            tell application "Arc"
                try
                    return URL of active tab of front window
                on error
                    return ""
                end try
            end tell
            """
        } else if app == "Firefox" {
            // Firefox doesn't support AppleScript well, skip
            return nil
        }

        guard let scriptSource = script else { return nil }

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: scriptSource) {
            let output = scriptObject.executeAndReturnError(&error)
            if error == nil, let url = output.stringValue, !url.isEmpty {
                return url
            }
        }
        return nil
    }

    // MARK: - Deduplication & Cleaning

    private func isDuplicate(ocrText: String, appName: String?) -> Bool {
        let hash = ocrText.hashValue
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

        let duration = Int(timestamp.timeIntervalSince(currentSession!.startTime))
        return (currentSession!.id, duration)
    }

    // MARK: - Activity Tracking for Perfect Recall

    private func trackActivity(app: String, windowTitle: String?, url: String?, ocrText: String, timestamp: Date) {
        let hour = Calendar.current.component(.hour, from: timestamp)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let timeStr = timeFormatter.string(from: timestamp)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: timestamp)

        // New hour? Generate summary for previous hour
        if lastHour != -1 && hour != lastHour {
            generateHourlySummary(hour: lastHour, date: timestamp)
            // Reset hourly tracking
            hourlyTimeline.removeAll()
            hourlyUrls.removeAll()
            hourlyStats.removeAll()
            hourlyTopics.removeAll()
        }
        lastHour = hour

        // Extract key content from this capture
        let keyContent = extractKeyContent(from: ocrText, windowTitle: windowTitle)

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

        // Track URL visits
        if let urlStr = url {
            hourlyUrls.insert(urlStr)
            if var existing = dailyUrlVisits[urlStr] {
                existing.count += 1
                dailyUrlVisits[urlStr] = existing
            } else {
                dailyUrlVisits[urlStr] = (title: windowTitle, firstSeen: timeStr, count: 1)
            }
        }

        // Track time per app
        hourlyStats[app, default: 0] += 2

        // Track topics
        for content in keyContent {
            hourlyTopics.insert(content)
        }
    }

    private func extractKeyContent(from text: String, windowTitle: String?) -> [String] {
        var content: [String] = []

        // Add window title as key content if meaningful
        if let title = windowTitle, title.count > 5 && title.count < 100 {
            content.append(title)
        }

        // Extract meaningful lines from OCR
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip noise
            if trimmed.count < 8 || trimmed.count > 80 { continue }
            if trimmed.filter({ $0.isLetter }).count < 5 { continue }

            // Keep lines that look like titles/headings
            let words = trimmed.components(separatedBy: .whitespaces)
            if words.count >= 3 && words.count <= 12 {
                // Capitalize check - titles often have capitalized words
                let capitalizedWords = words.filter { word in
                    guard let first = word.first else { return false }
                    return first.isUppercase
                }
                if capitalizedWords.count >= 2 || trimmed.contains(" - ") || trimmed.contains(" | ") {
                    if content.count < 5 && !content.contains(trimmed) {
                        content.append(trimmed)
                    }
                }
            }
        }

        return content
    }

    private func generateHourlySummary(hour: Int, date: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dayFolder = formatter.string(from: date)
        let dayDir = exportBaseDir.appendingPathComponent(dayFolder)

        let hourStr = String(format: "%02d:00", hour)
        let summary = HourlySummary(
            hour: hourStr,
            date: dayFolder,
            timeline: hourlyTimeline,
            urlsVisited: Array(hourlyUrls),
            appsUsed: hourlyStats.mapValues { $0 / 60 },
            keyTopics: Array(hourlyTopics.prefix(30))
        )

        let filename = "hour-\(String(format: "%02d", hour))-summary.json"
        let filePath = dayDir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(summary) {
            try? data.write(to: filePath)
        }
    }

    private func generateDailyJournal(for date: String) {
        let dayDir = exportBaseDir.appendingPathComponent(date)

        // Convert URL visits to array
        let urlVisits = dailyUrlVisits.map { (url, info) in
            URLVisit(url: url, title: info.title, firstSeen: info.firstSeen, visitCount: info.count)
        }.sorted { $0.visitCount > $1.visitCount }

        let journal = DailyJournal(
            date: date,
            timeline: dailyTimeline,
            allUrls: urlVisits,
            appSummary: dailyStats.mapValues { $0 * 2 / 60 },  // Convert to minutes
            keyMoments: dailyKeyMoments
        )

        let filename = "\(date)-journal.json"
        let filePath = dayDir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(journal) {
            try? data.write(to: filePath)
        }

        // Reset daily tracking
        dailyTimeline.removeAll()
        dailyUrlVisits.removeAll()
        dailyKeyMoments.removeAll()
    }

    // MARK: - Export to JSON

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
        try? fileManager.createDirectory(at: dayDir, withIntermediateDirectories: true)

        // Get window title and URL
        let windowTitle = getWindowTitle(for: appName)
        let url = getBrowserURL(for: appName)

        // Update session tracking
        let app = appName ?? "Unknown"
        let (sessionId, sessionDuration) = updateSession(app: app, timestamp: timestamp)

        // Track activity for perfect recall summaries
        trackActivity(app: app, windowTitle: windowTitle, url: url, ocrText: cleanedText, timestamp: timestamp)

        // Create structured capture data
        let capture = CaptureData(
            timestamp: timestamp.ISO8601Format(),
            app: app,
            windowTitle: windowTitle,
            url: url,
            ocrText: cleanedText,  // Use cleaned text
            frameId: frameId,
            sessionId: sessionId,
            sessionDuration: sessionDuration
        )

        // Save as JSON
        let safeAppName = app
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(30)

        let filename = "\(timeString)_\(safeAppName).json"
        let filePath = dayDir.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let jsonData = try? encoder.encode(capture) {
            try? jsonData.write(to: filePath)
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

        if let jsonData = try? JSONSerialization.data(withJSONObject: digest, options: [.prettyPrinted, .sortedKeys]) {
            try? jsonData.write(to: digestPath)
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
        let cutoffDate = Calendar.current.date(byAdding: .hour, value: -videoRetentionHours, to: Date())!

        if let saveDir = RemFileManager.shared.getSaveDir() {
            do {
                let files = try fileManager.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)
                for file in files {
                    if file.pathExtension == "mp4" {
                        let attrs = try fileManager.attributesOfItem(atPath: file.path)
                        if let creationDate = attrs[.creationDate] as? Date, creationDate < cutoffDate {
                            try fileManager.removeItem(at: file)
                            print("Deleted old video: \(file.lastPathComponent)")
                        }
                    }
                }
            } catch {
                print("Video cleanup error: \(error.localizedDescription)")
            }
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
        // Empty scene, as we are controlling everything through the AppDelegate
        Settings { SettingsView(settingsManager: appDelegate.settingsManager) }
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
        
        // Monitor for scroll events
        NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleGlobalScrollEvent(event)
        }
        
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if self?.isTimelineOpen() ?? false {
                if !event.modifierFlags.contains(.command) && event.scrollingDeltaX != 0 {
                    self?.timelineView?.viewModel.updateIndex(withDelta: event.scrollingDeltaX)
                }

                if event.modifierFlags.contains(.command) && event.scrollingDeltaY > 0 && (self?.isTimelineOpen() ?? false) { // Check if scroll up
                    DispatchQueue.main.async { [weak self] in
                        self?.closeTimelineView()
                    }
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

    let icon = self.isCapturing == .recording ? (
        isDarkMode ? self.recordingStatusImageDark : self.recordingStatusImage
    ) : (
        isDarkMode ? self.idleStatusImageDark : self.idleStatusImage
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
            let recordingTitle = self.isCapturing == .recording ? "Stop Remembering" : "Start Remembering"
            let recordingSelector = self.isCapturing == .recording ? #selector(self.userDisableRecording) : #selector(self.enableRecording)
            menu.addItem(NSMenuItem(title: recordingTitle, action: recordingSelector, keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Toggle Timeline", action: #selector(self.toggleTimeline), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Search", action: #selector(self.showSearchView), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Copy Recent Context", action: #selector(self.copyRecentContext), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator()) // Separator
            menu.addItem(NSMenuItem(title: "Show Me My Data", action: #selector(self.showMeMyData), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "⚠️ Purge All Data ⚠️", action: #selector(self.confirmPurgeAllData), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator()) // Separator
            menu.addItem(
                withTitle: "Settings",
                action: #selector(self.openSettings),
                keyEquivalent: ","
            )
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
        if settingsViewWindow == nil {
            let settingsView = SettingsView(settingsManager: settingsManager)
            settingsViewWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsViewWindow?.isReleasedWhenClosed = false
            settingsViewWindow?.center()
            settingsViewWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsViewWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                self.settingsViewWindow?.orderFrontRegardless() // Ensure it comes to the front
            }
        } else if !(settingsViewWindow?.isVisible ?? false) {
            settingsViewWindow?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async {
                self.settingsViewWindow?.orderFrontRegardless() // Ensure it comes to the front
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
    
    private func handleGlobalScrollEvent(_ event: NSEvent) {
        guard settingsManager.settings.enableCmdScrollShortcut else { return }
        guard event.modifierFlags.contains(.command) else { return }
        
        if event.scrollingDeltaY < 0 && !isTimelineOpen() { // Check if scroll up
            DispatchQueue.main.async { [weak self] in
                self?.showTimelineView(with: DatabaseManager.shared.getMaxChunksFramesIndex())
            }
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
                if settingsManager.settings.recordWindowWithMouse {
                    let mouseLocation = NSEvent.mouseLocation
                    if let screen = NSScreen.screens.first(where: {$0.frame.contains(mouseLocation)}) {
                        if let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                            displayID = CGDirectDisplayID(screenID.uint32Value)
                            logger.debug("Mouse Active Display ID: \(displayID ?? 999)")
                        }
                    }
                }
                
                if displayID == nil {
                    if let screenID = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                        displayID = CGDirectDisplayID(screenID.uint32Value)
                        logger.debug("Active Display ID: \(displayID ?? 999)")
                    }
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
            screenshotQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.scheduleScreenshot(shareableContent: shareableContent)
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

            // Close the pipe and handle the process completion
            ffmpegInputPipe.fileHandleForWriting.closeFile()
            ffmpegProcess.waitUntilExit()
            
            // Check if FFmpeg process completed successfully
            if ffmpegProcess.terminationStatus == 0 {
                // Start new video chunk in database only if FFmpeg succeeds
                let _ = DatabaseManager.shared.startNewVideoChunk(filePath: outputPath)
                logger.info("Video successfully saved and registered.")
            } else {
                logger.error("FFmpeg failed to process video chunk.")
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
        NSApplication.shared.terminate(self)
    }

    private func performOCR(frameId: Int64, on image: CGImage) {
        ocrQueue.async {
            Task {
                let request = VNRecognizeTextRequest { request, error in
                    guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                        print("OCR error: \(error?.localizedDescription ?? "Unknown error")")
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
                    print("Failed to perform OCR: \(error.localizedDescription)")
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
            print("No chunksFramesIndex found for frameId \(index)")
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
