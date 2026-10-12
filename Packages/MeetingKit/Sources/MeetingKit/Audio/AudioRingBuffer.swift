import Foundation
import Synchronization

public final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutableBufferPointer<Float>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

    public init(capacity requested: Int) {
        let cap = Self.nextPowerOfTwo(max(2, requested))
        self.capacity = cap
        self.mask = cap - 1
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    public var capacityInSamples: Int { capacity }
    public var droppedSampleCount: Int { dropped.load(ordering: .relaxed) }

    public var availableToRead: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .acquiring)
        return h - t
    }

    public var availableToWrite: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .acquiring)
        return capacity - (h - t)
    }

    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let free = capacity - (h - t)
        let toWrite = min(count, free)
        if toWrite < count {
            dropped.wrappingAdd(count - toWrite, ordering: .relaxed)
        }
        var i = 0
        while i < toWrite {
            storage[(h &+ i) & mask] = src[i]
            i &+= 1
        }
        head.store(h &+ toWrite, ordering: .releasing)
        return toWrite
    }

    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0.baseAddress!, count: $0.count) }
    }

    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let available = h - t
        let toRead = min(maxCount, available)
        var i = 0
        while i < toRead {
            dst[i] = storage[(t &+ i) & mask]
            i &+= 1
        }
        tail.store(t &+ toRead, ordering: .releasing)
        return toRead
    }

    public func readAll(max: Int = .max) -> [Float] {
        let n = min(availableToRead, max)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let readCount: Int = out.withUnsafeMutableBufferPointer { ptr in
            self.read(into: ptr.baseAddress!, maxCount: n)
        }
        if readCount < n { out.removeLast(n - readCount) }
        return out
    }

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}
