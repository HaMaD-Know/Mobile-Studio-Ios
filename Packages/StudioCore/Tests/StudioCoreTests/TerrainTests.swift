import XCTest
@testable import StudioCore

final class TerrainTests: XCTestCase {
    func testSmoothGridRoundTrip() {
        let g = TerrainGrid()
        TerrainOps.fillBall(g, center: Vector3(10, 4, -6), radius: 12, material: TerrainMaterials.fromName("Grass"))
        TerrainOps.fillBlock(g, cframe: .at(Vector3(0, -8, 0)), size: Vector3(64, 16, 64), material: TerrainMaterials.fromName("Rock"))
        g.set(3, 9, 3, 1, 1)
        g.tidy()
        let data = g.encode()
        XCTAssertEqual(Array(data.prefix(2)), [1, 5])
        let back = TerrainGrid.decode(data)
        XCTAssertEqual(back.countCells(), g.countCells())
        for (x, y, z) in [(0, 0, 0), (2, 1, -1), (3, 9, 3), (-7, -3, 5), (40, 2, 40)] {
            XCTAssertEqual(back.material(x, y, z), g.material(x, y, z), "material at \(x),\(y),\(z)")
            XCTAssertEqual(back.occupancy(x, y, z), g.occupancy(x, y, z), accuracy: 0.001)
        }
        // Re-encoding an untouched decoded grid gives the same bytes.
        XCTAssertEqual(back.encode(), data)
    }

    func testStoreFlushAndReload() {
        let t = InstanceFactory.create("Terrain")
        let g = TerrainStore.of(t)
        TerrainOps.fillBall(g, center: .zero, radius: 8, material: 2)
        XCTAssertNotNil(TerrainStore.flush(t))
        XCTAssertTrue(TerrainStore.of(t) === g)
        let copy = InstanceFactory.create("Terrain")
        copy.set("SmoothGrid", t.props["SmoothGrid"]!, notify: false)
        XCTAssertEqual(TerrainStore.of(copy).countCells(), g.countCells())
    }

    func testMesherAndRaycast() {
        let g = TerrainGrid()
        TerrainOps.fillBlock(g, cframe: .at(Vector3(0, -8, 0)), size: Vector3(128, 16, 128), material: 2)
        let m = TerrainMesher.mesh(g, 0, -1, 0, colors: TerrainMaterials.defaultColors)
        XCTAssertGreaterThan(m.solidVertexCount, 0)
        XCTAssertEqual(m.solidVertexCount % 3, 0)
        let hit = TerrainMesher.raycast(g, origin: Vector3(10, 50, 10), dir: Vector3(0, -1, 0), maxDist: 200)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.point.y ?? 99, 0, accuracy: 1.5)
        XCTAssertGreaterThan(hit?.normal.y ?? 0, 0.8)
    }

    func testGeneratorMakesLandAndSea() {
        let g = TerrainGrid()
        let n = TerrainGenerator.generate(g, .init(size: 128, seed: 7, biomes: [.water, .plains, .hills], caves: false))
        XCTAssertGreaterThan(n, 0)
        XCTAssertFalse(g.isEmpty)
    }
}
