import Foundation

/// Pure parsing for drop-to-add payloads. Extracted out of the playlist
/// screen so the "what counts as a droppable track-id list" contract — which
/// `PlaylistView.handleDrop` leans on to decide acceptance and error
/// surfacing (#236) — can be unit-tested without an `NSItemProvider` or a
/// SwiftUI scene. Lived in the retired `PlaylistDetailView` until #985
/// consolidated the playlist surfaces.
enum PlaylistDropPayload {
    /// Pull a list of track ids out of arbitrary dropped bytes. Tries JSON
    /// first (a `["id-1","id-2"]` array of strings), then newline-separated
    /// text; ignores blanks and surrounding whitespace.
    static func parseTrackIds(from data: Data) -> [String] {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return json.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
