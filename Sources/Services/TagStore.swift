import Foundation

/// Reads and writes macOS Finder tags.
///
/// Tags live in the `com.apple.metadata:_kMDItemUserTags` extended attribute as
/// a binary property list. Using the real thing rather than a private database
/// means tags set here show up in Finder, and tags set in Finder show up here.
enum TagStore {

    private static let attribute = "com.apple.metadata:_kMDItemUserTags"

    // MARK: - Reading

    static func tags(of path: String) -> [String] {
        guard let data = readAttribute(attribute, of: path) else { return [] }
        guard let list = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String] else { return [] }

        // Finder stores "Name\n<colour index>"; the label is everything before
        // the newline.
        return list.map { entry in
            entry.components(separatedBy: "\n").first ?? entry
        }.filter { !$0.isEmpty }
    }

    // MARK: - Writing

    @discardableResult
    static func setTags(_ tags: [String], on path: String) -> Bool {
        let cleaned = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }))

        if cleaned.isEmpty {
            return removeAttribute(attribute, of: path)
        }

        guard let data = try? PropertyListSerialization.data(
                fromPropertyList: cleaned, format: .binary, options: 0) else { return false }
        return writeAttribute(attribute, data: data, of: path)
    }

    @discardableResult
    static func add(_ tag: String, to path: String) -> Bool {
        var current = tags(of: path)
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || current.contains(trimmed) { return true }
        current.append(trimmed)
        return setTags(current, on: path)
    }

    @discardableResult
    static func remove(_ tag: String, from path: String) -> Bool {
        let current = tags(of: path).filter { $0 != tag }
        return setTags(current, on: path)
    }

    /// Every tag in use across a set of files, with how often each appears.
    static func vocabulary(in files: [IndexedFile]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for file in files {
            for tag in file.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.tag < $1.tag : $0.count > $1.count }
    }

    // MARK: - Extended attribute plumbing

    private static func readAttribute(_ name: String, of path: String) -> Data? {
        return path.withCString { pathPtr in
            name.withCString { namePtr -> Data? in
                let length = getxattr(pathPtr, namePtr, nil, 0, 0, 0)
                if length <= 0 { return nil }
                var buffer = [UInt8](repeating: 0, count: length)
                let read = getxattr(pathPtr, namePtr, &buffer, length, 0, 0)
                if read <= 0 { return nil }
                return Data(buffer[0 ..< read])
            }
        }
    }

    private static func writeAttribute(_ name: String, data: Data, of path: String) -> Bool {
        return path.withCString { pathPtr in
            name.withCString { namePtr -> Bool in
                let bytes = [UInt8](data)
                return setxattr(pathPtr, namePtr, bytes, bytes.count, 0, 0) == 0
            }
        }
    }

    private static func removeAttribute(_ name: String, of path: String) -> Bool {
        return path.withCString { pathPtr in
            name.withCString { namePtr -> Bool in
                let result = removexattr(pathPtr, namePtr, 0)
                // Already absent counts as success.
                return result == 0 || errno == ENOATTR
            }
        }
    }
}
