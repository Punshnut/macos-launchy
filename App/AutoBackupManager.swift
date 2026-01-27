import Foundation

/// Handles creation cadence, retention, and storage for automatic backups.
struct AutoBackupManager {
    private enum Keys {
        static let lastAutoBackup = "launcher.autobackup.lastCreatedAt"
    }

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let maximumBackups = 14
    private let cadence: TimeInterval = 60 * 60 * 48 // every second day

    init(fileManager: FileManager = .default, userDefaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
    }

    /// Returns true when a new auto-backup should be created.
    func shouldCreateBackup(now: Date = Date()) -> Bool {
        guard let last = userDefaults.object(forKey: Keys.lastAutoBackup) as? Date else {
            return true
        }

        let calendar = Calendar.current
        if calendar.isDate(now, inSameDayAs: last) {
            return false // already created today
        }

        return now.timeIntervalSince(last) >= cadence
    }

    /// Last recorded auto-backup time, if any.
    func lastAutoBackupDate() -> Date? {
        userDefaults.object(forKey: Keys.lastAutoBackup) as? Date
    }

    /// Records a successful creation time.
    func recordBackup(date: Date = Date()) {
        userDefaults.set(date, forKey: Keys.lastAutoBackup)
    }

    /// Returns the directory where auto-backups are stored, creating it if needed.
    func autoBackupDirectory() throws -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let launchyDirectory = baseDirectory.appendingPathComponent("Launchy", isDirectory: true)
        let autoBackupDirectory = launchyDirectory.appendingPathComponent("AutoBackup", isDirectory: true)
        try fileManager.createDirectory(at: autoBackupDirectory, withIntermediateDirectories: true)
        return autoBackupDirectory
    }

    /// Removes the oldest backups when the cap is exceeded.
    func pruneOldBackups(in directory: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let backups = files.filter { $0.pathExtension.lowercased() == "launchybackup" }
        guard backups.count > maximumBackups else { return }

        let sorted = backups.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            return lhsDate < rhsDate
        }

        let excess = sorted.prefix(sorted.count - maximumBackups)
        for url in excess {
            try? fileManager.removeItem(at: url)
        }
    }
}
