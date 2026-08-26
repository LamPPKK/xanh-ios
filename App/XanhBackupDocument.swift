import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let xanhPortableBackup = UTType(
        exportedAs: "io.github.lamppkk.xanhbrowser.portable-backup",
        conformingTo: .json
    )
}

struct XanhBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.xanhPortableBackup, .json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw XanhPortableBackupError.malformedDocument
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
