import Foundation

struct LineFramer {
    private var pending = Data()
    private var droppingOversizedLine = false
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 2 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func consume(_ data: Data, apply: (Data) -> Void) {
        for byte in data {
            if byte == 10 {
                if !droppingOversizedLine && !pending.isEmpty { apply(pending) }
                pending.removeAll(keepingCapacity: true)
                droppingOversizedLine = false
            } else if !droppingOversizedLine {
                if pending.count < maximumLineBytes {
                    pending.append(byte)
                } else {
                    pending.removeAll(keepingCapacity: true)
                    droppingOversizedLine = true
                }
            }
        }
        if pending.isEmpty { pending = Data() }
    }
}
