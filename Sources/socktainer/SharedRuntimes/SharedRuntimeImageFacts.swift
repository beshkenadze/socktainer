import ContainerAPIClient
import ContainerImagesServiceClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import ContainerizationOCI
import CryptoKit
import Foundation

/// The image facts that the decision of a `create` needs, from the local image store.
protocol SharedRuntimeImageFacts: Sendable {
    /// Nil when the image is not in the local store: the create route then answers 404 as before,
    /// and the client pulls the image and sends `create` again.
    func facts(reference: String, platform: Platform) async throws -> SharedRuntimeImageFactsResult?
}

struct SharedRuntimeImageFactsResult: Sendable {
    let image: SharedRuntimeImage
    let description: ImageDescription
}

enum SharedRuntimeImageFactsError: Error, Equatable, CustomStringConvertible {
    case configDigestMismatch(expected: String, actual: String)

    var description: String {
        switch self {
        case .configDigestMismatch(let expected, let actual): "image config blob has digest \(actual), its manifest says \(expected)"
        }
    }
}

extension SharedRuntimeImageFactsResult {
    /// The facts from the image config blob. The image ID is the SHA-256 of these bytes, which is
    /// what `docker image inspect` reports as `Id`; the process configuration and the declared
    /// volumes come from the same bytes.
    static func make(manifest: Manifest, configBlob: Data, description: ImageDescription) throws -> SharedRuntimeImageFactsResult {
        let digest = "sha256:" + SHA256.hash(data: configBlob).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.config.digest else {
            throw SharedRuntimeImageFactsError.configDigestMismatch(expected: manifest.config.digest, actual: digest)
        }
        let decoder = JSONDecoder()
        let image = try decoder.decode(ContainerizationOCI.Image.self, from: configBlob)
        let volumes = try decoder.decode(ImageVolumeConfiguration.self, from: configBlob).config?.Volumes
        return SharedRuntimeImageFactsResult(
            image: SharedRuntimeImage(id: digest, config: image.config, volumes: volumes), description: description)
    }
}

struct LocalImageFacts: SharedRuntimeImageFacts {
    let systemConfig: ContainerSystemConfig

    func facts(reference: String, platform: Platform) async throws -> SharedRuntimeImageFactsResult? {
        let image: ClientImage
        do {
            image = try await ImageIDResolver.get(reference, containerSystemConfig: systemConfig)
        } catch let error as ContainerizationError where error.code == .notFound {
            return nil
        }
        let manifest = try await image.manifest(for: platform)
        guard let content = try await RemoteContentStoreClient().get(digest: manifest.config.digest) else {
            throw ContainerizationError(.notFound, message: "image config blob missing: \(manifest.config.digest)")
        }
        return try .make(manifest: manifest, configBlob: try content.data(), description: image.description)
    }
}
