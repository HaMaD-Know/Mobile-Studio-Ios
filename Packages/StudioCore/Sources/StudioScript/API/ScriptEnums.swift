import Foundation
import StudioCore

/// Enum tables available to scripts: the ones generated from the Android app plus the ones it
/// builds in code (KeyCode) and a few more scripts commonly use.
enum ScriptEnums {
    static let all: [String: [(String, Int)]] = {
        var m = EnumTable.types
        var key: [(String, Int)] = [("Unknown", 0), ("Backspace", 8), ("Tab", 9), ("Clear", 12), ("Return", 13), ("Pause", 19), ("Escape", 27)]
        func seq(_ names: [String], _ start: Int) { for (i, n) in names.enumerated() { key.append((n, start + i)) } }
        seq(["Space", "QuotedDouble", "Hash", "Dollar", "Percent", "Ampersand", "Quote", "LeftParenthesis", "RightParenthesis",
             "Asterisk", "Plus", "Comma", "Minus", "Period", "Slash"], 32)
        seq(["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"], 48)
        seq(["Colon", "Semicolon", "LessThan", "Equals", "GreaterThan", "Question", "At"], 58)
        seq(["LeftBracket", "BackSlash", "RightBracket", "Caret", "Underscore", "Backquote"], 91)
        seq((0..<26).map { String(UnicodeScalar(65 + $0)!) }, 97)
        seq(["LeftCurly", "Pipe", "RightCurly", "Tilde", "Delete"], 123)
        seq(["KeypadZero", "KeypadOne", "KeypadTwo", "KeypadThree", "KeypadFour", "KeypadFive", "KeypadSix", "KeypadSeven",
             "KeypadEight", "KeypadNine", "KeypadPeriod", "KeypadDivide", "KeypadMultiply", "KeypadMinus", "KeypadPlus",
             "KeypadEnter", "KeypadEquals", "Up", "Down", "Right", "Left", "Insert", "Home", "End", "PageUp", "PageDown"], 256)
        seq((1...15).map { "F\($0)" }, 282)
        seq(["NumLock", "CapsLock", "ScrollLock", "RightShift", "LeftShift", "RightControl", "LeftControl", "RightAlt", "LeftAlt",
             "RightMeta", "LeftMeta", "LeftSuper", "RightSuper", "Mode", "Compose", "Help", "Print", "SysReq", "Break", "Menu",
             "Power", "Euro", "Undo"], 300)
        seq(["ButtonX", "ButtonY", "ButtonA", "ButtonB", "ButtonR1", "ButtonL1", "ButtonR2", "ButtonL2", "ButtonR3", "ButtonL3",
             "ButtonStart", "ButtonSelect", "DPadLeft", "DPadRight", "DPadUp", "DPadDown", "Thumbstick1", "Thumbstick2"], 1000)
        m["KeyCode"] = key
        func add(_ name: String, _ items: [(String, Int)]) { if m[name] == nil { m[name] = items } }
        func addSeq(_ name: String, _ items: [String]) { add(name, items.enumerated().map { ($1, $0) }) }
        addSeq("PlaybackState", ["Begin", "Delayed", "Playing", "Paused", "Completed", "Cancelled"])
        addSeq("MouseBehavior", ["Default", "LockCenter", "LockCurrentPosition"])
        addSeq("ContextActionResult", ["Sink", "Pass"])
        addSeq("Axis", ["X", "Y", "Z"])
        addSeq("FontStyle", ["Normal", "Italic"])
        add("FontWeight", [("Thin", 100), ("ExtraLight", 200), ("Light", 300), ("Regular", 400), ("Medium", 500),
                           ("SemiBold", 600), ("Bold", 700), ("ExtraBold", 800), ("Heavy", 900)])
        addSeq("MessageType", ["MessageOutput", "MessageInfo", "MessageWarning", "MessageError"])
        addSeq("HttpContentType", ["ApplicationJson", "ApplicationXml", "ApplicationUrlEncoded", "TextPlain", "TextXml"])
        addSeq("ThumbnailType", ["HeadShot", "AvatarBust", "AvatarThumbnail"])
        addSeq("ThumbnailSize", ["Size48x48", "Size180x180", "Size420x420", "Size60x60", "Size100x100", "Size150x150", "Size352x352"])
        addSeq("ProductPurchaseDecision", ["NotProcessedYet", "PurchaseGranted"])
        addSeq("ExplosionType", ["NoCraters", "Craters"])
        addSeq("SoundType", ["NoSound", "Boing", "Bomb", "Break", "Click", "Clock", "Slingshot", "Page", "Ping", "Snap", "Splat",
                             "Step", "StepOn", "Swoosh", "Victory"])
        addSeq("RollOffMode", ["Inverse", "Linear", "InverseTapered", "LinearSquare"])
        addSeq("ActuatorType", ["None", "Motor", "Servo"])
        addSeq("ConstraintPriority", ["Low", "Medium", "High"])
        addSeq("ProximityPromptStyle", ["Default", "Custom"])
        addSeq("ProximityPromptExclusivity", ["OnePerButton", "OneGlobally", "AlwaysShow"])
        addSeq("TextTruncate", ["None", "AtEnd", "SplitWord"])
        addSeq("ButtonStyle", ["Custom", "RobloxButtonDefault", "RobloxButton", "RobloxRoundButton", "RobloxRoundDropdownButton",
                               "RobloxRoundDefaultButton"])
        addSeq("DevTouchMovementMode", ["UserChoice", "Thumbstick", "DPad", "Thumbpad", "ClickToMove", "Scriptable", "DynamicThumbstick"])
        addSeq("HumanoidDisplayDistanceType", ["Viewer", "Subject", "None"])
        addSeq("HumanoidHealthDisplayType", ["DisplayWhenDamaged", "AlwaysOn", "AlwaysOff"])
        addSeq("TeleportResult", ["Success", "Failure", "GameNotFound", "GameEnded", "GameFull", "Unauthorized", "Flooded", "IsTeleporting"])
        addSeq("AssetType", ["Image", "TShirt", "Audio", "Mesh", "Lua", "HTML", "Text", "Hat", "Place", "Model", "Shirt", "Pants",
                             "Decal", "Avatar", "Head", "Face", "Gear"])
        addSeq("ParticleEmitterShape", ["Box", "Sphere", "Cylinder", "Disc"])
        addSeq("ParticleOrientation", ["FacingCamera", "FacingCameraWorldUp", "VelocityParallel", "VelocityPerpendicular"])
        addSeq("SelectionBehavior", ["Escape", "Stop"])
        addSeq("SizeConstraint", ["RelativeXY", "RelativeXX", "RelativeYY"])
        addSeq("StartCorner", ["TopLeft", "TopRight", "BottomLeft", "BottomRight"])
        addSeq("EasingStyle", ["Linear", "Sine", "Back", "Quad", "Quart", "Quint", "Bounce", "Elastic", "Exponential", "Circular", "Cubic"])
        addSeq("EasingDirection", ["In", "Out", "InOut"])
        addSeq("DataStoreRequestType", ["GetAsync", "SetIncrementAsync", "UpdateAsync", "GetSortedAsync", "SetIncrementSortedAsync", "OnUpdate"])
        addSeq("InfoType", ["Asset", "Product", "GamePass", "Subscription", "Bundle"])
        addSeq("Platform", ["Windows", "OSX", "IOS", "Android", "XBoxOne", "PS4", "PS3", "XBox360", "WiiU", "NX", "Ouya", "AndroidTV",
                            "Chromecast", "Linux", "SteamOS", "WebOS", "DOS", "BeOS", "UWP", "None"])
        return m
    }()

    static var names: [String] { all.keys.sorted() }
    static func items(_ t: String) -> [(String, Int)]? { all[t] }
    static func item(_ t: String, _ name: String) -> EnumItem? {
        guard let v = all[t]?.first(where: { $0.0 == name })?.1 else { return nil }
        return EnumItem(enumType: t, name: name, value: v)
    }
    static func item(_ t: String, value: Int) -> EnumItem? {
        guard let n = all[t]?.first(where: { $0.1 == value })?.0 else { return nil }
        return EnumItem(enumType: t, name: n, value: value)
    }
}
