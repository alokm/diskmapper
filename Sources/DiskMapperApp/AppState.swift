import Foundation
import DiskMapper

/// App-level scan state, observable from all views.
///
/// Lives on the `@MainActor` so `@Published` changes always happen on the
/// main thread, which is what SwiftUI requires for safe UI updates.
@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    @Published var rootNode: FileNode?
    @Published var isScanning = false
    @Published var scannedCount = 0
    @Published var currentName = ""
    @Published var errorMessage: String?
    /// 0…1 when volume size is known; nil for indeterminate progress.
    @Published var scanProgress: Double? = nil
    /// Smoothed items-per-second scan rate.
    @Published var itemsPerSecond: Double = 0

    // MARK: - Private

    private(set) var lastScannedURL: URL?
    private var scanTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    // MARK: - Actions

    func rescan() {
        guard let url = lastScannedURL else { return }
        beginScan(url: url)
    }

    func beginScan(url: URL) {
        lastScannedURL = url
        cancelScan()
        isScanning = true
        rootNode = nil
        errorMessage = nil
        scannedCount = 0
        currentName = ""
        scanProgress = nil
        itemsPerSecond = 0

        let progress = ScanProgress()

        // Poll ScanProgress at 150 ms intervals while scanning.
        // snapshot() reads all fields in one lock acquisition (no actor hops).
        progressTask = Task { [weak self] in
            var lastCount = 0
            var lastTime  = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, self.isScanning else { break }

                let snap    = progress.snapshot()
                let now     = Date()
                let elapsed = now.timeIntervalSince(lastTime)

                self.scannedCount = snap.totalScanned
                self.currentName  = snap.currentName
                self.scanProgress = snap.progressFraction

                // Exponential-moving-average smoothing (α = 0.3).
                if elapsed > 0 {
                    let sample = Double(snap.totalScanned - lastCount) / elapsed
                    self.itemsPerSecond = self.itemsPerSecond * 0.7 + sample * 0.3
                }
                lastCount = snap.totalScanned
                lastTime  = now
            }
        }

        // Run the actual scan off the main actor.
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let node = try await DiskScanner().scan(url: url, progress: progress)
                self.rootNode = node
            } catch is CancellationError {
                // Intentionally cancelled — leave rootNode nil.
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.progressTask?.cancel()
            self.isScanning = false
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        progressTask?.cancel()
        isScanning = false
    }
}
