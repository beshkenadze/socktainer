import ContainerAPIClient
import ContainerResource
import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage
import Vapor

/// Extension to add convenience computed properties for EXT4.Inode
extension EXT4.Inode {
    /// Full 64-bit file size
    var size: Int64 {
        Int64(sizeLow) | (Int64(sizeHigh) << 32)
    }

    /// Full 32-bit user ID
    var fullUid: UInt32 {
        UInt32(uid) | (UInt32(uidHigh) << 16)
    }

    /// Full 32-bit group ID
    var fullGid: UInt32 {
        UInt32(gid) | (UInt32(gidHigh) << 16)
    }

    /// Check if this is a directory
    var isDirectory: Bool {
        (mode & 0xF000) == 0x4000
    }

    /// Check if this is a regular file
    var isRegularFile: Bool {
        (mode & 0xF000) == 0x8000
    }

    /// Check if this is a symbolic link
    var isSymlink: Bool {
        (mode & 0xF000) == 0xA000
    }

    /// Permission bits only (without file type)
    var permissions: UInt16 {
        mode & 0x0FFF
    }
}

/// Errors specific to archive operations
enum ClientArchiveError: Error, LocalizedError {
    case containerNotFound(id: String)
    case pathNotFound(path: String)
    case rootfsNotFound(id: String)
    case invalidPath(path: String)
    case notADirectory(path: String)
    case operationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .containerNotFound(let id):
            return "No such container: \(id)"
        case .pathNotFound(let path):
            return "Path not found in container: \(path)"
        case .rootfsNotFound(let id):
            return "Rootfs not found for container: \(id)"
        case .invalidPath(let path):
            return "Invalid path: \(path)"
        case .notADirectory(let path):
            return "Extraction point is not a directory: \(path)"
        case .operationFailed(let message):
            return "Archive operation failed: \(message)"
        }
    }
}

/// File stat information for the X-Docker-Container-Path-Stat header
struct PathStat: Codable {
    let name: String
    let size: Int64
    let mode: UInt32
    let mtime: String
    let linkTarget: String?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case mode
        case mtime
        case linkTarget
    }
}

/// Protocol for archive operations on containers
protocol ClientArchiveProtocol: Sendable {
    /// Get the path to a container's rootfs
    func getRootfsPath(containerId: String) -> URL

    /// Read a file or directory from a container's filesystem and return as tar data.
    /// Takes the snapshot, not the id: where the bytes live depends on whether the guest is running.
    func getArchive(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat)

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws

    /// Export the container's entire root filesystem as an uncompressed tar
    /// (docker export). The caller owns the returned file and deletes it when done.
    func exportRootfs(containerId: String) async throws -> URL
}

/// Service for performing archive operations on container filesystems
struct ClientArchiveService: ClientArchiveProtocol {
    private static let log = Logger(label: "socktainer.archive")
    private let appSupportPath: URL

    init(appSupportPath: URL) {
        self.appSupportPath = appSupportPath
    }

    /// Get the path to a container's rootfs.ext4 file
    func getRootfsPath(containerId: String) -> URL {
        appSupportPath
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
            .appendingPathComponent("rootfs.ext4")
    }

    /// A running guest owns the filesystem. Its writes sit in the VM's page cache and do not reach
    /// `rootfs.ext4` on the host — measured: a file written through `exec` was still missing from the
    /// image 45 seconds later, and only a `sync` inside the guest ever brought it across. Reading the
    /// image therefore answers with the container's past, which is how every runtime-written file came
    /// back 404 while `docker exec cat` printed it (ContainerStack #10).
    ///
    /// So while the guest runs, it packs the path itself, over the channel `docker exec` already uses;
    /// once it is gone the image is the whole truth and is read directly.
    func getArchive(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat) {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        if container.status == .running {
            do {
                return try await getArchiveViaGuestTar(container: container, path: normalizedPath)
            } catch let error as ClientArchiveError {
                // A running guest is the authority on its own filesystem: if it says the path is not
                // there, it is not there, and falling back to the image would resurrect a deleted file.
                if case .pathNotFound = error { throw error }
                Self.log.warning("guest could not pack \(normalizedPath), reading the image instead: \(error)")
            } catch {
                Self.log.warning("guest could not pack \(normalizedPath), reading the image instead: \(error)")
            }
        }

        return try getArchiveFromImage(containerId: container.id, normalizedPath: normalizedPath)
    }

    /// Reads the path out of the container's `rootfs.ext4` on the host. Correct for a container that
    /// is not running, and the fallback for a running one whose image has no `tar`.
    private func getArchiveFromImage(containerId: String, normalizedPath: String) throws -> (tarData: Data, stat: PathStat) {
        let rootfsPath = getRootfsPath(containerId: containerId)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }

        // Open the ext4 filesystem
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))

        guard let (_, inode) = Self.lstat(reader: reader, path: normalizedPath) else {
            throw ClientArchiveError.pathNotFound(path: normalizedPath)
        }

        // Create PathStat for the response header
        let pathStat = PathStat(
            name: (normalizedPath as NSString).lastPathComponent,
            size: inode.size,
            mode: UInt32(inode.mode),
            mtime: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(inode.mtime))),
            linkTarget: inode.isSymlink ? readSymlinkTarget(reader: reader, path: normalizedPath) : nil
        )

        // Create temporary directory for tar creation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let stagingDir = tempDir.appendingPathComponent("\(sessionId)-staging")
        let tarPath = tempDir.appendingPathComponent("\(sessionId).tar")

        defer {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: tarPath)
        }

        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        // Extract the requested path to the staging directory
        try extractPathToDirectory(reader: reader, sourcePath: normalizedPath, destDir: stagingDir)

        // Create tar archive from the staging directory
        try ArchiveUtility.create(tarPath: tarPath, from: stagingDir)

        // Read the tar data
        let tarData = try Data(contentsOf: tarPath)

        return (tarData: tarData, stat: pathStat)
    }

    /// Has the guest pack the path with its own `tar`, and reads the archive off its stdout.
    ///
    /// `tar` is asked for rather than the runtime's `copyOut` because that call hangs forever on a
    /// path the guest does not have: the guest reports `notFound` immediately in its log, but the
    /// host side waits on metadata that never arrives while holding the container's state lock, so
    /// one 404 — which clients ask for routinely — wedges the container and, with it, new container
    /// creation. Filed as ContainerStack #49. `tar` also carries what `copyOut` drops: it writes a
    /// single file with mode 0644 and no owner, while the archive keeps modes, ownership, symlinks
    /// and mtimes exactly as the container has them.
    ///
    /// The cost is a dependency on `tar` inside the image. Every image with a shell has one; a
    /// `scratch` or distroless one does not, and its read falls back to the host image, which is the
    /// behaviour it had before this path existed.
    private func getArchiveViaGuestTar(container: ContainerSnapshot, path: String) async throws -> (tarData: Data, stat: PathStat) {
        let (parent, name) = Self.splitForTar(path)

        var processConfig = container.configuration.initProcess
        processConfig.executable = "tar"
        // `-C parent name` makes the archive's top entry the requested path itself, the shape docker
        // returns, rather than the absolute path with every parent directory along the way.
        processConfig.arguments = ["-cf", "-", "-C", parent, name]
        processConfig.terminal = false
        // Read as root: the image's own user may not be able to see the path the client asked for.
        processConfig.user = .id(uid: 0, gid: 0)

        guard let pipes = StdioPipes.make([.stdout, .stderr]) else {
            throw ClientArchiveError.operationFailed(message: "Failed to create pipes for reading \(path)")
        }

        let process: ClientProcess
        do {
            process = try await ContainerClient().createProcess(
                containerId: container.id,
                processId: UUID().uuidString.lowercased(),
                configuration: processConfig,
                stdio: pipes.stdioArray
            )
        } catch {
            pipes.closeAll()
            throw ClientArchiveError.operationFailed(message: "no tar in \(container.id): \(error.localizedDescription)")
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw ClientArchiveError.operationFailed(message: "no tar in \(container.id): \(error.localizedDescription)")
        }

        // Both pipes must be drained while the process runs: tar fills stdout with the archive and
        // blocks once the pipe buffer is full, so waiting for the exit first would deadlock.
        let stdoutReader = pipes.stdout!.read
        let stdoutTask = Task.detached { () -> Data in
            defer { try? stdoutReader.close() }
            var collected = Data()
            while let chunk = try? stdoutReader.read(upToCount: 256 * 1024), !chunk.isEmpty {
                collected.append(chunk)
            }
            return collected
        }
        let stderrReader = pipes.stderr!.read
        let stderrTask = Task.detached { () -> Data in
            defer { try? stderrReader.close() }
            var collected = Data()
            while let chunk = try? stderrReader.read(upToCount: 4096), !chunk.isEmpty {
                if collected.count < 16 * 1024 { collected.append(chunk) }
            }
            return collected
        }

        let exitCode: Int32
        do {
            exitCode = try await process.wait()
        } catch {
            throw ClientArchiveError.operationFailed(
                message: "Failed waiting for tar in running container: \(error.localizedDescription)")
        }

        let tarData = await stdoutTask.value
        let stderrText = String(data: await stderrTask.value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard exitCode == 0 else {
            // busybox and GNU tar both name a missing path this way and exit non-zero; anything else
            // is a failure of the mechanism, and the caller falls back to reading the host image.
            if stderrText.localizedCaseInsensitiveContains("No such file or directory") {
                throw ClientArchiveError.pathNotFound(path: path)
            }
            throw ClientArchiveError.operationFailed(message: "tar exited \(exitCode) in \(container.id): \(stderrText)")
        }

        return (tarData: tarData, stat: try Self.pathStat(fromTar: tarData, path: path))
    }

    /// `/etc/hostname` packs as `-C /etc hostname`; the root itself has no name to pass, so it packs
    /// as `-C / .` the way `tar` names a whole directory.
    static func splitForTar(_ path: String) -> (parent: String, name: String) {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed != "/" else { return ("/", ".") }
        let parent = (trimmed as NSString).deletingLastPathComponent
        return (parent.isEmpty ? "/" : parent, (trimmed as NSString).lastPathComponent)
    }

    /// The stat header describes the path the client asked for, which is the archive's first entry —
    /// so it is read back from what the guest packed rather than asked for a second time over a
    /// second channel that could disagree.
    static func pathStat(fromTar tarData: Data, path: String) throws -> PathStat {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("guest-tar-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try tarData.write(to: scratch)

        let reader = try ArchiveReader(format: .paxRestricted, filter: .none, file: scratch)
        var iterator = reader.makeStreamingIterator()
        guard let (entry, _) = iterator.next() else {
            throw ClientArchiveError.pathNotFound(path: path)
        }

        let typeBits: UInt32 =
            switch entry.fileType {
            case .directory: UInt32(S_IFDIR)
            case .symbolicLink: UInt32(S_IFLNK)
            default: UInt32(S_IFREG)
            }
        return PathStat(
            name: (path as NSString).lastPathComponent,
            size: entry.size ?? 0,
            // Raw Unix mode, matching what the image read reports for the same file, so a client
            // cannot see the mode change under it when a container starts or stops.
            mode: UInt32(entry.permissions) | typeBits,
            mtime: ISO8601DateFormatter().string(from: entry.modificationDate ?? Date(timeIntervalSince1970: 0)),
            linkTarget: typeBits == UInt32(S_IFLNK) ? entry.symlinkTarget : nil
        )
    }

    /// Reading rootfs.ext4 while the guest VM writes to it is a volatile
    /// snapshot — the same guarantee moby gives when exporting a running
    /// container's mounted layer. The export runs detached because it is
    /// synchronous I/O that can take minutes for large filesystems.
    func exportRootfs(containerId: String) async throws -> URL {
        let rootfsPath = getRootfsPath(containerId: containerId)
        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: containerId)
        }
        let tarPath = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).tar")
        let blockDevicePath = rootfsPath.path
        let archivePath = tarPath.path
        do {
            try await Task.detached(priority: .utility) {
                let reader = try EXT4.EXT4Reader(blockDevice: FilePath(blockDevicePath))
                try reader.export(archive: FilePath(archivePath))
            }.value
        } catch {
            try? FileManager.default.removeItem(at: tarPath)
            throw ClientArchiveError.operationFailed(message: "failed to read rootfs of \(containerId): \(error)")
        }
        return tarPath
    }

    /// Extract a tar archive into a container's filesystem at the specified path
    func putArchive(container: ContainerSnapshot, path: String, tarPath: URL, noOverwriteDirNonDir: Bool) async throws {
        // Normalize the destination path
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        // A running container's VM holds rootfs.ext4 open as its block device:
        // rewriting and swapping the file on the host is never seen by the guest
        // (and guest writes would diverge from the swapped file). Inject through
        // the live container instead.
        if container.status == .running {
            try await putArchiveViaCopyIn(
                container: container,
                destinationPath: normalizedPath,
                tarPath: tarPath,
                noOverwriteDirNonDir: noOverwriteDirNonDir
            )
            return
        }

        let rootfsPath = getRootfsPath(containerId: container.id)

        guard FileManager.default.fileExists(atPath: rootfsPath.path) else {
            throw ClientArchiveError.rootfsNotFound(id: container.id)
        }

        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        try validateArchiveEntries(
            reader: reader,
            tarPath: tarPath,
            destinationPath: normalizedPath,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        try await putArchiveFallback(
            rootfsPath: rootfsPath,
            destinationPath: normalizedPath,
            inputTarPath: tarPath
        )
    }

    /// One parsed entry of the uploaded archive.
    private struct ArchiveEntryPlan {
        enum Kind {
            case directory
            case file
            case symlink(target: String)
        }
        let relativePath: String
        let guestPath: String
        let kind: Kind
        let mode: UInt32
    }

    /// Inject the archive into a RUNNING container.
    ///
    /// Docker semantics require extracting *into* the destination without
    /// disturbing what already exists (e.g. a tar entry `tmp/foo` must not
    /// change the ownership/mode/sticky bit of an existing `/tmp`). So instead
    /// of pushing whole directories through copyIn (whose in-guest extraction
    /// applies archived directory metadata over existing directories), this:
    ///  1. runs ONE `/bin/sh` exec in the guest that validates the destination
    ///     (404/400/conflict semantics that copyIn cannot express) and creates
    ///     missing directories and symlinks (`mkdir` skips existing dirs), then
    ///  2. streams each regular file individually over vsock via the daemon's
    ///     copyIn API with the mode recorded in the tar.
    private func putArchiveViaCopyIn(
        container: ContainerSnapshot,
        destinationPath: String,
        tarPath: URL,
        noOverwriteDirNonDir: Bool
    ) async throws {
        let plan = try parseArchiveEntries(tarPath: tarPath, destinationPath: destinationPath)

        try await prepareGuestForCopy(
            container: container,
            destinationPath: destinationPath,
            entries: plan,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        let files = plan.filter {
            if case .file = $0.kind { return true }
            return false
        }
        guard !files.isEmpty else { return }

        // Unpack the uploaded tar to a staging directory for the file contents
        // (modes are taken from the tar entries, not the staged files).
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("put-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        try ArchiveUtility.extract(tarPath: tarPath, to: stagingDir)

        let client = ContainerClient()
        for file in files {
            let stagedURL = stagingDir.appendingPathComponent(file.relativePath)
            guard FileManager.default.fileExists(atPath: stagedURL.path) else {
                throw ClientArchiveError.operationFailed(message: "archive entry missing after extraction: \(file.relativePath)")
            }
            do {
                try await client.copyIn(
                    id: container.id,
                    source: stagedURL.path,
                    destination: file.guestPath,
                    mode: file.mode
                )
            } catch {
                throw ClientArchiveError.operationFailed(
                    message: "Failed to copy \(file.relativePath) into running container: \(error.localizedDescription)")
            }
        }
    }

    /// Parse the uploaded tar into a copy plan.
    private func parseArchiveEntries(tarPath: URL, destinationPath: String) throws -> [ArchiveEntryPlan] {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        var plan: [ArchiveEntryPlan] = []
        for (entry, _) in archiveReader.makeStreamingIterator() {
            guard let entryPath = entry.path,
                let guestPath = ArchiveUtility.destinationPath(for: entryPath, under: destinationPath),
                guestPath != destinationPath
            else {
                continue
            }

            var relativePath = entryPath
            if relativePath.hasPrefix("./") {
                relativePath = String(relativePath.dropFirst(2))
            }

            let mode = UInt32(entry.permissions) & 0o7777
            switch entry.fileType {
            case .directory:
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .directory, mode: mode))
            case .regular:
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .file, mode: mode))
            case .symbolicLink:
                guard let target = entry.symlinkTarget else { continue }
                plan.append(.init(relativePath: relativePath, guestPath: guestPath, kind: .symlink(target: target), mode: mode))
            default:
                throw ClientArchiveError.operationFailed(
                    message: "unsupported archive entry type for copy into a running container: \(relativePath)")
            }
        }
        return plan
    }

    /// Run Docker's PUT-archive validation inside the running guest and create
    /// the directory/symlink structure for the incoming archive: destination
    /// must exist (404) and be a directory (400), optional per-entry
    /// noOverwriteDirNonDir conflict checks, `mkdir` for missing directories
    /// (existing ones are left untouched), and `ln -sfn` for symlinks.
    private func prepareGuestForCopy(
        container: ContainerSnapshot,
        destinationPath: String,
        entries: [ArchiveEntryPlan],
        noOverwriteDirNonDir: Bool
    ) async throws {
        let script = buildPreparationScript(
            entries: entries,
            noOverwriteDirNonDir: noOverwriteDirNonDir
        )

        var processConfig = container.configuration.initProcess
        processConfig.executable = "/bin/sh"
        processConfig.arguments = ["-c", script, "sh", destinationPath]
        processConfig.terminal = false
        // Validate as root so restrictive permissions on parent directories
        // cannot mask the existence checks.
        processConfig.user = .id(uid: 0, gid: 0)

        guard let pipes = StdioPipes.make([.stderr]) else {
            throw ClientArchiveError.operationFailed(message: "Failed to create stderr pipe")
        }

        let process: ClientProcess
        do {
            process = try await ContainerClient().createProcess(
                containerId: container.id,
                processId: UUID().uuidString.lowercased(),
                configuration: processConfig,
                stdio: pipes.stdioArray
            )
        } catch {
            pipes.closeAll()
            throw ClientArchiveError.operationFailed(message: "Failed to exec into running container: \(error.localizedDescription)")
        }
        do {
            try await process.start()
        } catch {
            pipes.closeAfterHandoff()
            throw ClientArchiveError.operationFailed(message: "Failed to exec into running container: \(error.localizedDescription)")
        }

        // Drain stderr concurrently (capped at 16 KiB) while waiting.
        // collectOutput() is not used here because it reads unboundedly via
        // readDataToEndOfFile(); this capped reader prevents runaway memory growth.
        let stderrReader = pipes.stderr!.read
        let stderrTask = Task.detached { () -> Data in
            defer { try? stderrReader.close() }
            var collected = Data()
            while let chunk = try? stderrReader.read(upToCount: 4096), !chunk.isEmpty {
                if collected.count < 16 * 1024 {
                    collected.append(chunk)
                }
            }
            return collected
        }

        let exitCode: Int32
        do {
            exitCode = try await process.wait()
        } catch {
            // Concurrent close(2) + read(2) on the same fd is unsafe (NSException risk).
            // Rethrow immediately; stderrTask exits naturally when the process terminates
            // and Apple closes the write end.
            throw ClientArchiveError.operationFailed(message: "Failed waiting for validation in running container: \(error.localizedDescription)")
        }

        let stderrText =
            String(data: await stderrTask.value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch exitCode {
        case 0:
            return
        case 40:
            throw ClientArchiveError.pathNotFound(path: destinationPath)
        case 41:
            throw ClientArchiveError.notADirectory(path: destinationPath)
        default:
            let detail = stderrText.isEmpty ? "" : ": \(stderrText)"
            throw ClientArchiveError.operationFailed(message: "Validation in running container failed (exit \(exitCode))\(detail)")
        }
    }

    /// Build the validation/preparation shell script run inside the guest.
    /// Only `sh`, `mkdir`, `ln` and `test` are required. Existing directories
    /// are never modified, mirroring how tar treats implicit parents.
    private func buildPreparationScript(
        entries: [ArchiveEntryPlan],
        noOverwriteDirNonDir: Bool
    ) -> String {
        var lines = [
            "set -u",
            "dest=\"$1\"",
            "if [ ! -e \"$dest\" ]; then echo \"destination does not exist: $dest\" >&2; exit 40; fi",
            "if [ ! -d \"$dest\" ]; then echo \"extraction point is not a directory: $dest\" >&2; exit 41; fi",
        ]

        if noOverwriteDirNonDir {
            for entry in entries {
                let quoted = shellSingleQuoted(entry.guestPath)
                if case .directory = entry.kind {
                    lines.append("if [ -e \(quoted) ] && [ ! -d \(quoted) ]; then echo \"refusing to overwrite non-directory with directory\" >&2; exit 43; fi")
                } else {
                    lines.append("if [ -d \(quoted) ]; then echo \"refusing to overwrite directory with non-directory\" >&2; exit 43; fi")
                }
            }
        }

        // Explicit directory entries: create missing ones with the archived
        // mode (parents first); never touch directories that already exist.
        let directories =
            entries
            .compactMap { entry -> (path: String, mode: UInt32)? in
                guard case .directory = entry.kind else { return nil }
                return (entry.guestPath, entry.mode)
            }
            .sorted { $0.path.count < $1.path.count }
        for directory in directories {
            let quoted = shellSingleQuoted(directory.path)
            let parent = shellSingleQuoted((directory.path as NSString).deletingLastPathComponent)
            let octal = String(directory.mode, radix: 8)
            lines.append(
                "if [ ! -d \(quoted) ]; then mkdir -p \(parent) && mkdir -m \(octal) \(quoted) || { echo \"failed to create directory \(directory.path)\" >&2; exit 44; }; fi")
        }

        // Implicit parents of file/symlink entries (mkdir -p is a no-op on
        // existing directories).
        var parents = Set<String>()
        for entry in entries {
            if case .directory = entry.kind { continue }
            let parent = (entry.guestPath as NSString).deletingLastPathComponent
            if !parent.isEmpty, parent != "/" {
                parents.insert(parent)
            }
        }
        for parent in parents.sorted() {
            lines.append("mkdir -p \(shellSingleQuoted(parent)) || { echo \"failed to create parent directory \(parent)\" >&2; exit 44; }")
        }

        for entry in entries {
            guard case .symlink(let target) = entry.kind else { continue }
            lines.append(
                "ln -sfn \(shellSingleQuoted(target)) \(shellSingleQuoted(entry.guestPath)) || { echo \"failed to create symlink \(entry.guestPath)\" >&2; exit 45; }")
        }

        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Fallback PUT using full read-modify-write approach
    private func putArchiveFallback(
        rootfsPath: URL,
        destinationPath: String,
        inputTarPath: URL
    ) async throws {
        // Create temporary files for the operation
        let tempDir = FileManager.default.temporaryDirectory
        let sessionId = UUID().uuidString
        let exportedTarPath = tempDir.appendingPathComponent("\(sessionId)-export.tar")
        let newRootfsPath = tempDir.appendingPathComponent("\(sessionId)-rootfs.ext4")

        defer {
            try? FileManager.default.removeItem(at: exportedTarPath)
            try? FileManager.default.removeItem(at: newRootfsPath)
        }

        // Step 1: Export existing filesystem to tar
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfsPath.path))
        try reader.export(archive: FilePath(exportedTarPath.path))

        // Step 2: Get the size of the existing rootfs to create a new one of similar size
        let rootfsAttributes = try FileManager.default.attributesOfItem(atPath: rootfsPath.path)
        let rootfsSize = (rootfsAttributes[.size] as? UInt64) ?? (2 * 1024 * 1024 * 1024)  // Default 2GB

        // Step 3: Create a new ext4 formatter
        // Use a minimum size that can accommodate the filesystem
        let minSize = max(rootfsSize, 256 * 1024)  // At least 256KB
        let formatter = try EXT4.Formatter(
            FilePath(newRootfsPath.path),
            blockSize: 4096,
            minDiskSize: minSize
        )

        // Step 4: Unpack the existing filesystem
        let existingReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: exportedTarPath
        )
        try await formatter.unpack(reader: existingReader)

        // Step 5: Unpack the new tar at the specified destination path
        try ArchiveUtility.unpack(
            tarPath: inputTarPath,
            to: formatter,
            destinationPath: destinationPath
        )

        // Step 6: Finalize the new filesystem
        try formatter.close()

        // Step 7: Atomically replace the old rootfs with the new one
        let backupPath = rootfsPath.appendingPathExtension("backup")
        try? FileManager.default.removeItem(at: backupPath)

        // Move old rootfs to backup
        try FileManager.default.moveItem(at: rootfsPath, to: backupPath)

        do {
            // Move new rootfs into place
            try FileManager.default.moveItem(at: newRootfsPath, to: rootfsPath)
            // Remove backup on success
            try? FileManager.default.removeItem(at: backupPath)
        } catch {
            // Restore backup on failure
            try? FileManager.default.moveItem(at: backupPath, to: rootfsPath)
            throw ClientArchiveError.operationFailed(message: "Failed to replace rootfs: \(error.localizedDescription)")
        }
    }

    /// `lstat`: describe the entry itself, never what it points at — which is what tar stores and what
    /// moby's archive path does (`os.Lstat`, daemon/archive_unix.go).
    ///
    /// `EXT4Reader` has no lstat. Its `followSymlinks` flag applies to *every* component of the path,
    /// not just the last one, so asking it not to follow also refuses to walk *through* a symlinked
    /// directory: `/var/run/app.sock` where `/var/run -> /run` stops dead at `run`. Hence two steps —
    /// describe the entry without following, and if the walk could not get there, resolve normally.
    ///
    /// Residual divergence, deliberate: a path whose parent chain contains a symlink *and* whose final
    /// component is one too is archived as its target rather than as a link. moby would store the
    /// link. The alternative is re-implementing symlink resolution here, and returning the target's
    /// bytes is the smaller lie than 404 for a path that plainly exists.
    static func lstat(reader: EXT4.EXT4Reader, path: String) -> (EXT4.InodeNumber, EXT4.Inode)? {
        if let entry = try? reader.stat(FilePath(path), followSymlinks: false) {
            return entry
        }
        return try? reader.stat(FilePath(path), followSymlinks: true)
    }

    /// The target a symlink points at, read the way the reader's own exporter reads it.
    ///
    /// `readFile` cannot: it rejects any inode that is not a regular file, so every symlink came back
    /// nil and was dropped from the archive entirely — `docker cp <ctr>:/etc .` silently lost `mtab`,
    /// `os-release` and friends instead of copying them as links.
    ///
    /// ext4 stores a target shorter than 60 bytes inline in the inode's block array (a "fast
    /// symlink"), which is what EXT4Reader+Export reads. A longer target lives in data blocks, and
    /// reaching those needs block arithmetic the reader keeps private, so such an entry is logged and
    /// skipped rather than guessed at.
    private func readSymlinkTarget(reader: EXT4.EXT4Reader, path: String) -> String? {
        guard let (_, inode) = try? reader.stat(FilePath(path), followSymlinks: false), inode.isSymlink else {
            return nil
        }
        let size = Int(inode.size)
        guard size > 0 else { return nil }
        guard size < 60 else {
            // Not readable through the public API, and silence here means the entry vanishes from the
            // archive — the exact failure this whole change is about. A copy that quietly returns
            // fewer files than the container holds is worse than one that says it cannot.
            Self.log.error("symlink target of \(path) is \(size) bytes; only inline targets are readable")
            return nil
        }
        let inlineBytes = Mirror(reflecting: inode.block).children.compactMap { $0.value as? UInt8 }
        return String(bytes: inlineBytes.prefix(size), encoding: .utf8)
    }

    private func validateArchiveEntries(
        reader: EXT4.EXT4Reader,
        tarPath: URL,
        destinationPath: String,
        noOverwriteDirNonDir: Bool
    ) throws {
        let archiveReader = try ArchiveReader(
            format: .paxRestricted,
            filter: .none,
            file: tarPath
        )

        for (entry, _) in archiveReader.makeStreamingIterator() {
            guard let fullPath = ArchiveUtility.destinationPath(for: entry.path, under: destinationPath) else {
                continue
            }

            guard noOverwriteDirNonDir, reader.exists(FilePath(fullPath)) else {
                continue
            }

            let (_, inode) = try reader.stat(FilePath(fullPath))
            let existingIsDirectory = inode.isDirectory
            let incomingIsDirectory = entry.fileType == .directory

            if existingIsDirectory != incomingIsDirectory {
                throw ClientArchiveError.operationFailed(
                    message: "Refusing to overwrite \(existingIsDirectory ? "directory" : "non-directory") at \(fullPath)"
                )
            }
        }
    }

    /// Extract a path from the ext4 filesystem to a local directory
    private func extractPathToDirectory(reader: EXT4.EXT4Reader, sourcePath: String, destDir: URL) throws {
        // lstat, not stat: a symlink is archived as itself. Following it also breaks the walk
        // outright when the target is outside the filesystem — `/etc/mtab -> /proc/mounts` threw
        // and took the whole directory's archive with it.
        guard let (_, inode) = Self.lstat(reader: reader, path: sourcePath) else {
            throw ClientArchiveError.pathNotFound(path: sourcePath)
        }
        let baseName = sourcePath == "/" ? nil : (sourcePath as NSString).lastPathComponent

        if inode.isDirectory {
            let dirDest: URL
            if let baseName {
                dirDest = destDir.appendingPathComponent(baseName)
                try FileManager.default.createDirectory(at: dirDest, withIntermediateDirectories: true)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: inode.permissions)],
                    ofItemAtPath: dirDest.path
                )
            } else {
                dirDest = destDir
            }

            // Recursively extract contents
            let entries = try reader.listDirectory(FilePath(sourcePath))
            for entry in entries {
                let childPath = sourcePath == "/" ? "/\(entry)" : "\(sourcePath)/\(entry)"
                try extractPathToDirectory(reader: reader, sourcePath: childPath, destDir: dirDest)
            }
        } else if inode.isRegularFile {
            // Read file contents
            let fileData = try reader.readFile(at: FilePath(sourcePath))
            guard let baseName else {
                throw ClientArchiveError.invalidPath(path: sourcePath)
            }
            let fileDest = destDir.appendingPathComponent(baseName)

            // Write file
            try fileData.write(to: fileDest)

            // Set permissions and modification time
            let mtimeDate = Date(timeIntervalSince1970: TimeInterval(inode.mtime))
            try FileManager.default.setAttributes(
                [
                    .posixPermissions: NSNumber(value: inode.permissions),
                    .modificationDate: mtimeDate,
                ],
                ofItemAtPath: fileDest.path
            )
        } else if inode.isSymlink {
            guard let baseName else {
                throw ClientArchiveError.invalidPath(path: sourcePath)
            }
            // Dropping the entry when the target cannot be read is silent data loss: the client gets a
            // tar that is missing a file and no indication of it. ext4 stores targets under 60 bytes
            // inline; anything longer needs block arithmetic the reader keeps private, so say so.
            guard let target = readSymlinkTarget(reader: reader, path: sourcePath) else {
                throw ClientArchiveError.operationFailed(
                    message: "cannot read the symlink target of \(sourcePath); refusing to omit it from the archive"
                )
            }
            let linkDest = destDir.appendingPathComponent(baseName)
            try FileManager.default.createSymbolicLink(atPath: linkDest.path, withDestinationPath: target)
        }
        // Skip other file types (devices, fifos, sockets)
    }

}
