import XCTest
@testable import StudioCore

final class StudioCoreTests: XCTestCase {
    func testNewPlaceRoundTripsThroughBinary() throws {
        let dm = PlaceFactory.newPlace(.baseplate)
        let part = InstanceFactory.create("Part")
        part.name = "Red"
        part.set("CFrame", .cframe(CFrame.at(Vector3(1, 2, 3)) * .ry(0.5)))
        part.set("Color3uint8", .color3(.fromRGB(255, 0, 0)))
        part.attachRaw(dm.workspace)
        let weld = InstanceFactory.create("Weld")
        weld.set("Part0", .ref(part))
        weld.attachRaw(part)

        let bytes = RbxBinaryWriter.write(dm.children, meta: dm.meta)
        XCTAssertTrue(RbxFile.isBinary(bytes))
        let doc = try RbxFile.read(bytes)
        XCTAssertTrue(doc.warnings.isEmpty, "\(doc.warnings)")
        let back = PlaceFactory.fromDocument(doc)

        let red = try XCTUnwrap(back.workspace.findFirstChild("Red"))
        XCTAssertEqual(PartData.color(red).rgb8.0, 255)
        let cf = PartData.cframe(red)
        XCTAssertEqual(cf.position, Vector3(1, 2, 3))
        XCTAssertEqual(cf.r00, cos(0.5), accuracy: 1e-6)
        let w = try XCTUnwrap(red.findFirstChildOfClass("Weld"))
        XCTAssertTrue(w.get("Part0")?.asInstance === red)
        XCTAssertNotNil(back.workspace.findFirstChild("Baseplate"))
        XCTAssertEqual(back.meta["ExplicitAutoJoints"], "true")
    }

    func testInterleavedArraysRoundTrip() throws {
        var w = ByteWriter()
        w.i32Array([0, -1, 5, Int32.min, Int32.max])
        w.f32Array([0, -0.5, 3.25, .infinity])
        w.refArray([3, 7, 2, -1])
        w.i64Array([0, -2, Int64.max])
        var r = ByteReader(w.out)
        XCTAssertEqual(try r.i32Array(5), [0, -1, 5, Int32.min, Int32.max])
        XCTAssertEqual(try r.f32Array(4), [0, -0.5, 3.25, .infinity])
        XCTAssertEqual(try r.refArray(4), [3, 7, 2, -1])
        XCTAssertEqual(try r.i64Array(3), [0, -2, Int64.max])
    }

    func testLz4() throws {
        // "abcabcabcabc": 3 literals then a 9-byte match at offset 3.
        let block: [UInt8] = [0x35, 0x61, 0x62, 0x63, 0x03, 0x00]
        let out = try ChunkCodec.lz4(block, 0, block.count, 12)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abcabcabcabc")
    }

    func testRotationIds() {
        // id 2 = right +X, up +Y -> identity
        XCTAssertEqual(RbxBinaryReader.rotationFromId(2), .identity)
    }

    func testUndoRedo() {
        let s = EditSession(model: PlaceFactory.newPlace(.empty))
        let p = s.insertPart(shape: 1, at: .zero)
        XCTAssertTrue(p.parent === s.model.workspace)
        s.setProp(p, "Transparency", .float(0.5))
        s.undo.undo()
        XCTAssertEqual(PartData.transparency(p), 0)
        s.undo.undo()
        XCTAssertNil(p.parent)
        s.undo.redo()
        XCTAssertTrue(p.parent === s.model.workspace)
        s.select([p])
        s.groupSelection()
        XCTAssertEqual(s.selection.first?.className, "Model")
    }

    func testXml() throws {
        let xml = """
        <roblox version="4">
          <Item class="Part" referent="RBX1">
            <Properties>
              <string name="Name">P</string>
              <CoordinateFrame name="CFrame"><X>1</X><Y>2</Y><Z>3</Z><R00>1</R00><R01>0</R01><R02>0</R02><R10>0</R10><R11>1</R11><R12>0</R12><R20>0</R20><R21>0</R21><R22>1</R22></CoordinateFrame>
              <Color3uint8 name="Color3uint8">4294901760</Color3uint8>
              <Vector3 name="size"><X>4</X><Y>1</Y><Z>2</Z></Vector3>
              <token name="Material">272</token>
            </Properties>
          </Item>
        </roblox>
        """
        let doc = try RbxFile.read(Data(xml.utf8))
        let p = try XCTUnwrap(doc.roots.first)
        XCTAssertEqual(p.name, "P")
        XCTAssertEqual(PartData.cframe(p).position, Vector3(1, 2, 3))
        XCTAssertEqual(PartData.color(p).rgb8.0, 255)
        XCTAssertEqual(Enums.display(prop: "Material", value: 272), "SmoothPlastic")
    }
}
