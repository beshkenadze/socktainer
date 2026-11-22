import ContainerResource
import Foundation

/// The volume images that containers other than the one being created name. The host writes a
/// volume's backing image (the lost+found clean-up, the copy-up) only when no other container
/// configuration names it.
enum VolumeImageWriters {
    struct Named: Equatable {
        var names: Set<String>
        var sources: Set<String>
    }

    static func named(by containers: [(id: String, mounts: [Filesystem])], except id: String?) -> Named {
        var named = Named(names: [], sources: [])
        for container in containers where container.id != id {
            for mount in container.mounts {
                if mount.isVolume, let name = mount.volumeName {
                    named.names.insert(name)
                    named.sources.insert(normalized(mount.source))
                } else if mount.isBlock {
                    named.sources.insert(normalized(mount.source))
                }
            }
        }
        return named
    }

    static func named(by snapshots: [ContainerSnapshot], except id: String?) -> Named {
        named(by: snapshots.map { (id: $0.id, mounts: $0.configuration.mounts) }, except: id)
    }

    static func mayWrite(name: String, source: String, named: Named) -> Bool {
        !named.names.contains(name) && !named.sources.contains(normalized(source))
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
