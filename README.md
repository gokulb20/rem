# Rem

**Rem** is a macOS application that continuously captures your screen activity, performs OCR (Optical Character Recognition) on screenshots, and creates a searchable timeline of everything you've seen on your computer.

## Features

- **Continuous Screen Capture**: Automatically records your screen at regular intervals
- **OCR Text Extraction**: Extracts readable text from screenshots using Apple's Vision framework
- **Full-Text Search**: Search through everything you've seen with SQLite FTS4
- **Timeline Visualization**: Browse through your screen history with video playback
- **Activity Tracking**: Generates hourly and daily summaries of your computer usage
- **URL & Project Detection**: Automatically extracts URLs from browser sessions and detects active projects
- **Privacy-First Design**: All data stays local on your machine
- **Sensitive Content Filtering**: Automatically detects and filters passwords, API keys, and other sensitive data from clipboard

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15.0 or later (for building)
- Screen Recording permission
- Accessibility permission (for window titles)

## Installation

### From Source

1. Clone the repository:
   ```bash
   git clone --recursive https://github.com/jasonjmcghee/rem.git
   cd rem
   ```

2. Build FFmpeg (required for video encoding):
   ```bash
   ./scripts/build_ffmpeg.sh
   ```

3. Open in Xcode:
   ```bash
   open rem.xcodeproj
   ```

4. Build and run (⌘R)

### Pre-built Release

Download the latest release from the [Releases](https://github.com/jasonjmcghee/rem/releases) page.

## Usage

### Getting Started

1. Launch Rem from your Applications folder
2. Grant the required permissions when prompted:
   - **Screen Recording**: Required for capturing screen content
   - **Accessibility**: Required for extracting window titles
3. Rem will automatically start recording in the background
4. Access Rem from the menu bar icon

### Menu Bar Controls

- Click the Rem icon to access settings
- **Recording indicator**: Green = recording, Gray = stopped
- **Settings**: Configure recording preferences
- **Show Data Folder**: Open the folder where data is stored
- **Purge All Data**: Delete all captured data (irreversible)

### Keyboard Shortcuts

- `⌘⇧F` - Open search view
- `Esc` - Close timeline or search view

### Data Storage

Rem stores data in two locations:

1. **Database & Videos**: `~/Library/Application Support/today.jason.rem/`
   - `db.sqlite3` - SQLite database with OCR text and metadata
   - `output-*.mp4` - Video chunks (automatically cleaned after 1 hour)

2. **Exports for Claude/AI**: `~/rem-data/`
   - Daily folders with JSON captures
   - Hourly and daily summaries
   - Perfect for AI assistant integration

## Architecture

```
rem/
├── remApp.swift          # Main app entry point & DataExporter
├── DB.swift              # SQLite database with FTS4 search
├── TimelineView.swift    # Video playback & timeline UI
├── Search.swift          # Full-text search interface
├── ClipboardManager.swift # Clipboard monitoring
├── TextMerger.swift      # OCR text deduplication
├── SettingsManager.swift # User preferences
├── Logger.swift          # Production logging infrastructure
└── ImageHelper.swift     # Image processing utilities
```

### Key Components

| Component | Purpose |
|-----------|---------|
| `DataExporter` | Exports captures to JSON, generates summaries |
| `DatabaseManager` | SQLite operations, FTS4 search, video chunk management |
| `AppDelegate` | Screen capture loop, OCR processing, event handling |
| `RemLogger` | Centralized logging with os.Logger |
| `SensitiveContentFilter` | Filters passwords, API keys from stored data |

## Configuration

### Settings (via UI)

- **Launch at startup**: Auto-start Rem when you log in
- **Include clipboard text**: Save copied text with screenshots
- **Fast OCR mode**: Trade accuracy for speed
- **OCR active window only**: Only process the focused window

### Internal Configuration

These values are in the source code and can be modified:

| Setting | Default | Description |
|---------|---------|-------------|
| `sessionTimeoutSeconds` | 300 (5 min) | Gap before new session starts |
| `videoRetentionHours` | 1 | Hours before video cleanup |
| `frameThreshold` | 30 | Frames per video chunk |
| `maxBufferSize` | 100 | Max frames in memory buffer |
| `candidateConfidenceThreshold` | 0.35 | Minimum OCR confidence |

## Development

### Building

```bash
# Clone with submodules
git clone --recursive https://github.com/jasonjmcghee/rem.git
cd rem

# Build FFmpeg
./scripts/build_ffmpeg.sh

# Open in Xcode
open rem.xcodeproj
```

### Running Tests

```bash
# Via Xcode
xcodebuild test -project rem.xcodeproj -scheme rem -destination 'platform=macOS'

# Or use ⌘U in Xcode
```

### Code Quality

```bash
# Install SwiftLint
brew install swiftlint

# Run linter
swiftlint lint
```

### CI/CD

This project uses GitHub Actions for continuous integration:

- **Build & Test**: Runs on every push and PR
- **Lint**: SwiftLint code quality checks
- **Security Scan**: Checks for hardcoded secrets
- **Release Build**: Creates artifacts for releases

## Security & Privacy

### Data Protection

- All data is stored locally (never uploaded)
- App Sandbox enabled for security isolation
- SQL injection protection via parameterized queries
- FTS search input sanitization

### Sensitive Content Filtering

Rem automatically detects and filters:
- Passwords and authentication tokens
- API keys (AWS, OpenAI, etc.)
- Credit card numbers
- Social Security Numbers
- JWT tokens

### Recommendations

For maximum security:
- Enable FileVault disk encryption on your Mac
- Regularly review and purge old data
- Be cautious with the "Include clipboard text" option

## Troubleshooting

### Common Issues

**"Screen Recording permission denied"**
- Go to System Preferences → Privacy & Security → Screen Recording
- Enable Rem in the list
- Restart the app

**"No data appearing"**
- Check that recording is enabled (green indicator)
- Verify permissions are granted
- Check `~/Library/Application Support/today.jason.rem/` for data

**"Search not finding results"**
- OCR may not have captured the text clearly
- Try searching for partial words
- Check that the timeframe is correct

### Logs

View logs using Console.app:
1. Open Console.app
2. Filter by "today.jason.rem"
3. Select your device

Or via terminal:
```bash
log show --predicate 'subsystem == "today.jason.rem"' --last 1h
```

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Run tests (`xcodebuild test`)
5. Commit (`git commit -m 'Add amazing feature'`)
6. Push (`git push origin feature/amazing-feature`)
7. Open a Pull Request

### Code Style

- Follow Swift API Design Guidelines
- Use SwiftLint for consistency
- Add tests for new functionality
- Update documentation as needed

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [SQLite.swift](https://github.com/stephencelis/SQLite.swift) - SQLite wrapper
- [FFmpeg](https://ffmpeg.org/) - Video encoding
- Apple Vision framework - OCR capabilities

## Support

- **Issues**: [GitHub Issues](https://github.com/jasonjmcghee/rem/issues)
- **Discussions**: [GitHub Discussions](https://github.com/jasonjmcghee/rem/discussions)

---

Made with care by [Jason McGhee](https://github.com/jasonjmcghee)
