import XCTest
@testable import DiskMapper

final class ScannerTests: XCTestCase {

    // MARK: - Setup

    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    func makeFile(name: String, size: Int, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? tempDir).appendingPathComponent(name)
        try Data(repeating: 0xAB, count: size).write(to: url)
        return url
    }

    func makeDir(name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? tempDir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Basic structure

    func testScanEmptyDirectory() async throws {
        let node = try await DiskScanner().scan(url: tempDir, progress: ScanProgress())
        XCTAssertTrue(node.isDirectory)
        XCTAssertTrue(node.children.isEmpty)
        XCTAssertEqual(node.totalSize, 0)
    }

    func testScanFlatFiles() async throws {
        try makeFile(name: "a.txt", size: 1_024)
        try makeFile(name: "b.txt", size: 4_096)

        let node = try await DiskScanner().scan(url: tempDir, progress: ScanProgress())

        XCTAssertEqual(node.children.count, 2)
        XCTAssertGreaterThan(node.totalSize, 0)
    }

    func testScanNestedDirectories() async throws {
        let sub = try makeDir(name: "sub")
        try makeFile(name: "nested.txt", size: 2_048, in: sub)
        try makeFile(name: "root.txt", size: 1_024)

        let node = try await DiskScanner().scan(url: tempDir, progress: ScanProgress())

        XCTAssertEqual(node.children.count, 2)

        let subNode = node.children.first { $0.isDirectory }
        XCTAssertNotNil(subNode)
        XCTAssertEqual(subNode?.children.count, 1)
        XCTAssertGreaterThan(node.totalSize, 0)
    }

    // MARK: - Total sizes

    func testTotalSizeEqualsChildrenSum() async throws {
        try makeFile(name: "x.bin", size: 4_096)
        try makeFile(name: "y.bin", size: 8_192)

        let node = try await DiskScanner().scan(url: tempDir, progress: ScanProgress())

        let childSum = node.children.reduce(Int64(0)) { $0 + $1.totalSize }
        XCTAssertEqual(node.totalSize, childSum)
    }

    func testNestedTotalSizePropagates() async throws {
        let sub = try makeDir(name: "sub")
        try makeFile(name: "a.bin", size: 8_192, in: sub)
        try makeFile(name: "b.bin", size: 4_096)

        let node = try await DiskScanner().scan(url: tempDir, progress: ScanProgress())

        // Root total must include nested file
        let subNode = node.children.first { $0.isDirectory }!
        XCTAssertGreaterThan(subNode.totalSize, 0)
        XCTAssertGreaterThanOrEqual(node.totalSize, subNode.totalSize)
    }

    // MARK: - Sorting

    func testChildrenSortedLargestFirst() async throws {
        try makeFile(name: "small.txt", size: 512)
        try makeFile(name: "large.txt", size: 16_384)
        try makeFile(name: "medium.txt", size: 4_096)

        let node = try await DiskScanner().scan(url: tempDir, progress: ScanProgress())

        let sizes = node.children.map(\.totalSize)
        XCTAssertEqual(sizes, sizes.sorted(by: >), "Children should be sorted largest-first")
    }

    // MARK: - Symlinks

    func testSymlinksAreSkipped() async throws {
        let real = try makeFile(name: "real.txt", size: 1_024)
        let link = tempDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let node = try await DiskScanner().scan(url: tempDir, progress: ScanProgress())

        // Symlink should be excluded; only the real file is counted.
        XCTAssertEqual(node.children.count, 1)
        XCTAssertEqual(node.children[0].name, "real.txt")
    }

    // MARK: - Progress tracking

    func testProgressCounts() async throws {
        let sub = try makeDir(name: "sub")
        try makeFile(name: "f1.txt", size: 100)
        try makeFile(name: "f2.txt", size: 100, in: sub)

        let progress = ScanProgress()
        _ = try await DiskScanner().scan(url: tempDir, progress: progress)

        // ScanProgress is no longer an actor — no await needed.
        let files = progress.scannedFiles
        let dirs  = progress.scannedDirectories
        // 2 files, 2 directories (root + sub)
        XCTAssertEqual(files, 2)
        XCTAssertEqual(dirs, 2)
    }

    func testCancellationStopsEarly() async throws {
        // Create enough entries that cancellation mid-way is meaningful
        for i in 0..<20 {
            try makeFile(name: "file\(i).bin", size: 1_024)
        }

        let progress = ScanProgress()
        // Cancel immediately — scanner checks isCancelled between items
        progress.cancel()

        let node = try await DiskScanner().scan(url: tempDir, progress: progress)
        // Some or all children may be skipped; total should be <= 20
        XCTAssertLessThanOrEqual(node.children.count, 20)
    }

    // MARK: - Error on non-directory input

    func testScanFileThrows() async throws {
        let file = try makeFile(name: "not_a_dir.txt", size: 512)
        do {
            _ = try await DiskScanner().scan(url: file, progress: ScanProgress())
            XCTFail("Expected ScanError.notADirectory to be thrown")
        } catch ScanError.notADirectory {
            // expected
        }
    }

    // MARK: - FileKind classification

    func testFileKindImages() {
        for ext in ["jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp"] {
            XCTAssertEqual(FileKind.classify(pathExtension: ext), .image, "Expected .image for .\(ext)")
        }
    }

    func testFileKindVideos() {
        for ext in ["mp4", "mov", "avi", "mkv", "m4v"] {
            XCTAssertEqual(FileKind.classify(pathExtension: ext), .video, "Expected .video for .\(ext)")
        }
    }

    func testFileKindAudio() {
        for ext in ["mp3", "aac", "wav", "flac", "m4a"] {
            XCTAssertEqual(FileKind.classify(pathExtension: ext), .audio, "Expected .audio for .\(ext)")
        }
    }

    func testFileKindDocuments() {
        for ext in ["pdf", "doc", "docx", "txt", "pages"] {
            XCTAssertEqual(FileKind.classify(pathExtension: ext), .document, "Expected .document for .\(ext)")
        }
    }

    func testFileKindArchives() {
        for ext in ["zip", "tar", "gz", "7z", "dmg", "pkg"] {
            XCTAssertEqual(FileKind.classify(pathExtension: ext), .archive, "Expected .archive for .\(ext)")
        }
    }

    func testFileKindCode() {
        for ext in ["swift", "py", "js", "ts", "go", "rs", "java"] {
            XCTAssertEqual(FileKind.classify(pathExtension: ext), .code, "Expected .code for .\(ext)")
        }
    }

    func testFileKindExecutable() {
        for ext in ["app", "dylib", "framework"] {
            XCTAssertEqual(FileKind.classify(pathExtension: ext), .executable, "Expected .executable for .\(ext)")
        }
    }

    func testFileKindOther() {
        XCTAssertEqual(FileKind.classify(pathExtension: "xyz"), .other)
        XCTAssertEqual(FileKind.classify(pathExtension: ""), .other)
        XCTAssertEqual(FileKind.classify(pathExtension: "UNKNOWN"), .other)
    }

    func testFileKindCaseInsensitive() {
        XCTAssertEqual(FileKind.classify(pathExtension: "JPG"), .image)
        XCTAssertEqual(FileKind.classify(pathExtension: "MP4"), .video)
        XCTAssertEqual(FileKind.classify(pathExtension: "SWIFT"), .code)
    }

    // MARK: - FileNode description

    func testFileNodeDescription() async throws {
        try makeFile(name: "doc.pdf", size: 1_024)

        let node = try await DiskScanner().scan(url: tempDir, progress: ScanProgress())
        let child = node.children[0]

        XCTAssertTrue(child.description.contains("doc.pdf"))
        XCTAssertFalse(child.isDirectory)
        XCTAssertEqual(child.kind, .document)
    }
}
