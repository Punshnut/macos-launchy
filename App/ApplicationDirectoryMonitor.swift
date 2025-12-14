import Foundation
import Dispatch
import Darwin

/// Watches key application directories and notifies when their contents change.
final class ApplicationDirectoryMonitor {
    private struct Observation {
        let descriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private let queue: DispatchQueue
    private let debounceInterval: TimeInterval
    private let pollingInterval: TimeInterval?
    private let changeHandler: () -> Void
    private var observations: [Observation] = []
    private var pendingWorkItem: DispatchWorkItem?
    private var pollingSource: DispatchSourceTimer?

    init(
        directories: [URL],
        debounceInterval: TimeInterval = 1.25,
        pollingInterval: TimeInterval? = nil,
        queue: DispatchQueue = DispatchQueue(label: "launchy.app-directory-monitor", qos: .utility),
        changeHandler: @escaping () -> Void
    ) {
        self.queue = queue
        self.debounceInterval = debounceInterval
        self.pollingInterval = pollingInterval
        self.changeHandler = changeHandler
        observe(directories: directories)
        startPollingIfNeeded()
    }

    deinit {
        stop()
    }

    /// Cancels all observations and stops scheduling refresh callbacks.
    func stop() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        for observation in observations {
            observation.source.cancel()
        }
        observations.removeAll()
        pollingSource?.cancel()
        pollingSource = nil
    }

    /// Registers file system watchers for the provided application directories.
    private func observe(directories: [URL]) {
        let directoriesToWatch = uniqueDirectories(from: directories)
        for directory in directoriesToWatch {
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }
            guard let descriptor = openDirectoryDescriptor(at: directory.path) else {
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [
                    .write,
                    .delete,
                    .extend,
                    .attrib,
                    .rename,
                    .link
                ],
                queue: queue
            )

            source.setEventHandler { [weak self] in
                self?.scheduleChange()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            observations.append(Observation(descriptor: descriptor, source: source))
        }
    }

    /// Deduplicates directory paths so we do not double-register observers.
    private func uniqueDirectories(from directories: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        for directory in directories {
            let standardized = directory.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            unique.append(standardized)
        }
        return unique
    }

    /// Opens a directory descriptor suitable for monitoring file system events.
    private func openDirectoryDescriptor(at path: String) -> Int32? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        return descriptor
    }

    private func startPollingIfNeeded() {
        guard let pollingInterval, pollingInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        timer.resume()
        pollingSource = timer
    }

    /// Debounces rapid file system signals before invoking the caller's handler.
    private func scheduleChange() {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingWorkItem = nil
            self.changeHandler()
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
