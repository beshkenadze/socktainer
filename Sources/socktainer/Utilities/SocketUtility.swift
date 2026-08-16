import Foundation
import Vapor

public enum UnixSocketError: Error {
    case missingHomeDirectory
}

func socketDirectory(homeDirectory: String) -> String {
    "\(homeDirectory)/.socktainer"
}

func containerSocketPath(homeDirectory: String) -> String {
    "\(socketDirectory(homeDirectory: homeDirectory))/container.sock"
}

/// Serves on exactly this path. The directory around it is locked to its owner: the socket itself is
/// world-writable so guest processes can reach it through the docker.sock relay.
public func prepareUnixSocket(for app: Application, at socketPath: String) throws {
    let socketDirectory = (socketPath as NSString).deletingLastPathComponent

    try restrictDirectoryToOwner(at: socketDirectory)

    if FileManager.default.fileExists(atPath: socketPath) {
        try FileManager.default.removeItem(atPath: socketPath)
    }

    app.http.server.configuration.hostname = ""
    app.http.server.configuration.port = 0
    app.http.server.configuration.address = .unixDomainSocket(path: socketPath)
}

public func prepareUnixSocket(for app: Application, homeDirectory: String? = nil) throws {
    guard let homeDir = homeDirectory else {
        throw UnixSocketError.missingHomeDirectory
    }
    try prepareUnixSocket(for: app, at: containerSocketPath(homeDirectory: homeDir))
}

/// The docker.sock relay mirrors this socket's mode onto the root-owned guest-side socket
/// (apple/container >= 1.1.0), so 0666 is what lets non-root guest processes connect; the
/// 0700 parent directory keeps other host users out despite the world-writable socket.
public func openUnixSocketToAllUsers(homeDirectory: String?) throws {
    guard let homeDir = homeDirectory else {
        throw UnixSocketError.missingHomeDirectory
    }
    try openSocketToAllUsers(at: containerSocketPath(homeDirectory: homeDir))
}

func restrictDirectoryToOwner(at path: String) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: path) {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    } else {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

func openSocketToAllUsers(at path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path)
}
