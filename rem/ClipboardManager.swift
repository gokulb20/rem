import AppKit

class ClipboardManager {
    static let shared = ClipboardManager()
    
    private var changeCount: Int
    private var pasteboard: NSPasteboard
    
    init() {
        self.pasteboard = NSPasteboard.general
        self.changeCount = pasteboard.changeCount
    }
    
    func getClipboardIfChanged() -> String? {
        // Check if the clipboard has changed since the last check
        // Note: NSPasteboard.changeCount only tells us IF it changed, not how many times.
        // The pasteboard API doesn't provide access to historical clipboard items -
        // it only returns the current content.
        if pasteboard.changeCount != changeCount {
            // Update the changeCount to the current changeCount
            changeCount = pasteboard.changeCount

            // Return the current clipboard content if it's a string
            if let string = pasteboard.string(forType: .string), !string.isEmpty {
                return string
            }
        }

        // Return nil if there are no new changes or no string content
        return nil
    }
    
    func replaceClipboardContents(with string: String) {
        pasteboard.clearContents()
        
        let finalContents = string.isEmpty ? "No context. Is remembering disabled?" : """
        Below is the text that's been on my screen recently. ------------- \(string) ------------------ Above is the text that's been on my screen recently. Please answer whatever I ask using the provided information about what has been on the screen recently. Do not say anything else or give any other information. Only answer the query. --------------------------\n
        """

        pasteboard.setString(finalContents, forType: .string)
        // We don't want to pickup our own changes
        changeCount = pasteboard.changeCount
    }
}
