import Foundation

/// Cancellation is independent of the task/actor that owns a calculation. A retired
/// worker can drain while its replacement waits, without blocking the main actor.
public final class NearestNeighborCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var canceled = false

    public init() {}

    public func cancel() {
        lock.lock()
        canceled = true
        lock.unlock()
    }

    public func checkCancellation() throws {
        lock.lock()
        let value = canceled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

/// An exact, open nearest-unvisited walk in upright source-photo geometry.
/// The index accelerates candidate discovery; it does not approximate distances.
public enum NearestNeighborRoute {
    public static func indices(markers: [Marker], pixelWidth: Int, pixelHeight: Int,
                               cancellation: NearestNeighborCancellation = .init()) throws -> [Int] {
        try cancellation.checkCancellation()
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= ResourceLimits.maxImageDimension, pixelHeight <= ResourceLimits.maxImageDimension,
              pixelWidth * pixelHeight <= ResourceLimits.maxImagePixels,
              markers.count <= ResourceLimits.maxMarkers else {
            throw CountError.invalid("The count or upright photo dimensions are invalid for renumbering.")
        }
        var work = WorkCheck(cancellation: cancellation)
        var entries: [Entry] = []
        entries.reserveCapacity(markers.count)
        var identities = Set<UUID>()
        identities.reserveCapacity(markers.count)
        for (index, marker) in markers.enumerated() {
            try work.step()
            try marker.validate()
            guard identities.insert(marker.id).inserted else {
                throw CountError.invalid("Marker identities must be unique.")
            }
            entries.append(Entry(source: index, x: marker.x, y: marker.y,
                                 uuid: marker.id.uuidString.lowercased()))
        }
        entries = try canonicalSort(entries, work: &work)
        var tree = try Index(entries: entries, width: Double(pixelWidth), height: Double(pixelHeight), work: work)
        return try tree.walk()
    }

    private struct Entry {
        let source: Int
        let x: Double
        let y: Double
        let uuid: String

        func precedes(_ other: Entry) -> Bool {
            if y != other.y { return y < other.y }
            if x != other.x { return x < other.x }
            return uuid < other.uuid
        }
    }

    /// Bottom-up merge sort is interruptible even during canonicalization. Using
    /// the standard library's whole-array sort would defer cancellation too long.
    private static func canonicalSort(_ input: [Entry], work: inout WorkCheck) throws -> [Entry] {
        guard input.count > 1 else { return input }
        var source = input
        var target = input
        var width = 1
        while width < input.count {
            var start = 0
            while start < input.count {
                let middle = min(start + width, input.count)
                let end = min(middle + width, input.count)
                var left = start, right = middle
                for output in start..<end {
                    try work.step()
                    if left < middle && (right == end || source[left].precedes(source[right])) {
                        target[output] = source[left]
                        left += 1
                    } else {
                        target[output] = source[right]
                        right += 1
                    }
                }
                start = end
            }
            swap(&source, &target)
            width *= 2
        }
        return source
    }

    private struct Bucket {
        let x: Double
        let y: Double
        var cursor: Int
        let end: Int
        var leaf = -1
    }

    private struct Node {
        let parent: Int
        var left = -1
        var right = -1
        var bucket = -1
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double
        let minRank: Int
        var live: Int
    }

    private struct Index {
        let entries: [Entry]
        let width: Double
        let height: Double
        var work: WorkCheck
        var buckets: [Bucket] = []
        var order: [Int] = []
        var nodes: [Node] = []

        init(entries: [Entry], width: Double, height: Double, work: WorkCheck) throws {
            self.entries = entries
            self.width = width
            self.height = height
            self.work = work
            buckets.reserveCapacity(entries.count)
            for rank in entries.indices {
                try self.work.step()
                let point = entries[rank]
                if let last = buckets.last, last.x == point.x && last.y == point.y {
                    // Only the last bucket changes; UUID ranks are already canonical.
                    buckets[buckets.count - 1] = Bucket(x: last.x, y: last.y, cursor: last.cursor, end: rank + 1)
                } else {
                    buckets.append(Bucket(x: point.x, y: point.y, cursor: rank, end: rank + 1))
                }
            }
            order.reserveCapacity(buckets.count)
            for index in buckets.indices { try self.work.step(); order.append(index) }
            nodes.reserveCapacity(max(0, buckets.count * 2 - 1))
            if !buckets.isEmpty { _ = try build(0, order.count, parent: -1) }
        }

        mutating func walk() throws -> [Int] {
            guard !entries.isEmpty else { return [] }
            var result: [Int] = []
            result.reserveCapacity(entries.count)
            var chosen = 0 // canonical bucket containing the topmost/leftmost/UUID start
            while result.count < entries.count {
                try work.step()
                let rank = buckets[chosen].cursor
                result.append(entries[rank].source)
                let current = entries[rank]
                try consume(chosen)
                if result.count < entries.count {
                    var best = -1
                    var bestDistance = Double.infinity
                    var bestRank = Int.max
                    try search(0, x: current.x, y: current.y, best: &best,
                               distance: &bestDistance, rank: &bestRank)
                    guard best >= 0 else { throw CountError.invalid("Renumbering did not produce a complete order.") }
                    chosen = best
                }
            }
            try work.cancellation.checkCancellation()
            return result
        }

        mutating func build(_ start: Int, _ end: Int, parent: Int) throws -> Int {
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity
            var live = 0, minRank = Int.max
            for offset in start..<end {
                try work.step()
                let bucket = buckets[order[offset]]
                minX = min(minX, bucket.x); maxX = max(maxX, bucket.x)
                minY = min(minY, bucket.y); maxY = max(maxY, bucket.y)
                minRank = min(minRank, bucket.cursor)
                live += bucket.end - bucket.cursor
            }
            let index = nodes.count
            nodes.append(Node(parent: parent, minX: minX, maxX: maxX, minY: minY, maxY: maxY,
                              minRank: minRank, live: live))
            if end - start == 1 {
                let bucket = order[start]
                nodes[index].bucket = bucket
                buckets[bucket].leaf = index
            } else {
                let axisX = (maxX - minX) * width >= (maxY - minY) * height
                let middle = start + (end - start) / 2
                try select(middle, start: start, end: end, axisX: axisX)
                let left = try build(start, middle, parent: index)
                let right = try build(middle, end, parent: index)
                nodes[index].left = left
                nodes[index].right = right
            }
            return index
        }

        func precedes(_ a: Int, _ b: Int, axisX: Bool) -> Bool {
            let one = buckets[a], two = buckets[b]
            let av = axisX ? one.x : one.y, bv = axisX ? two.x : two.y
            return av == bv ? one.cursor < two.cursor : av < bv
        }

        /// In-place median selection avoids sorting/copying every subtree. Each
        /// resulting node splits its unique centers evenly, independent of layout.
        mutating func select(_ target: Int, start: Int, end: Int, axisX: Bool) throws {
            var low = start, high = end - 1
            while low < high {
                try work.step()
                let middle = low + (high - low) / 2
                if precedes(order[middle], order[low], axisX: axisX) { order.swapAt(middle, low) }
                if precedes(order[high], order[low], axisX: axisX) { order.swapAt(high, low) }
                if precedes(order[high], order[middle], axisX: axisX) { order.swapAt(high, middle) }
                let pivot = order[middle]
                var left = low, right = high
                while left <= right {
                    while precedes(order[left], pivot, axisX: axisX) { try work.step(); left += 1 }
                    while precedes(pivot, order[right], axisX: axisX) { try work.step(); right -= 1 }
                    try work.step()
                    if left <= right { order.swapAt(left, right); left += 1; right -= 1 }
                }
                if target <= right { high = right }
                else if target >= left { low = left }
                else { return }
            }
        }

        mutating func consume(_ bucket: Int) throws {
            buckets[bucket].cursor += 1
            var node = buckets[bucket].leaf
            while node >= 0 {
                try work.step()
                nodes[node].live -= 1
                node = nodes[node].parent
            }
        }

        /// Every rectangle bound uses the same difference-before-scale binary64
        /// operations as candidate distance. Clamping minimizes each absolute
        /// difference; IEEE round-to-nearest multiplication/addition are monotone
        /// for these nonnegative finite terms (including subnormal underflow).
        func bound(_ node: Node, x: Double, y: Double) -> Double {
            let closestX = max(node.minX, min(x, node.maxX))
            let closestY = max(node.minY, min(y, node.maxY))
            return squaredDistance(x: x, y: y, otherX: closestX, otherY: closestY)
        }

        func squaredDistance(x: Double, y: Double, otherX: Double, otherY: Double) -> Double {
            let dx = (otherX - x) * width
            let dy = (otherY - y) * height
            let xx = dx * dx
            let yy = dy * dy
            return xx + yy
        }

        mutating func search(_ index: Int, x: Double, y: Double, best: inout Int,
                             distance: inout Double, rank: inout Int) throws {
            try work.step()
            let node = nodes[index]
            guard node.live > 0 else { return }
            let lower = bound(node, x: x, y: y)
            guard lower <= distance else { return }
            if lower == distance && node.minRank >= rank { return }
            if node.bucket >= 0 {
                let bucket = buckets[node.bucket]
                let candidateDistance = squaredDistance(x: x, y: y, otherX: bucket.x, otherY: bucket.y)
                if candidateDistance < distance || (candidateDistance == distance && bucket.cursor < rank) {
                    best = node.bucket; distance = candidateDistance; rank = bucket.cursor
                }
                return
            }
            let left = nodes[node.left], right = nodes[node.right]
            let leftBound = left.live > 0 ? bound(left, x: x, y: y) : Double.infinity
            let rightBound = right.live > 0 ? bound(right, x: x, y: y) : Double.infinity
            let leftFirst = leftBound < rightBound || (leftBound == rightBound && left.minRank < right.minRank)
            try search(leftFirst ? node.left : node.right, x: x, y: y, best: &best, distance: &distance, rank: &rank)
            try search(leftFirst ? node.right : node.left, x: x, y: y, best: &best, distance: &distance, rank: &rank)
        }
    }
}

/// At most 128 bounded loop/query/ancestor steps between cancellation checks.
/// Shared internally with prepared-history validation; no actor hop is required.
struct WorkCheck {
    let cancellation: NearestNeighborCancellation
    private var remaining = 0

    init(cancellation: NearestNeighborCancellation) { self.cancellation = cancellation }

    mutating func step() throws {
        remaining -= 1
        if remaining <= 0 {
            try cancellation.checkCancellation()
            remaining = 128
        }
    }
}
