import Foundation
import Darwin

/// Builds the replacement on the destination's volume, then publishes it with
/// one atomic rename. Call the I/O methods from a worker queue. A failed write
/// or commit must leave the previous destination intact.
final class AtomicMediaSave: @unchecked Sendable {
    let destinationURL: URL
    let stagingURL: URL
    private let stagingDirectory: URL

    nonisolated init(destinationURL: URL) throws {
        self.destinationURL = destinationURL
        stagingDirectory = try FileManager.default.url(for: .itemReplacementDirectory,
            in: .userDomainMask, appropriateFor: destinationURL, create: true)
        stagingURL = stagingDirectory.appendingPathComponent(destinationURL.lastPathComponent)
    }

    nonisolated func commit(overwritingExisting: Bool = true) throws {
        // A missing/empty output must never replace an existing file.
        let values = try stagingURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Flush before publishing. This also surfaces a deferred disk-full/I/O
        // error while the original destination is still untouched.
        let handle = try FileHandle(forWritingTo: stagingURL)
        defer { try? handle.close() }
        try handle.synchronize()
        let code: Int32 = stagingURL.withUnsafeFileSystemRepresentation { source in
            destinationURL.withUnsafeFileSystemRepresentation { destination in
                guard let source = source, let destination = destination else { return EINVAL }
                let status = overwritingExisting ? rename(source, destination)
                    : renamex_np(source, destination, UInt32(RENAME_EXCL))
                return status == 0 ? 0 : errno
            }
        }
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }

    deinit {
        let directory = stagingDirectory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Takes ownership of an access count the caller has already acquired. Jobs
/// retain this object, so even a closed/deallocated editor releases it once.
final class SaveDirectoryLease: @unchecked Sendable {
    private let url: URL?
    nonisolated init(alreadyAccessing url: URL?) { self.url = url }
    deinit { url?.stopAccessingSecurityScopedResource() }
}
