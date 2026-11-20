import Foundation

/// Reader for `.rbxlx` / `.rbxmx` XML files (port of format/RbxXmlReader.kt).
enum RbxXmlReader {
    final class XNode {
        let tag: String
        var attrs: [String: String]
        var children: [XNode] = []
        var text = ""
        init(_ tag: String, _ attrs: [String: String]) { self.tag = tag; self.attrs = attrs }
        func child(_ t: String) -> XNode? { children.first { $0.tag.caseInsensitiveCompare(t) == .orderedSame } }
        func float(_ t: String) -> Float { child(t).map { RbxXmlReader.parseFloat($0.text) } ?? 0 }
        func int(_ t: String) -> Int { child(t).flatMap { Int($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0 }
        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var stack: [XNode] = [XNode("#doc", [:])]
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let n = XNode(e, attributes)
            stack.last!.children.append(n)
            stack.append(n)
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
        func parser(_ p: XMLParser, foundCharacters s: String) { stack.last!.text += s }
        func parser(_ p: XMLParser, foundCDATA d: Data) { stack.last!.text += String(decoding: d, as: UTF8.self) }
    }

    static func parseFloat(_ s: String) -> Float {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        switch t.uppercased() {
        case "INF", "+INF": return .infinity
        case "-INF": return -.infinity
        case "NAN": return .nan
        default: return Float(t) ?? 0
        }
    }

    static func read(_ data: Data) throws -> RbxDocument {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        if !parser.parse() {
            throw RbxFormatError("Invalid XML: \(parser.parserError?.localizedDescription ?? "parse error")")
        }
        guard let root = builder.stack.first?.children.first(where: { $0.tag == "roblox" }) else {
            throw RbxFormatError("Not a Roblox XML file")
        }

        var warnings: [String] = []
        var meta = OrderedDict<String>()
        var byRef: [String: Instance] = [:]
        var pending: [(Instance, String, String)] = []
        var pendingContent: [(Instance, String, String)] = []
        var sharedStrings: [String: Data] = [:]
        var pendingShared: [(Instance, String, String)] = []

        for n in root.children where n.tag == "SharedStrings" {
            for s in n.children where s.tag == "SharedString" {
                if let k = s.attrs["md5"] { sharedStrings[k] = Data(base64Encoded: s.trimmed, options: .ignoreUnknownCharacters) ?? Data() }
            }
        }
        for n in root.children where n.tag == "Meta" { if let k = n.attrs["name"] { meta[k] = n.text } }

        var nextRef = 0
        func readItem(_ node: XNode) -> Instance {
            let inst = Instance(node.attrs["class"] ?? "Folder")
            if let r = node.attrs["referent"] { byRef[r] = inst }
            inst.loadedRef = nextRef; nextRef += 1
            for c in node.children {
                if c.tag == "Properties" {
                    for p in c.children {
                        guard let name = p.attrs["name"] else { continue }
                        if p.tag == "Ref" {
                            pending.append((inst, name, p.trimmed))
                            inst.propTypes[name] = PropType.REF
                            continue
                        }
                        if p.tag == "SharedString" {
                            pendingShared.append((inst, name, p.trimmed))
                            continue
                        }
                        if let decoded = value(p, inst, name, &pendingContent) {
                            inst.props[name] = decoded.0
                            inst.propTypes[name] = decoded.1
                        } else {
                            warnings.append("Skipped \(inst.className).\(name) (\(p.tag))")
                        }
                    }
                } else if c.tag == "Item" {
                    readItem(c).attachRaw(inst)
                }
            }
            return inst
        }

        let roots = root.children.filter { $0.tag == "Item" }.map(readItem)
        for (inst, name, r) in pending { inst.props[name] = .ref(r == "null" || r.isEmpty ? nil : byRef[r]) }
        for (inst, name, r) in pendingContent {
            inst.props[name] = .content(ContentValue(sourceType: 2, uri: "", obj: byRef[r]))
        }
        for (inst, name, k) in pendingShared {
            inst.props[name] = .sharedString(SharedStr(sharedStrings[k] ?? Data()))
            inst.propTypes[name] = PropType.SHAREDSTRING
        }
        return RbxDocument(roots: roots, meta: meta, warnings: warnings)
    }

    private static func vec3(_ n: XNode) -> Vector3 { Vector3(n.float("X"), n.float("Y"), n.float("Z")) }
    private static func cframe(_ n: XNode) -> CFrame {
        CFrame(n.float("X"), n.float("Y"), n.float("Z"),
               n.float("R00"), n.float("R01"), n.float("R02"),
               n.float("R10"), n.float("R11"), n.float("R12"),
               n.float("R20"), n.float("R21"), n.float("R22"))
    }
    private static func packedColor(_ s: String) -> Color3 {
        let v = UInt32(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? UInt32(bitPattern: Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        return .fromHex(Int(v & 0xFFFFFF))
    }
    private static func floats(_ s: String) -> [Float] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map { parseFloat(String($0)) }
    }
    private static func url(_ n: XNode) -> String { n.child("url")?.trimmed ?? n.child("uri")?.trimmed ?? n.trimmed }

    /// Decode one property element. Returns the value and its binary type id.
    private static func value(_ p: XNode, _ inst: Instance, _ name: String,
                              _ pendingContent: inout [(Instance, String, String)]) -> (PropValue, Int)? {
        switch p.tag {
        case "string", "ProtectedString": return (.string(p.text), PropType.STRING)
        case "BinaryString":
            return (.binaryString(BinaryString(Data(base64Encoded: p.trimmed, options: .ignoreUnknownCharacters) ?? Data())), PropType.STRING)
        case "bool": return (.bool(p.trimmed.lowercased() == "true"), PropType.BOOL)
        case "int": return (.int(Int32(p.trimmed) ?? Int32(truncatingIfNeeded: Int64(p.trimmed) ?? 0)), PropType.INT)
        case "int64": return (.int64(Int64(p.trimmed) ?? 0), PropType.INT64)
        case "float": return (.float(parseFloat(p.text)), PropType.FLOAT)
        case "double": return (.double(Double(parseFloat(p.text))), PropType.DOUBLE)
        case "token": return (.enumValue(EnumValue(UInt32(p.trimmed) ?? 0)), PropType.ENUM)
        case "BrickColor": return (.brickColor(BrickColorV(Int32(p.trimmed) ?? 194)), PropType.BRICKCOLOR)
        case "Vector2": return (.vector2(Vector2(p.float("X"), p.float("Y"))), PropType.VECTOR2)
        case "Vector3": return (.vector3(vec3(p)), PropType.VECTOR3)
        case "Vector3int16":
            return (.vector3int16(Vector3int16(Int16(p.int("X")), Int16(p.int("Y")), Int16(p.int("Z")))), PropType.VECTOR3INT16)
        case "CoordinateFrame", "CFrame": return (.cframe(cframe(p)), PropType.CFRAME)
        case "OptionalCoordinateFrame":
            return (.optionalCFrame(OptionalCFrame(p.child("CFrame").map(cframe))), PropType.OPTCFRAME)
        case "Color3":
            if p.child("R") != nil { return (.color3(Color3(p.float("R"), p.float("G"), p.float("B"))), PropType.COLOR3) }
            return (.color3(packedColor(p.text)), PropType.COLOR3)
        case "Color3uint8": return (.color3(packedColor(p.text)), PropType.COLOR3U8)
        case "UDim": return (.udim(UDim(p.float("S"), Int32(p.int("O")))), PropType.UDIM)
        case "UDim2":
            return (.udim2(UDim2(p.float("XS"), Int32(p.int("XO")), p.float("YS"), Int32(p.int("YO")))), PropType.UDIM2)
        case "Ray":
            let o = p.child("origin").map(vec3) ?? .zero, d = p.child("direction").map(vec3) ?? .zero
            return (.ray(Ray(o, d)), PropType.RAY)
        case "Faces": return (.faces(Faces(UInt8(truncatingIfNeeded: p.int("faces")))), PropType.FACES)
        case "Axes": return (.axes(Axes(UInt8(truncatingIfNeeded: p.int("axes")))), PropType.AXES)
        case "NumberRange":
            let f = floats(p.text)
            return (.numberRange(NumberRange(f.first ?? 0, f.count > 1 ? f[1] : (f.first ?? 0))), PropType.NUMBERRANGE)
        case "NumberSequence":
            let f = floats(p.text)
            let keys = stride(from: 0, to: f.count - 2, by: 3).map { NumberKey(f[$0], f[$0 + 1], f[$0 + 2]) }
            return (.numberSequence(NumberSequence(keys)), PropType.NUMBERSEQ)
        case "ColorSequence":
            let f = floats(p.text)
            let keys = stride(from: 0, to: f.count - 4, by: 5).map { ColorKey(f[$0], Color3(f[$0 + 1], f[$0 + 2], f[$0 + 3]), f[$0 + 4]) }
            return (.colorSequence(ColorSequence(keys)), PropType.COLORSEQ)
        case "Rect2D":
            let mn = p.child("min"), mx = p.child("max")
            return (.rect(Rect(mn?.float("X") ?? 0, mn?.float("Y") ?? 0, mx?.float("X") ?? 0, mx?.float("Y") ?? 0)), PropType.RECT)
        case "PhysicalProperties":
            let custom = p.child("CustomPhysics")?.trimmed.lowercased() == "true"
            guard custom else { return (.physicalProps(PhysicalProps(flags: 0)), PropType.PHYSPROPS) }
            var pp = PhysicalProps(flags: 1, density: p.float("Density"), friction: p.float("Friction"),
                                   elasticity: p.float("Elasticity"), frictionWeight: p.float("FrictionWeight"),
                                   elasticityWeight: p.float("ElasticityWeight"))
            if p.child("AcousticAbsorption") != nil { pp.flags |= 2; pp.acoustic = p.float("AcousticAbsorption") }
            return (.physicalProps(pp), PropType.PHYSPROPS)
        case "Font":
            let fam = p.child("Family").map(url) ?? FontValue.default.family
            let style = p.child("Style")?.trimmed == "Italic" ? 1 : 0
            let cached = p.child("CachedFaceId").map(url) ?? ""
            return (.font(FontValue(fam, p.child("Weight").flatMap { Int($0.trimmed) } ?? 400, style, cached)), PropType.FONT)
        case "UniqueId":
            var bytes = Data()
            let hex = Array(p.trimmed)
            var k = 0
            while k + 1 < hex.count { if let b = UInt8(String(hex[k...k + 1]), radix: 16) { bytes.append(b) }; k += 2 }
            return (.uniqueId(UniqueId(bytes)), PropType.UNIQUEID)
        case "SecurityCapabilities": return (.securityCaps(SecurityCaps(UInt64(p.trimmed) ?? 0)), PropType.SECCAPS)
        case "Content", "ContentId":
            if let o = p.child("Object") {
                pendingContent.append((inst, name, o.trimmed))
                return (.content(ContentValue()), PropType.CONTENT)
            }
            if let u = p.child("uri") { return (.content(ContentValue(sourceType: 1, uri: u.trimmed)), PropType.CONTENT) }
            if p.child("None") != nil { return (.content(ContentValue()), PropType.CONTENT) }
            if p.child("null") != nil { return (.string(""), PropType.STRING) }
            return (.string(url(p)), PropType.STRING)
        default:
            return nil
        }
    }
}

/// File-level entry points (port of format/RbxFile.kt).
public enum RbxFile {
    public static func isBinary(_ b: Data) -> Bool { b.count > 14 && b.prefix(8) == Data("<roblox!".utf8) }

    public static func isXml(_ b: Data) -> Bool {
        let head = String(decoding: b.prefix(200), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF} \n\r\t"))
        return head.hasPrefix("<roblox") || head.hasPrefix("<?xml")
    }

    public static func read(_ data: Data) throws -> RbxDocument {
        let b = try Gzip.unwrap(data)
        var doc: RbxDocument
        if isBinary(b) {
            doc = try RbxBinaryReader([UInt8](b)).read()
        } else if isXml(b) {
            doc = try RbxXmlReader.read(b)
        } else {
            throw RbxFormatError("Not a Roblox place or model file")
        }
        normalize(&doc)
        return doc
    }

    private static func normalize(_ doc: inout RbxDocument) {
        for r in doc.roots where r.className == "MaterialService" {
            if let plain = r.props["Use2022Materials"] {
                r.props["Use2022Materials"] = nil
                r.propTypes["Use2022Materials"] = nil
                if !r.props.contains("Use2022MaterialsXml"), case .bool = plain {
                    r.props["Use2022MaterialsXml"] = plain
                    r.propTypes["Use2022MaterialsXml"] = PropType.BOOL
                }
            }
        }
    }

    public static func isPlace(_ doc: RbxDocument) -> Bool { doc.roots.contains { $0.className == "Workspace" } }
}
