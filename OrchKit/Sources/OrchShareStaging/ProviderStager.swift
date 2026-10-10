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
            let item = try await p.loadItem(forTypeIdentifier: UTType.url.identifier)
            if let url = urlValue(item) { try session.add(.url(url.absoluteString)) }
            else if let text = item as? String { try session.add(.url(text)) }
            else { throw ShareError.unsupported("url") }
        } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) || p.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            let id = p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) ? UTType.plainText.identifier : UTType.text.identifier
            let item = try await p.loadItem(forTypeIdentifier: id)
            if let text = item as? String { try session.add(.text(text)) }
            else if let data = item as? Data { try session.add(.text(String(decoding: data, as: UTF8.self))) }
            else if let url = urlValue(item) { try session.add(.text(url.absoluteString)) }  // never read as a file
            else { throw ShareError.unsupported("text") }
        } else if let type = advertisedDataType(p) {
            try await copyRepresentation(p, type: type, session: session)
        } else {
            throw ShareError.unsupported("type")
        }
    }

    /// Providers hand a URL back as a URL or as its data representation.
    static func urlValue(_ item: Any) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
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
        let item = try await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
        guard let url = urlValue(item), url.isFileURL else { throw ShareError.unsupported("file url") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try session.add(.file(url, name: p.suggestedName ?? url.lastPathComponent, type: nil))
    }
}
