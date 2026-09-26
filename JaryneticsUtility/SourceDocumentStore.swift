import Foundation
import UniformTypeIdentifiers

struct StoredSourceDocument {
    let id: UUID
    let relativePath: String
    let originalFilename: String?
    let documentType: SourceDocumentType
    let importedAt: Date
}

enum SourceDocumentStoreError: LocalizedError {
    case unsupportedDocumentType
    case invalidStoredPath
    case storedDocumentMissing

    var errorDescription: String? {
        switch self {
        case .unsupportedDocumentType:
            String(localized: "Select a PDF or supported image file.")
        case .invalidStoredPath:
            String(localized: "The stored document location is invalid.")
        case .storedDocumentMissing:
            String(localized: "The imported document is no longer available.")
        }
    }
}

struct SourceDocumentStore {
    private let rootDirectoryURL: URL
    private let fileManager: FileManager

    init(
        rootDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.rootDirectoryURL = rootDirectoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.fileManager = fileManager
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> Self {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return Self(
            rootDirectoryURL: applicationSupportURL
                .appendingPathComponent("SourceDocuments", isDirectory: true),
            fileManager: fileManager
        )
    }

    func importDocument(
        from sourceURL: URL,
        importedAt: Date = Date()
    ) throws -> StoredSourceDocument {
        let documentType = try documentType(for: sourceURL)
        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try fileManager.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true
        )

        let id = UUID()
        let filename = collisionSafeFilename(
            id: id,
            pathExtension: sourceURL.pathExtension
        )
        let destinationURL = rootDirectoryURL.appendingPathComponent(filename)

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        return StoredSourceDocument(
            id: id,
            relativePath: filename,
            originalFilename: sourceURL.lastPathComponent,
            documentType: documentType,
            importedAt: importedAt
        )
    }

    func resolve(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              URL(fileURLWithPath: relativePath).lastPathComponent == relativePath else {
            throw SourceDocumentStoreError.invalidStoredPath
        }

        // Resolve both sides after the directory exists. Simulator container paths can
        // gain a symlink-resolved prefix between initialization and a later lookup.
        let resolvedRootDirectoryURL = rootDirectoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let storedURL = resolvedRootDirectoryURL
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard storedURL.deletingLastPathComponent().path == resolvedRootDirectoryURL.path else {
            throw SourceDocumentStoreError.invalidStoredPath
        }
        guard fileManager.fileExists(atPath: storedURL.path) else {
            throw SourceDocumentStoreError.storedDocumentMissing
        }
        return storedURL
    }

    func remove(relativePath: String) throws {
        let storedURL = try resolve(relativePath: relativePath)
        try fileManager.removeItem(at: storedURL)
    }

    private func documentType(for sourceURL: URL) throws -> SourceDocumentType {
        guard let contentType = UTType(filenameExtension: sourceURL.pathExtension) else {
            throw SourceDocumentStoreError.unsupportedDocumentType
        }

        if contentType.conforms(to: .pdf) {
            return .pdf
        }
        if contentType.conforms(to: .image) {
            return .image
        }
        throw SourceDocumentStoreError.unsupportedDocumentType
    }

    private func collisionSafeFilename(id: UUID, pathExtension: String) -> String {
        var candidateID = id
        var filename = makeFilename(id: candidateID, pathExtension: pathExtension)

        while fileManager.fileExists(
            atPath: rootDirectoryURL.appendingPathComponent(filename).path
        ) {
            candidateID = UUID()
            filename = makeFilename(id: candidateID, pathExtension: pathExtension)
        }
        return filename
    }

    private func makeFilename(id: UUID, pathExtension: String) -> String {
        guard !pathExtension.isEmpty else {
            return id.uuidString
        }
        return "\(id.uuidString).\(pathExtension.lowercased())"
    }
}
