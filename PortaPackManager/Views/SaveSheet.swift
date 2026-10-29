import AppKit
import UniformTypeIdentifiers

/// Sichern-Dialog als Blatt am aktuellen Fenster statt `NSSavePanel.runModal()`.
///
/// `runModal` hielt die ganze App an – auch Archivfenster, Karten und den
/// Fernzugriff – und erschien losgelöst vom Fenster, aus dem es kam (Review
/// 28.10.2026, Nitpick). Ohne Fenster (sollte nicht vorkommen) bleibt `runModal`
/// als Rückfall.
@MainActor
enum SaveSheet {
    static func url(name: String, types: [UTType] = [], message: String? = nil,
                    window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if !types.isEmpty { panel.allowedContentTypes = types }
        if let message { panel.message = message }
        guard let window else { return panel.runModal() == .OK ? panel.url : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }

    /// Öffnen-Dialog als Blatt – Gegenstück zu `url(name:…)`; leer bei Abbruch.
    static func open(multiple: Bool = false, types: [UTType] = [], message: String? = nil,
                     window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) async -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        if !types.isEmpty { panel.allowedContentTypes = types }
        if let message { panel.message = message }
        guard let window else { return panel.runModal() == .OK ? panel.urls : [] }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : []
    }
}
