//
//  SettingsManager.swift
//  rem
//
//  Created by Jason McGhee on 12/27/23.
//

import Foundation
import SwiftUI
import LaunchAtLogin

// The settings structure
struct AppSettings: Codable {
    var saveEverythingCopiedToClipboard: Bool
    var onlyOCRFrontmostWindow: Bool = true
    var fastOCR: Bool = true
    var startRememberingOnStartup: Bool = true  // Always on by default
}

// The settings manager handles saving and loading the settings
class SettingsManager: ObservableObject {
    @Published var settings: AppSettings
    @Published var isRecording: Bool = false

    private let settingsKey = "appSettings"

    init() {
        // Load settings or use default values
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let decodedSettings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decodedSettings
        } else {
            // Default settings
            self.settings = AppSettings(saveEverythingCopiedToClipboard: false)
        }
    }

    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
    }

    func updateRecordingState(_ recording: Bool) {
        DispatchQueue.main.async {
            self.isRecording = recording
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    var onToggleRecording: () -> Void
    var onShowData: () -> Void
    var onPurgeData: () -> Void

    @State private var showPurgeConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title)
                .fontWeight(.semibold)

            // RECORDING SECTION
            VStack(alignment: .leading, spacing: 12) {
                Text("RECORDING")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)

                HStack {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(settingsManager.isRecording ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                        Text(settingsManager.isRecording ? "Recording" : "Stopped")
                            .font(.body)
                    }

                    Spacer()

                    Button(action: onToggleRecording) {
                        Text(settingsManager.isRecording ? "Stop" : "Start")
                            .frame(width: 60)
                    }
                    .controlSize(.regular)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }

            // OPTIONS SECTION
            VStack(alignment: .leading, spacing: 12) {
                Text("OPTIONS")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Launch at startup", isOn: $settingsManager.settings.startRememberingOnStartup)
                        .onChange(of: settingsManager.settings.startRememberingOnStartup) { value in
                            LaunchAtLogin.isEnabled = value
                            settingsManager.saveSettings()
                        }

                    Toggle("Include clipboard text", isOn: $settingsManager.settings.saveEverythingCopiedToClipboard)
                        .onChange(of: settingsManager.settings.saveEverythingCopiedToClipboard) { _ in
                            settingsManager.saveSettings()
                        }

                    Toggle("Fast OCR mode", isOn: $settingsManager.settings.fastOCR)
                        .onChange(of: settingsManager.settings.fastOCR) { _ in
                            settingsManager.saveSettings()
                        }

                    Toggle("OCR active window only", isOn: $settingsManager.settings.onlyOCRFrontmostWindow)
                        .onChange(of: settingsManager.settings.onlyOCRFrontmostWindow) { _ in
                            settingsManager.saveSettings()
                        }
                }
            }

            // DATA SECTION
            VStack(alignment: .leading, spacing: 12) {
                Text("DATA")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fontWeight(.medium)

                HStack(spacing: 12) {
                    Button(action: onShowData) {
                        Text("Show Data Folder")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)

                    Button(action: { showPurgeConfirmation = true }) {
                        Text("Purge All Data")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.regular)
                    .foregroundColor(.red)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 350, height: 380)
        .alert("Purge All Data?", isPresented: $showPurgeConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Everything", role: .destructive) {
                onPurgeData()
            }
        } message: {
            Text("This will permanently delete all captured data. This action cannot be undone.")
        }
    }
}
