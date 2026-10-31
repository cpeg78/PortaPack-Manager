// swift-tools-version:5.9
// whisper.cpp (MIT, ggml-org/whisper.cpp) als fertiges XCFramework für die
// Flugfunk-Abschrift mit Whisper. Xcode lädt das Archiv beim ersten Bauen und
// prüft es über die Prüfsumme – nichts davon liegt im Repository.
// Neue Fassung: Archiv von github.com/ggml-org/whisper.cpp/releases (Build-Tag mit
// „-xcframework.zip“), Prüfsumme mit `swift package compute-checksum <zip>`.
import PackageDescription

let package = Package(
    name: "WhisperFramework",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WhisperFramework", targets: ["whisper"])],
    targets: [
        // v1.9.5 (Build b5454, 6.10.2026)
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"),
    ]
)
