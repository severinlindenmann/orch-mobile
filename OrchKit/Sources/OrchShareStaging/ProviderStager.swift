import Foundation
import UniformTypeIdentifiers

/// Turns one `NSItemProvider` into one staged item. Rules (S1/C4):
/// - Files enter ONLY as the framework's temporary copy (`loadFileRepresentation`), or, for a provider that exposes
///   nothing but `public.file-url`, as a strict file URL (container and home checks apply).
/// - A text or URL value never becomes a file: a URL is stored as its string, a file URL included.
public enum ProviderStager {
    @MainActor public static func stage(_ p: NSItemProvider, into session: StagingSession) async throws {
        let fileURL = UTType.fileURL.identifier
        if p.hasItemConformingToTypeIdentifier(fileURL) {
            if let type = advertisedDataType(p) {
                try await copyRepresentation(p, type: type, session: session)
            } else {
                try await copyFileURLValue(p, session: session)
            }
        } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            switch try await loadValue(p, UTType.url.identifier, cap: session.remainingBytes) {
            case .url(let url): try session.add(.url(url.absoluteString))
            case .string(let text): try session.add(.url(text))
            default: throw ShareError.unsupported("url")
            }
        } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            let id = p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ? UTType.plainText.identifier : UTType.text.identifier
            switch try await loadValue(p, id, cap: session.remainingBytes) {
            case .string(let text): try session.add(.text(text))
            case .data(let data): try session.add(.text(String(decoding: data, as: UTF8.self)))
            case .url(let url): try session.add(.text(url.absoluteString))   // never read as a file
            case .other: throw ShareError.unsupported("text")
            }
        } else if let type = advertisedDataType(p) {
            try await copyRepresentation(p, type: type, session: session)
        } else {
            throw ShareError.unsupported("type")
        }
    }

    /// A provider's value reduced to Sendable data inside the completion handler (`NSSecureCoding` is not Sendable).
    enum LoadedValue: Sendable { case url(URL), data(Data), string(String), other }

    /// Cap the data representation before decoding or making any further text/data copies.
    @MainActor static func loadValue(_ p: NSItemProvider, _ type: String, cap: Int) async throws -> LoadedValue {
        // URL representations are values; never ask the
        // framework to turn a file URL into the contents of the referenced file.
        if type == UTType.fileURL.identifier || type == UTType.url.identifier {
            return try await withCheckedThrowingContinuation { (c: CheckedContinuation<LoadedValue, Error>) in
                p.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                    if let error { c.resume(throwing: error); return }
                    if let url = value as? URL {
                        guard url.absoluteString.utf8.count <= cap else { c.resume(throwing: ShareError.tooLarge); return }
                        c.resume(returning: .url(url))
                    } else if let data = value as? Data {
                        guard data.count <= cap else { c.resume(throwing: ShareError.tooLarge); return }
                        c.resume(returning: URL(dataRepresentation: data, relativeTo: nil).map(LoadedValue.url) ?? .other)
                    } else if let text = value as? String {
                        guard text.utf8.count <= cap else { c.resume(throwing: ShareError.tooLarge); return }
                        c.resume(returning: .string(text))
                    } else { c.resume(returning: .other) }
                }
            }
        }
        // Inspect the value first: requesting data for an NSURL advertised as text can
        // make Foundation read the referenced file instead of returning the URL string.
        let url: URL? = try await withCheckedThrowingContinuation { c in
            p.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { c.resume(throwing: error); return }
                if let url = item as? URL {
                    guard url.absoluteString.utf8.count <= cap else { c.resume(throwing: ShareError.tooLarge); return }
                    c.resume(returning: url)
                    return
                }
                // Refuse oversized values before requesting another representation or decoding.
                if let data = item as? Data, data.count > cap {
                    c.resume(throwing: ShareError.tooLarge); return
                }
                if let text = item as? String, text.utf8.count > cap {
                    c.resume(throwing: ShareError.tooLarge); return
                }
                c.resume(returning: nil)
            }
        }
        if let url { return .url(url) }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<LoadedValue, Error>) in
            p.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { c.resume(throwing: error); return }
                guard let data else { c.resume(returning: .other); return }
                guard data.count <= cap else { c.resume(throwing: ShareError.tooLarge); return }
                c.resume(returning: .data(data))
            }
        }
    }

    /// A content type the provider genuinely advertises as data (not a URL, whose supertype is also data).
    static func advertisedDataType(_ p: NSItemProvider) -> UTType? {
        p.registeredContentTypes.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
    }

    @MainActor private static func copyRepresentation(_ p: NSItemProvider, type: UTType, session: StagingSession) async throws {
        let name = p.suggestedName
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            _ = p.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { c.resume(throwing: error ?? ShareError.unsupported("load")); return }
                do {
                    var display = name ?? url.lastPathComponent
                    if (display as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension { display += "." + ext }
                    try session.add(.providerCopy(url, name: display, type: type.identifier))
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
    }

    /// Provider with only `public.file-url`: the extension itself reads the file while access is valid.
    @MainActor private static func copyFileURLValue(_ p: NSItemProvider, session: StagingSession) async throws {
        let value = try await loadValue(p, UTType.fileURL.identifier, cap: session.remainingBytes)
        guard case .url(let url) = value, url.isFileURL else { throw ShareError.unsupported("file url") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try session.add(.file(url, name: p.suggestedName ?? url.lastPathComponent, type: nil))
    }
}
