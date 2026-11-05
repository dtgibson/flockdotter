import XCTest
@testable import DotCounterCore

final class NearestNeighborTests: XCTestCase {
    private func marker(_ id: Int, _ x: Double, _ y: Double) -> Marker {
        Marker(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", id))!, x: x, y: y)
    }

    /// Deliberately exhaustive small-fixture oracle, separate from spatial indexing.
    private func oracle(_ markers: [Marker], width: Int, height: Int) -> [UUID] {
        func canonical(_ a: Marker, _ b: Marker) -> Bool {
            if a.y != b.y { return a.y < b.y }
            if a.x != b.x { return a.x < b.x }
            return a.id.uuidString.lowercased() < b.id.uuidString.lowercased()
        }
        func distance(_ a: Marker, _ b: Marker) -> Double {
            let dx = (b.x - a.x) * Double(width)
            let dy = (b.y - a.y) * Double(height)
            let xx = dx * dx
            let yy = dy * dy
            return xx + yy
        }
        var remaining = markers.sorted(by: canonical)
        guard !remaining.isEmpty else { return [] }
        var current = remaining.removeFirst()
        var result = [current.id]
        while !remaining.isEmpty {
            let next = remaining.indices.min {
                let a = distance(current, remaining[$0]), b = distance(current, remaining[$1])
                return a == b ? canonical(remaining[$0], remaining[$1]) : a < b
            }!
            current = remaining.remove(at: next)
            result.append(current.id)
        }
        return result
    }

    private func route(_ markers: [Marker], width: Int = 4000, height: Int = 3000) throws -> [UUID] {
        try NearestNeighborRoute.indices(markers: markers, pixelWidth: width, pixelHeight: height).map { markers[$0].id }
    }

    func testExactTraversalMatchesOracleAcrossTiesPermutationsAndAspectRatios() throws {
        var random = Generator()
        var randomPoints: [Marker] = []
        for id in 1...160 {
            randomPoints.append(marker(id, Double(random.next() % 1000) / 999, Double(random.next() % 1000) / 999))
        }
        // Exact distance ties, coincident starting/remaining centers, crossings,
        // separated clusters, and adjacent Double values exercise pruning/ties.
        let fixtures = [
            [marker(3, 0.5, 0), marker(8, 0.25, 0.25), marker(2, 0.75, 0.25), marker(1, 0.25, 0.25)],
            [marker(3, 0.1, 0.1), marker(2, 0.3, 0.1), marker(1, 0.1, 0.4)],
            [marker(5, 0, 0), marker(4, 0, 0), marker(3, 0, 0), marker(2, 1, 1), marker(1, 1, 1)],
            [marker(1, 0, 0), marker(2, 0.0001, 0.0001), marker(3, 0.99, 0.99), marker(4, 1, 1)],
            [marker(1, 0.5, 0), marker(2, 0.5.nextDown, 0.5), marker(3, 0.5.nextUp, 0.5), marker(4, 0.5, 1)],
            randomPoints
        ]
        for fixture in fixtures {
            for (width, height) in [(4000, 1000), (1000, 4000), (32768, 1), (1, 32768), (4000, 3000)] {
                let expected = oracle(fixture, width: width, height: height)
                for input in [fixture, Array(fixture.reversed()), fixture.shuffled(using: &random)] {
                    XCTAssertEqual(try route(input, width: width, height: height), expected)
                }
            }
        }
        let aspect = fixtures[1]
        XCTAssertEqual(try route(aspect, width: 4000, height: 1000)[1], aspect[2].id)
        XCTAssertEqual(try route(aspect, width: 1000, height: 4000)[1], aspect[1].id)
        XCTAssertEqual(try route([]), [])
        XCTAssertEqual(try route([marker(1, 1, 0)]), [marker(1, 1, 0).id])
    }

    func testSubnormalComputedZeroTiesCompeteWithCoincidentBuckets() throws {
        // Distinct centers can have zero computed squared distance. A bucket
        // must not be blindly drained; the topmost competing center wins.
        let tiny = 1e-200
        let fixtures = [
            [marker(3, 0, 0), marker(2, 0, 0), marker(1, tiny, 0), marker(4, tiny, tiny)],
            [marker(4, tiny, 0), marker(3, tiny, tiny), marker(2, tiny, tiny), marker(1, 0, tiny)],
            (1...40).map { marker($0, Double($0 % 7) * tiny, Double($0 % 11) * tiny) }
        ]
        for fixture in fixtures {
            XCTAssertEqual(try route(fixture, width: 1, height: 1), oracle(fixture, width: 1, height: 1))
            XCTAssertEqual(try route(Array(fixture.reversed()), width: 32768, height: 1),
                           oracle(fixture, width: 32768, height: 1))
        }
    }

    func testValidatedPermutationIsOneReversibleEditAndNoOpPreservesRedo() throws {
        let initial = [marker(3, 0.8, 0.8), marker(1, 0, 0), marker(2, 0.1, 0.1)]
        var history = MarkerHistory(markers: initial)
        XCTAssertFalse(history.renumber(.nearestNeighbor))
        XCTAssertTrue(history.add(x: 0.5, y: 0.5))
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.redoCount, 1)
        XCTAssertFalse(try history.applyPermutation([0, 1, 2]))
        XCTAssertEqual(history.redoCount, 1)
        for invalid in [[0, 1], [0, 1, 1], [0, 1, 3], [-1, 1, 2]] {
            XCTAssertThrowsError(try history.applyPermutation(invalid))
            XCTAssertEqual(history.markers, initial)
            XCTAssertEqual(history.undoCount, 0)
            XCTAssertEqual(history.redoCount, 1)
        }
        let indices = try NearestNeighborRoute.indices(markers: initial, pixelWidth: 4000, pixelHeight: 3000)
        XCTAssertTrue(try history.applyPermutation(indices))
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertFalse(history.canRedo)
        let after = history.markers
        XCTAssertEqual(Set(after.map(\.id)), Set(initial.map(\.id)))
        XCTAssertEqual(after, indices.map { initial[$0] })
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.markers, initial)
        XCTAssertTrue(history.redo())
        XCTAssertEqual(history.markers, after)
        XCTAssertFalse(try history.applyPermutation(Array(after.indices)))
        XCTAssertEqual(history.undoCount, 1)
        let image = ImageIdentity(sha256: String(repeating: "a", count: 64), pixelWidth: 4000, pixelHeight: 3000, originalFilename: "flock.png")
        let document = CountDocument(image: image, markers: after)
        XCTAssertEqual(try CountDocument.decode(document.encoded()), document)
    }

    func testInvalidInputAndCanceledWorkCannotProduceOrApplyAnOrder() throws {
        let point = marker(1, 0.5, 0.5)
        XCTAssertThrowsError(try route([point, point]))
        XCTAssertThrowsError(try route([marker(2, .nan, 0)]))
        XCTAssertThrowsError(try route([point], width: 0, height: 1))
        XCTAssertThrowsError(try route([point], width: 32768, height: 32768))
        let cancellation = NearestNeighborCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try NearestNeighborRoute.indices(markers: [point], pixelWidth: 100, pixelHeight: 100, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        var history = MarkerHistory(markers: [point, marker(2, 0, 0)])
        XCTAssertThrowsError(try history.applyPermutation([1, 0], cancellation: cancellation))
        XCTAssertEqual(history.markers.first, point)
        XCTAssertFalse(history.canUndo)
    }

    func testCanceledCapacityWorkerDrainsDuringCanonicalizationOrSearch() async throws {
        let input = (0..<100_000).map { index in
            marker(index + 1, Double(index % 400) / 399, Double(index / 400) / 249)
        }
        let cancellation = NearestNeighborCancellation()
        let worker = Task.detached {
            try NearestNeighborRoute.indices(markers: input, pixelWidth: 6000, pixelHeight: 4000,
                                            cancellation: cancellation)
        }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        cancellation.cancel()
        do {
            _ = try await worker.value
            XCTFail("Canceled capacity work unexpectedly returned a complete route")
        } catch is CancellationError {
            let drain = start.duration(to: .now)
            print("NEAREST_NEIGHBOR_CANCEL configuration=Debug markers=100000 cancelToDrain=\(drain) excludesNativeStatus=true")
            XCTAssertLessThan(drain, .milliseconds(250))
        }
    }

    func testCapacityGridAndCoincidentCompleteWithoutTruncation() throws {
        for count in [1000, 10_000, 100_000] {
            for coincident in [false, true] {
                let markers = (0..<count).map { index in
                    marker(index + 1, coincident ? 0.5 : Double(index % 400) / 399,
                           coincident ? 0.5 : Double(index / 400) / 249)
                }.reversed()
                let input = Array(markers)
                let start = ContinuousClock.now
                let indices = try NearestNeighborRoute.indices(markers: input, pixelWidth: 6000, pixelHeight: 4000)
                var history = MarkerHistory(markers: input)
                _ = try history.applyPermutation(indices)
                let duration = start.duration(to: .now)
                XCTAssertEqual(indices.count, count)
                XCTAssertEqual(Set(indices).count, count)
                XCTAssertEqual(history.markers.count, count)
                XCTAssertEqual(history.markers.first?.id, marker(1, 0, 0).id)
                print("NEAREST_NEIGHBOR_CORE configuration=Debug markers=\(count) layout=\(coincident ? "coincident" : "grid400") routeAndHistory=\(duration) excludesNativePublicationAndDrawing=true")
            }
        }
    }

    private struct Generator: RandomNumberGenerator {
        var state: UInt64 = 0x123456789abcdef
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}
