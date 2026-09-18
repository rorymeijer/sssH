import CoreTransferable
import Foundation
import ssshCore
import UniformTypeIdentifiers

extension UTType {
    /// A private type for dragging between the two panes.
    ///
    /// A private type rather than `public.file-url`, because a remote file has
    /// no URL: it exists on another machine and the only handle on it is a
    /// path plus the connection it belongs to. Advertising it as a file URL
    /// would let other apps accept a drop they cannot actually read.
    static let ssshFileSelection = UTType(exportedAs: "nl.rorymeijer.sssh.file-selection")
}

/// What a drag between the two panes carries.
struct DraggedFiles: Codable, Transferable {
    enum Origin: Codable, Hashable {
        /// The directory the files were dragged out of.
        case local(directory: String)
        case remote(directory: String, sessionID: UUID)
    }

    var origin: Origin
    var names: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ssshFileSelection)
    }
}
