import Foundation

// MARK: - PlayQueue
//
// Mirrors Python core/queue.py (PlayQueue).
// Manages the ordered list of tracks and the current playback position within it.

@MainActor
public final class PlayQueue: ObservableObject {

    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var currentIndex: Int = -1

    // Stored before shuffle so we can restore on unshuffle.
    private var preShuffleOrder: [Track]? = nil

    public init() {}

    // MARK: - Current track

    public var currentTrack: Track? {
        guard tracks.indices.contains(currentIndex) else { return nil }
        return tracks[currentIndex]
    }

    // MARK: - Load

    /// Replace the entire queue and jump to a starting index.
    public func setTracks(_ newTracks: [Track], startAt index: Int = 0) {
        preShuffleOrder = nil
        tracks = newTracks
        currentIndex = newTracks.isEmpty ? -1 : max(0, min(index, newTracks.count - 1))
    }

    /// Append a single track; set currentIndex to 0 if queue was empty.
    public func add(_ track: Track) {
        tracks.append(track)
        if currentIndex == -1 { currentIndex = 0 }
    }

    public func clear() {
        preShuffleOrder = nil
        tracks = []
        currentIndex = -1
    }

    // MARK: - Navigation

    /// Advance to the next track and return it, or nil if the queue is exhausted.
    public func next(repeatMode: RepeatMode = .none) -> Track? {
        guard !tracks.isEmpty else { return nil }
        if repeatMode == .one { return currentTrack }

        let nextIdx = currentIndex + 1
        if nextIdx >= tracks.count {
            if repeatMode == .all {
                currentIndex = 0
            } else {
                return nil
            }
        } else {
            currentIndex = nextIdx
        }
        return currentTrack
    }

    /// Peek at the next track without advancing the index.
    public func peekNext(repeatMode: RepeatMode = .none) -> Track? {
        guard !tracks.isEmpty else { return nil }
        if repeatMode == .one { return currentTrack }

        let nextIdx = currentIndex + 1
        if nextIdx >= tracks.count {
            return repeatMode == .all ? tracks.first : nil
        }
        return tracks[nextIdx]
    }

    /// Go back to the previous track and return it.
    public func previous() -> Track? {
        guard !tracks.isEmpty else { return nil }
        currentIndex = max(0, currentIndex - 1)
        return currentTrack
    }

    // MARK: - Shuffle / unshuffle

    /// Shuffle the queue in place, keeping the current track at its new position.
    /// Stores the pre-shuffle order so `unshuffle()` can restore it.
    public func shuffle() {
        guard !tracks.isEmpty else { return }
        let current = currentTrack
        preShuffleOrder = tracks
        tracks.shuffle()
        if let current, let newIdx = tracks.firstIndex(of: current) {
            currentIndex = newIdx
        }
    }

    /// Restore the pre-shuffle order if available; otherwise no-op.
    public func unshuffle() {
        guard let original = preShuffleOrder else { return }
        let current = currentTrack
        tracks = original
        preShuffleOrder = nil
        if let current, let idx = tracks.firstIndex(of: current) {
            currentIndex = idx
        }
    }

    // MARK: - Mutations

    /// Remove the track at `index`, adjusting currentIndex accordingly.
    public func remove(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        tracks.remove(at: index)
        if tracks.isEmpty {
            currentIndex = -1
        } else if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            // Keep index (now points to the next track), but clamp to last
            currentIndex = min(currentIndex, tracks.count - 1)
        }
        // If index > currentIndex: no adjustment needed
    }

    /// Reorder tracks for SwiftUI List drag-reorder.
    public func move(from source: IndexSet, to destination: Int) {
        let current = currentTrack
        tracks.move(fromOffsets: source, toOffset: destination)
        if let current, let newIdx = tracks.firstIndex(of: current) {
            currentIndex = newIdx
        }
    }

    // MARK: - Convenience

    public var count: Int { tracks.count }
    public var isEmpty: Bool { tracks.isEmpty }
}
