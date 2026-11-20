import Foundation

enum ReverseJournalReader {
    static func read(in handle: FileHandle, before offset: UInt64,
                     blockBytes: Int = 64 * 1024, maximumLineBytes: Int = 2 * 1024 * 1024,
                     consume: (Data) -> Bool) throws {
        var position = offset
        var pending = Data()
        // An unterminated final line is still being written.
        var discarding = true

        func prepend(_ segment: Data.SubSequence) {
            guard !discarding else { return }
            if segment.count + pending.count > maximumLineBytes {
                pending = Data()
                discarding = true
            } else {
                pending.insert(contentsOf: segment, at: pending.startIndex)
            }
        }

        while position > 0 {
            try Task.checkCancellation()
            let count = Int(min(UInt64(blockBytes), position))
            position -= UInt64(count)
            try handle.seek(toOffset: position)
            let block = try handle.read(upToCount: count) ?? Data()
            var end = block.endIndex
            while let newline = block[..<end].lastIndex(of: 10) {
                prepend(block[block.index(after: newline)..<end])
                if !discarding && !pending.isEmpty && !consume(pending) { return }
                pending = Data()
                discarding = false
                end = newline
            }
            prepend(block[..<end])
        }
        if !discarding && !pending.isEmpty { _ = consume(pending) }
    }
}
