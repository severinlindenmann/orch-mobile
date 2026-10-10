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
            switch try await loadValue(p, UTType.url.identifier) {
            case .url(let url): try session.add(.url(url.absoluteString))
            case .string(let text): try session.add(.url(text))
            default: throw ShareError.unsupported("url")
            }
        } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            let id = p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ? UTType.plainText.identifier : UTType.text.identifier
            switch try await loadValue(p, id) {
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

    /// Completion-handler variant on purpose: the async `loadItem` returns a non-Sendable value, which older compilers reject.
    @MainActor static func loadValue(_ p: NSItemProvider, _ type: String) async throws -> LoadedValue {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<LoadedValue, Error>) in
            p.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { c.resume(throwing: error); return }
                // Providers hand a URL back as a URL or as its data representation.
                if let url = item as? URL { c.resume(returning: .url(url)) }
                else if let text = item as? String { c.resume(returning: .string(text)) }
                else if let data = item as? Data {
                    if type == UTType.url.identifier || type == UTType.fileURL.identifier,
                       let url = URL(dataRepresentation: data, relativeTo: nil) { c.resume(returning: .url(url)) }
                    else { c.resume(returning: .data(data)) }
                } else { c.resume(returning: .other) }
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
        let value = try await loadValue(p, UTType.fileURL.identifier)
        guard case .url(let url) = value, url.isFileURL else { throw ShareError.unsupported("file url") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try session.add(.file(url, name: p.suggestedName ?? url.lastPathComponent, type: nil))
    }
}
