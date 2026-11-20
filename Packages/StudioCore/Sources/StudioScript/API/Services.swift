import Foundation
import Luau
import StudioCore

/// Service names `game.X` / `game:GetService("X")` resolve (ClassDb services + script-only ones).
enum ServiceRegistry {
    static let extra: Set<String> = ["RunService", "TweenService", "Debris", "HttpService", "UserInputService", "ContextActionService",
                                     "CollectionService", "MarketplaceService", "DataStoreService", "Selection", "ChangeHistoryService",
                                     "PathfindingService", "TextService", "GuiService", "BadgeService", "PhysicsService", "InsertService",
                                     "StarterGui", "ProximityPromptService", "VRService", "HapticService", "GroupService", "MessagingService",
                                     "AssetService", "SocialService", "PolicyService", "LogService", "ContentProvider", "TeleportService",
                                     "MemoryStoreService", "AnalyticsService", "LocalizationService", "TextChatService", "Chat",
                                     "SoundService", "Lighting", "Teams", "ReplicatedStorage", "ReplicatedFirst", "ServerStorage",
                                     "ServerScriptService", "StarterPack", "StarterPlayer", "Players", "Workspace", "MaterialService",
                                     "CoreGui", "StudioService", "KeyframeSequenceProvider", "AnimationClipProvider", "VoiceChatService",
                                     "GamepadService", "Stats", "ScriptContext", "NotificationService", "AvatarEditorService", "UserService",
                                     "ExperienceService", "PlayerService"]
    static func byName(_ n: String) -> String? { ClassDb.isServiceName(n) || extra.contains(n) ? n : nil }
}

/// Service methods (port of lua/RobloxServices.kt).
enum Services {
    static let table: [String: Set<String>] = [
        "DataModel": ["GetService", "FindService", "IsLoaded", "BindToClose", "GetJobsInfo", "SetPlaceId", "GetObjects"],
        "Players": ["GetPlayers", "GetPlayerFromCharacter", "GetPlayerByUserId", "GetUserIdFromNameAsync", "GetNameFromUserIdAsync",
                    "GetUserThumbnailAsync", "GetHumanoidDescriptionFromUserId", "GetCharacterAppearanceInfoAsync",
                    "CreateHumanoidModelFromDescription", "GetFriendsAsync"],
        "RunService": ["IsClient", "IsServer", "IsStudio", "IsRunning", "IsRunMode", "IsEdit", "BindToRenderStep", "UnbindFromRenderStep",
                       "Pause", "Run", "Stop"],
        "TweenService": ["Create", "GetValue", "SmoothDamp"],
        "UserInputService": ["IsKeyDown", "IsMouseButtonPressed", "GetKeysPressed", "GetMouseLocation", "GetMouseDelta",
                             "GetLastInputType", "GetFocusedTextBox", "GetConnectedGamepads", "GetNavigationGamepads",
                             "GetMouseButtonsPressed", "GetStringForKeyCode", "GetGamepadConnected"],
        "ContextActionService": ["BindAction", "BindActionAtPriority", "UnbindAction", "UnbindAllActions", "SetTitle", "SetImage",
                                 "SetPosition", "SetDescription", "GetButton", "GetBoundActionInfo", "GetAllBoundActionInfo",
                                 "BindActivate", "UnbindActivate"],
        "CollectionService": ["GetTagged", "GetTags", "AddTag", "RemoveTag", "HasTag", "GetInstanceAddedSignal",
                              "GetInstanceRemovedSignal", "GetAllTags"],
        "HttpService": ["JSONEncode", "JSONDecode", "GenerateGUID", "UrlEncode", "GetAsync", "PostAsync", "RequestAsync", "GetSecret"],
        "Debris": ["AddItem", "addItem"],
        "DataStoreService": ["GetDataStore", "GetGlobalDataStore", "GetOrderedDataStore", "GetRequestBudgetForRequestType", "ListDataStoresAsync"],
        "DataStore": ["GetAsync", "SetAsync", "UpdateAsync", "RemoveAsync", "IncrementAsync", "GetSortedAsync", "ListKeysAsync"],
        "DataStorePages": ["GetCurrentPage", "AdvanceToNextPageAsync"],
        "MarketplaceService": ["PromptProductPurchase", "PromptGamePassPurchase", "PromptPurchase", "PromptPremiumPurchase",
                               "UserOwnsGamePassAsync", "PlayerOwnsAsset", "GetProductInfo", "PlayerOwnsBundle", "PromptBundlePurchase"],
        "TextService": ["GetTextSize", "FilterStringAsync", "GetTextBoundsAsync"],
        "TextFilterResult": ["GetNonChatStringForBroadcastAsync", "GetNonChatStringForUserAsync", "GetChatForUserAsync"],
        "GuiService": ["GetGuiInset", "IsTenFootInterface", "AddSelectionParent", "RemoveSelectionGroup", "GetScreenResolution"],
        "BadgeService": ["UserHasBadgeAsync", "AwardBadge", "GetBadgeInfoAsync", "CheckUserBadgesAsync"],
        "PhysicsService": ["RegisterCollisionGroup", "UnregisterCollisionGroup", "CollisionGroupSetCollidable", "CollisionGroupsAreCollidable",
                           "GetRegisteredCollisionGroups", "CreateCollisionGroup", "SetPartCollisionGroup", "IsCollisionGroupRegistered",
                           "GetMaxCollisionGroups", "RenameCollisionGroup"],
        "StarterGui": ["SetCoreGuiEnabled", "GetCoreGuiEnabled", "SetCore", "GetCore"],
        "PathfindingService": ["CreatePath", "FindPathAsync", "ComputeRawPathAsync"],
        "Path": ["ComputeAsync", "GetWaypoints", "CheckOcclusionAsync"],
        "Lighting": ["GetMinutesAfterMidnight", "SetMinutesAfterMidnight", "GetSunDirection", "GetMoonDirection", "GetMoonPhase"],
        "InsertService": ["LoadAsset", "LoadAssetVersion", "GetFreeModels", "CreateMeshPartAsync"],
        "TeleportService": ["Teleport", "TeleportAsync", "TeleportToPlaceInstance", "TeleportToPrivateServer", "ReserveServer",
                            "GetLocalPlayerTeleportData", "SetTeleportGui", "GetTeleportSetting", "SetTeleportSetting"],
        "MessagingService": ["PublishAsync", "SubscribeAsync"],
        "LogService": ["GetLogHistory", "ClearOutput"],
        "ContentProvider": ["PreloadAsync", "Preload"],
        "SoundService": ["PlayLocalSound", "SetListener", "GetListener"],
        "ChangeHistoryService": ["SetWaypoint", "Undo", "Redo", "ResetWaypoints", "GetCanUndo", "GetCanRedo", "TryBeginRecording",
                                 "FinishRecording", "SetEnabled", "IsRecordingInProgress"],
        "Selection": ["Get", "Set", "Add", "Remove"],
        "PolicyService": ["GetPolicyInfoForPlayerAsync", "GetPolicyInfoForServerAsync"],
        "SocialService": ["PromptGameInvite", "CanSendGameInviteAsync", "ShowSelfView", "HideSelfView"],
        "GroupService": ["GetGroupInfoAsync", "GetGroupsAsync", "GetAlliesAsync", "GetEnemiesAsync"],
        "AnalyticsService": ["LogEconomyEvent", "LogFunnelStepEvent", "LogProgressionEvent", "LogCustomEvent", "LogOnboardingFunnelStepEvent",
                             "FireEvent", "FireLogEvent", "FireCustomEvent"],
        "TextChannel": ["SendAsync", "DisplaySystemMessage"],
        "Chat": ["Chat", "FilterStringAsync", "FilterStringForBroadcast", "CanUserChatAsync"],
        "LocalizationService": ["GetTranslatorForPlayerAsync", "GetCountryRegionForPlayerAsync", "GetTranslatorForPlayer"],
        "AssetService": ["CreatePlaceAsync", "GetBundleDetailsAsync", "GetGamePlacesAsync"],
        "Teams": ["GetTeams"],
        "Team": ["GetPlayers"],
        "MemoryStoreService": ["GetSortedMap", "GetQueue", "GetHashMap"],
        "VRService": ["GetUserCFrame", "GetUserCFrameEnabled", "RecenterUserHeadCFrame"],
        "HapticService": ["IsVibrationSupported", "IsMotorSupported", "SetMotor", "GetMotor"],
        "Stats": ["GetTotalMemoryUsageMb", "GetMemoryUsageMbForTag"],
    ]

    static func methods(_ inst: Instance) -> Set<String> {
        if inst is DataModel { return table["DataModel"]! }
        return (table[inst.className] ?? []).union(PluginAPI.methods[inst.className] ?? [])
    }

    static func call(_ c: LuaCall, _ inst: Instance, _ m: String) throws -> Int32? {
        if let n = try PluginAPI.call(c, inst, m) { return n }
        let rt = c.rt
        let cls = inst is DataModel ? "DataModel" : inst.className
        guard table[cls]?.contains(m) == true else { return nil }
        switch (cls, m) {
        // MARK: DataModel
        case ("DataModel", "GetService"), ("DataModel", "FindService"):
            let n = try c.checkString(2, m)
            guard let s = ServiceRegistry.byName(n) else {
                if m == "FindService" { c.pushNil(); return 1 }
                throw LuaError("'\(n)' is not a valid Service name")
            }
            c.push(m == "FindService" ? rt.dm.findService(s) : rt.dm.getService(s)); return 1
        case ("DataModel", "IsLoaded"): c.push(true); return 1
        case ("DataModel", "BindToClose"):
            if c.isFunction(2) { _ = rt.connect(rt.dm, "Close", c.ref(2), once: true) }
            return 0
        case ("DataModel", "GetJobsInfo"): lua_createtable(c.L, 0, 0); return 1
        case ("DataModel", "SetPlaceId"): return 0
        case ("DataModel", "GetObjects"): throw LuaError("GetObjects needs network access (not available)")

        // MARK: Players
        case ("Players", "GetPlayers"): c.pushArray(inst.children.filter { $0.className == "Player" }) { c.push($0) }; return 1
        case ("Players", "GetPlayerFromCharacter"):
            let ch = c.instance(2)
            c.push(inst.children.first { $0.className == "Player" && $0.get("Character")?.asInstance === ch && ch != nil }); return 1
        case ("Players", "GetPlayerByUserId"):
            let id = c.optNumber(2, -1)
            c.push(inst.children.first { $0.className == "Player" && Double($0.get("UserId")?.asFloat ?? 1) == id }); return 1
        case ("Players", "GetUserIdFromNameAsync"): c.push(1); return 1
        case ("Players", "GetNameFromUserIdAsync"): c.push(inst.children.first { $0.className == "Player" }?.name ?? "Player1"); return 1
        case ("Players", "GetUserThumbnailAsync"): c.push("rbxasset://textures/ui/GuiImagePlaceholder.png"); c.push(true); return 2
        case ("Players", "GetHumanoidDescriptionFromUserId"): c.push(InstanceFactory.create("HumanoidDescription")); return 1
        case ("Players", "GetCharacterAppearanceInfoAsync"), ("Players", "GetFriendsAsync"): lua_createtable(c.L, 0, 0); return 1
        case ("Players", "CreateHumanoidModelFromDescription"):
            c.push(CharacterBuilder.buildR6(name: "Character")); return 1

        // MARK: RunService
        case ("RunService", "IsClient"), ("RunService", "IsServer"): c.push(true); return 1
        case ("RunService", "IsStudio"): c.push(true); return 1
        case ("RunService", "IsRunning"), ("RunService", "IsRunMode"): c.push(rt.isPlay); return 1
        case ("RunService", "IsEdit"): c.push(!rt.isPlay); return 1
        case ("RunService", "BindToRenderStep"):
            let name = try c.checkString(2, m)
            guard c.isFunction(4) else { throw c.argError(4, "function", m) }
            let cn = rt.connect(inst, "RenderStepped", c.ref(4), once: false)
            rt.renderStepBindings[name] = cn
            return 0
        case ("RunService", "UnbindFromRenderStep"):
            if let cn = rt.renderStepBindings.removeValue(forKey: try c.checkString(2, m)) { rt.disconnect(cn) }
            return 0
        case ("RunService", "Pause"), ("RunService", "Run"), ("RunService", "Stop"): return 0

        // MARK: TweenService
        case ("TweenService", "Create"):
            let target = try c.checkInstance(2, m)
            guard case .tweenInfo(let info)? = c.object(3) else { throw c.argError(3, "TweenInfo", m) }
            guard c.isTable(4) else { throw c.argError(4, "table", m) }
            var goals: [String: ScriptValue] = [:]
            if case .table(let kv) = rt.readValue(c.L, 4) {
                for (k, v) in kv { if case .string(let ks) = k { goals[ks] = v } }
            }
            c.push(.tween(Tween(inst: target, info: info, goals: goals))); return 1
        case ("TweenService", "GetValue"):
            let a = try c.checkFloat(2, m)
            c.push(Easing.ease(style: c.enumItem(3)?.value ?? 3, direction: c.enumItem(4)?.value ?? 1, a)); return 1
        case ("TweenService", "SmoothDamp"):
            c.push(c.vector3(3) ?? .zero); c.push(Vector3.zero); return 2

        // MARK: UserInputService
        case ("UserInputService", "IsKeyDown"):
            let k = c.enumItem(2)?.name ?? ""
            c.push(rt.host?.keyDown(k) ?? false); return 1
        case ("UserInputService", "IsMouseButtonPressed"): c.push(false); return 1
        case ("UserInputService", "GetKeysPressed"), ("UserInputService", "GetConnectedGamepads"),
             ("UserInputService", "GetNavigationGamepads"), ("UserInputService", "GetMouseButtonsPressed"):
            lua_createtable(c.L, 0, 0); return 1
        case ("UserInputService", "GetMouseLocation"), ("UserInputService", "GetMouseDelta"): c.push(.vector2(.zero)); return 1
        case ("UserInputService", "GetLastInputType"): c.push(.enumItem(ScriptEnums.item("UserInputType", "Touch")!)); return 1
        case ("UserInputService", "GetFocusedTextBox"): c.pushNil(); return 1
        case ("UserInputService", "GetStringForKeyCode"): c.push(c.enumItem(2)?.name ?? ""); return 1
        case ("UserInputService", "GetGamepadConnected"): c.push(false); return 1

        // MARK: ContextActionService
        case ("ContextActionService", "BindAction"), ("ContextActionService", "BindActionAtPriority"):
            let name = try c.checkString(2, m)
            guard c.isFunction(3) else { throw c.argError(3, "function", m) }
            let firstKey: Int32 = m == "BindActionAtPriority" ? 6 : 5
            var keys: [String] = []
            if c.top >= firstKey { for i in firstKey...c.top { if let e = c.enumItem(i) { keys.append(e.name) } } }
            rt.host?.bindAction(name, c.ref(3), touchButton: c.bool(4), keys: keys)
            return 0
        case ("ContextActionService", "UnbindAction"): rt.host?.unbindAction(try c.checkString(2, m)); return 0
        case ("ContextActionService", "UnbindAllActions"): return 0
        case ("ContextActionService", "SetTitle"): rt.host?.setActionTitle(try c.checkString(2, m), c.optString(3) ?? ""); return 0
        case ("ContextActionService", "SetImage"), ("ContextActionService", "SetPosition"), ("ContextActionService", "SetDescription"),
             ("ContextActionService", "BindActivate"), ("ContextActionService", "UnbindActivate"): return 0
        case ("ContextActionService", "GetButton"): c.pushNil(); return 1
        case ("ContextActionService", "GetBoundActionInfo"), ("ContextActionService", "GetAllBoundActionInfo"): lua_createtable(c.L, 0, 0); return 1

        // MARK: CollectionService
        case ("CollectionService", "GetTagged"):
            let t = try c.checkString(2, m)
            c.pushArray(rt.dm.descendants().filter { CollectionTags.tags(of: $0).contains(t) }) { c.push($0) }; return 1
        case ("CollectionService", "GetTags"):
            c.pushArray(CollectionTags.tags(of: try c.checkInstance(2, m))) { c.push($0) }; return 1
        case ("CollectionService", "AddTag"), ("CollectionService", "RemoveTag"), ("CollectionService", "HasTag"):
            let target = try c.checkInstance(2, m)
            lua_remove(c.L, 1)
            return try rt.api.callInstance(c, target, m)
        case ("CollectionService", "GetInstanceAddedSignal"):
            c.push(.signal(SignalRef(owner: CollectionTags.signalOwner(rt, try c.checkString(2, m)), name: "Added"))); return 1
        case ("CollectionService", "GetInstanceRemovedSignal"):
            c.push(.signal(SignalRef(owner: CollectionTags.signalOwner(rt, try c.checkString(2, m)), name: "Removed"))); return 1
        case ("CollectionService", "GetAllTags"):
            c.pushArray(Array(Set(rt.dm.descendants().flatMap { CollectionTags.tags(of: $0) })).sorted()) { c.push($0) }; return 1

        // MARK: HttpService
        case ("HttpService", "JSONEncode"):
            c.push(try JSON.encode(rt.readValue(c.L, 2))); return 1
        case ("HttpService", "JSONDecode"):
            c.push(try JSON.decode(try c.checkString(2, m))); return 1
        case ("HttpService", "GenerateGUID"):
            let g = UUID().uuidString
            c.push(c.isNil(2) || c.bool(2) ? "{\(g)}" : g); return 1
        case ("HttpService", "UrlEncode"):
            c.push((try c.checkString(2, m)).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""); return 1
        case ("HttpService", "GetSecret"): throw LuaError("Secrets are not available")
        case ("HttpService", "GetAsync"), ("HttpService", "PostAsync"), ("HttpService", "RequestAsync"):
            guard inst.get("HttpEnabled")?.asBool == true else { throw LuaError("Http requests are not enabled. Enable via game settings") }
            return try HttpRequests.perform(c, m)

        // MARK: Debris
        case ("Debris", "AddItem"), ("Debris", "addItem"):
            let item = try c.checkInstance(2, m)
            rt.after(c.optNumber(3, 10)) { item.destroy() }
            return 0

        // MARK: DataStores (in memory for the Play session, like the Android Studio.dataStores map)
        case ("DataStoreService", "GetDataStore"), ("DataStoreService", "GetGlobalDataStore"), ("DataStoreService", "GetOrderedDataStore"):
            let name = m == "GetGlobalDataStore" ? "global" : (try c.checkString(2, m))
            let scope = c.optString(3) ?? "global"
            let ds = Instance("DataStore")
            ds.name = name
            ds.set("StoreKey", .string("\(m == "GetOrderedDataStore" ? "ordered:" : "")\(name)/\(scope)"), notify: false)
            c.push(ds); return 1
        case ("DataStoreService", "GetRequestBudgetForRequestType"): c.push(100); return 1
        case ("DataStoreService", "ListDataStoresAsync"): c.push(DataStorePages.make([])); return 1
        case ("DataStore", _):
            return try DataStores.call(c, inst, m)
        case ("DataStorePages", "GetCurrentPage"):
            c.push(DataStorePages.current(inst)); return 1
        case ("DataStorePages", "AdvanceToNextPageAsync"):
            inst.set("IsFinished", .bool(true), notify: false); return 0

        // MARK: Marketplace / badges / social (offline answers)
        case ("MarketplaceService", "UserOwnsGamePassAsync"), ("MarketplaceService", "PlayerOwnsAsset"),
             ("MarketplaceService", "PlayerOwnsBundle"): c.push(false); return 1
        case ("MarketplaceService", "GetProductInfo"):
            c.push(.table([(.string("Name"), .string("Product")), (.string("PriceInRobux"), .number(0)),
                           (.string("Description"), .string("")), (.string("IsForSale"), .bool(false))])); return 1
        case ("MarketplaceService", let pm) where pm.hasPrefix("Prompt"):
            rt.log(.info, "Purchases aren't available in Play mode on this device")
            let player = c.instance(2), id = c.optNumber(3, 0)
            let ev = pm + "Finished"
            rt.after(0.1) { rt.fire(inst, ev, [player.map { .object(.instance($0)) } ?? .nil_, .number(id), .bool(false)]) }
            return 0
        case ("BadgeService", "UserHasBadgeAsync"): c.push(false); return 1
        case ("BadgeService", "AwardBadge"): c.push(true); return 1
        case ("BadgeService", "GetBadgeInfoAsync"):
            c.push(.table([(.string("Name"), .string("Badge")), (.string("IsEnabled"), .bool(true))])); return 1
        case ("BadgeService", "CheckUserBadgesAsync"): lua_createtable(c.L, 0, 0); return 1

        // MARK: TextService
        case ("TextService", "GetTextSize"), ("TextService", "GetTextBoundsAsync"):
            let text = c.string(2) ?? "", size = c.optFloat(3, 14)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let w = Float(lines.map(\.count).max() ?? 0) * size * 0.5
            c.push(.vector2(Vector2(w, Float(max(1, lines.count)) * size))); return 1
        case ("TextService", "FilterStringAsync"), ("Chat", "FilterStringAsync"):
            let r = Instance("TextFilterResult")
            r.set("Text", .string(c.string(2) ?? ""), notify: false)
            if cls == "Chat" { c.push(c.string(2) ?? ""); return 1 }
            c.push(r); return 1
        case ("Chat", "FilterStringForBroadcast"): c.push(c.string(2) ?? ""); return 1
        case ("Chat", "CanUserChatAsync"): c.push(true); return 1
        case ("Chat", "Chat"):
            rt.host?.chat(nil, c.string(3) ?? ""); return 0
        case ("TextFilterResult", _): c.push(inst.get("Text")?.asString ?? ""); return 1
        case ("TextChannel", "SendAsync"), ("TextChannel", "DisplaySystemMessage"):
            rt.host?.chat(m == "SendAsync" ? rt.dm.findService("Players")?.children.first { $0.className == "Player" } : nil, c.string(2) ?? "")
            c.pushNil(); return 1

        // MARK: GUI / StarterGui
        case ("GuiService", "GetGuiInset"): c.push(.vector2(Vector2(0, 58))); c.push(.vector2(.zero)); return 2
        case ("GuiService", "IsTenFootInterface"): c.push(false); return 1
        case ("GuiService", "GetScreenResolution"): c.push(.vector2(rt.host?.viewportSize() ?? Vector2(1280, 720))); return 1
        case ("GuiService", _): return 0
        case ("StarterGui", "SetCoreGuiEnabled"), ("StarterGui", "SetCore"): return 0
        case ("StarterGui", "GetCoreGuiEnabled"): c.push(true); return 1
        case ("StarterGui", "GetCore"): c.pushNil(); return 1

        // MARK: Physics / pathfinding
        case ("PhysicsService", "CollisionGroupSetCollidable"):
            let a = try c.checkString(2, m), b = try c.checkString(3, m)
            Physics.setCollidable(a, b, c.bool(4)); return 0
        case ("PhysicsService", "CollisionGroupsAreCollidable"):
            c.push(Physics.collidable(try c.checkString(2, m), try c.checkString(3, m))); return 1
        case ("PhysicsService", "RegisterCollisionGroup"), ("PhysicsService", "CreateCollisionGroup"):
            Physics.groups.insert(try c.checkString(2, m)); if m == "CreateCollisionGroup" { c.push(Physics.groups.count); return 1 }; return 0
        case ("PhysicsService", "UnregisterCollisionGroup"): Physics.groups.remove(try c.checkString(2, m)); return 0
        case ("PhysicsService", "IsCollisionGroupRegistered"): c.push(Physics.groups.contains(try c.checkString(2, m))); return 1
        case ("PhysicsService", "GetMaxCollisionGroups"): c.push(32); return 1
        case ("PhysicsService", "RenameCollisionGroup"): return 0
        case ("PhysicsService", "SetPartCollisionGroup"):
            let p = try c.checkInstance(2, m)
            p.set("CollisionGroup", .string(try c.checkString(3, m))); return 0
        case ("PhysicsService", "GetRegisteredCollisionGroups"):
            c.pushArray(["Default"] + Physics.groups.sorted().filter { $0 != "Default" }) { name in
                c.push(.table([(.string("name"), .string(name)), (.string("mask"), .number(-1))]))
            }
            return 1
        case ("PathfindingService", "CreatePath"):
            let path = Instance("Path")
            path.set("Status", .enumValue(EnumValue(0)), notify: false)
            c.push(path); return 1
        case ("PathfindingService", "FindPathAsync"), ("PathfindingService", "ComputeRawPathAsync"):
            let path = Instance("Path")
            Pathfinding.compute(path, from: try c.checkVector3(2, m), to: try c.checkVector3(3, m))
            c.push(path); return 1
        case ("Path", "ComputeAsync"):
            Pathfinding.compute(inst, from: try c.checkVector3(2, m), to: try c.checkVector3(3, m)); return 0
        case ("Path", "GetWaypoints"):
            let pts = Pathfinding.waypoints(inst)
            c.pushArray(pts) { p in
                c.push(.table([(.string("Position"), .object(.vector3(p))),
                               (.string("Action"), .object(.enumItem(EnumItem(enumType: "PathWaypointAction", name: "Walk", value: 0))))]))
            }
            return 1
        case ("Path", "CheckOcclusionAsync"): c.push(-1); return 1

        // MARK: Lighting
        case ("Lighting", "GetMinutesAfterMidnight"): c.push(Double(inst.get("ClockTime")?.asFloat ?? 14) * 60); return 1
        case ("Lighting", "SetMinutesAfterMidnight"):
            inst.set("ClockTime", .float(Float((try c.checkNumber(2, m)) / 60).truncatingRemainder(dividingBy: 24))); return 0
        case ("Lighting", "GetSunDirection"), ("Lighting", "GetMoonDirection"):
            let a = ((inst.get("ClockTime")?.asFloat ?? 14) - 6) / 12 * .pi
            let d = Vector3(-cos(a) * 0.75, sin(a), 0.45).unit
            c.push(m == "GetSunDirection" ? d : -d); return 1
        case ("Lighting", "GetMoonPhase"): c.push(0.75); return 1

        // MARK: Everything else that needs the network or a server: clear messages
        case ("InsertService", _): throw LuaError("InsertService:\(m) needs network access (not available)")
        case ("TeleportService", _):
            rt.log(.warn, "TeleportService:\(m) is not available in Play mode")
            if m == "ReserveServer" { c.push(""); c.push(""); return 2 }
            c.pushNil(); return 1
        case ("MessagingService", "PublishAsync"):
            let topic = try c.checkString(2, m), data = rt.readValue(c.L, 3)
            rt.fire(inst, "Topic:" + topic, [.table([(.string("Data"), data), (.string("Sent"), .number(Date().timeIntervalSince1970))])])
            return 0
        case ("MessagingService", "SubscribeAsync"):
            guard c.isFunction(3) else { throw c.argError(3, "function", m) }
            c.push(.connection(rt.connect(inst, "Topic:" + (try c.checkString(2, m)), c.ref(3), once: false))); return 1
        case ("LogService", "GetLogHistory"): lua_createtable(c.L, 0, 0); return 1
        case ("LogService", "ClearOutput"): return 0
        case ("ContentProvider", _): return 0
        case ("SoundService", "PlayLocalSound"): if let s = c.instance(2) { rt.host?.playSound(s) }; return 0
        case ("SoundService", "SetListener"): return 0
        case ("SoundService", "GetListener"): c.push(.enumItem(EnumItem(enumType: "ListenerType", name: "Camera", value: 0))); return 1
        case ("ChangeHistoryService", "GetCanUndo"), ("ChangeHistoryService", "GetCanRedo"), ("ChangeHistoryService", "IsRecordingInProgress"):
            c.push(false); return 1
        case ("ChangeHistoryService", "TryBeginRecording"): c.push("rec"); return 1
        case ("ChangeHistoryService", _): return 0
        case ("Selection", "Get"): c.pushArray(rt.selectionProvider()) { c.push($0) }; return 1
        case ("Selection", "Set"): rt.selectionSetter(try DataTypes.instances(c, 2)); return 0
        case ("Selection", "Add"), ("Selection", "Remove"):
            var cur = rt.selectionProvider()
            let items = try DataTypes.instances(c, 2)
            if m == "Add" { cur += items } else { cur.removeAll { x in items.contains { $0 === x } } }
            rt.selectionSetter(cur); return 0
        case ("PolicyService", _):
            c.push(.table([(.string("AreAdsAllowed"), .bool(false)), (.string("ArePaidRandomItemsRestricted"), .bool(false)),
                           (.string("IsSubjectToChinaPolicies"), .bool(false)), (.string("AllowedExternalLinkReferences"), .table([]))]))
            return 1
        case ("SocialService", "CanSendGameInviteAsync"): c.push(false); return 1
        case ("SocialService", _): return 0
        case ("GroupService", _): lua_createtable(c.L, 0, 0); return 1
        case ("AnalyticsService", _): return 0
        case ("LocalizationService", "GetCountryRegionForPlayerAsync"): c.push("US"); return 1
        case ("LocalizationService", _): throw LuaError("Translators are not available")
        case ("AssetService", _): throw LuaError("AssetService:\(m) needs network access (not available)")
        case ("Teams", "GetTeams"): c.pushArray(inst.children.filter { $0.className == "Team" }) { c.push($0) }; return 1
        case ("Team", "GetPlayers"):
            let players = rt.dm.findService("Players")?.children.filter { p in
                p.className == "Player" && { if case .brickColor(let b)? = p.get("TeamColor"), case .brickColor(let t)? = inst.get("TeamColor") { return b == t }; return false }()
            } ?? []
            c.pushArray(players) { c.push($0) }; return 1
        case ("MemoryStoreService", _): throw LuaError("MemoryStoreService is not available in Play mode")
        case ("VRService", "GetUserCFrame"): c.push(CFrame.identity); return 1
        case ("VRService", _): c.push(false); return 1
        case ("HapticService", _): c.push(false); return 1
        case ("Stats", _): c.push(Double(lua_gc(c.L, 3, 0)) / 1024); return 1
        default:
            return nil
        }
    }
}

/// In-memory DataStores for the Play session.
enum DataStores {
    static func call(_ c: LuaCall, _ ds: Instance, _ m: String) throws -> Int32 {
        let rt = c.rt
        let store = ds.get("StoreKey")?.asString ?? ds.name
        func key() throws -> String {
            if let s = c.string(2) { return s }
            throw c.argError(2, "string", m)
        }
        switch m {
        case "GetAsync":
            c.push(rt.dataStores[store]?[try key()] ?? .nil_)
            c.pushNil()
            return 2
        case "SetAsync":
            rt.dataStores[store, default: [:]][try key()] = rt.readValue(c.L, 3)
            c.push("1"); return 1
        case "RemoveAsync":
            let k = try key()
            let old = rt.dataStores[store]?[k] ?? .nil_
            rt.dataStores[store]?[k] = nil
            c.push(old); return 1
        case "IncrementAsync":
            let k = try key()
            var n: Double = 0
            if case .number(let x)? = rt.dataStores[store]?[k] { n = x }
            n += c.optNumber(3, 1)
            rt.dataStores[store, default: [:]][k] = .number(n)
            c.push(n); return 1
        case "UpdateAsync":
            let k = try key()
            guard c.isFunction(3) else { throw c.argError(3, "function", m) }
            let fn = c.ref(3)
            let old = rt.dataStores[store]?[k] ?? .nil_
            // Run the transform, then store whatever it returned (via a tiny Lua shim).
            let saver = rt.storeSaver(store: store, key: k)
            return try rt.callLua(c, saver, [.function(fn), old])
        case "GetSortedAsync":
            let ascending = c.bool(2)
            let size = Int(c.optNumber(3, 50))
            var entries: [(String, Double)] = (rt.dataStores[store] ?? [:]).compactMap { k, v in
                if case .number(let n) = v { return (k, n) }; return nil
            }
            entries.sort { ascending ? $0.1 < $1.1 : $0.1 > $1.1 }
            c.push(DataStorePages.make(Array(entries.prefix(size)))); return 1
        case "ListKeysAsync":
            c.push(DataStorePages.make((rt.dataStores[store] ?? [:]).keys.sorted().map { ($0, 0) })); return 1
        default:
            throw LuaError("\(m) is not a valid member of DataStore")
        }
    }
}

enum DataStorePages {
    private static var pages: [ObjectIdentifier: [(String, Double)]] = [:]
    static func make(_ entries: [(String, Double)]) -> Instance {
        let p = Instance("DataStorePages")
        p.set("IsFinished", .bool(true), notify: false)
        pages[ObjectIdentifier(p)] = entries
        return p
    }
    static func current(_ p: Instance) -> ScriptValue {
        let entries = pages[ObjectIdentifier(p)] ?? []
        return .table(entries.enumerated().map { (i, e) in
            (.number(Double(i + 1)), .table([(.string("key"), .string(e.0)), (.string("value"), .number(e.1))]))
        })
    }
}

extension ScriptRuntime {
    /// Lua function `(transform, old) -> new` that also stores the result (DataStore:UpdateAsync).
    func storeSaver(store: String, key: String) -> LuaRef {
        guard let L = mainState else { fatalError("runtime closed") }
        let src = "local save = ... return function(f, old) local new = f(old) if new ~= nil then save(new) end return new end"
        try? load(L, src, chunk: "UpdateAsync")
        pushFunction(L, "save") { [unowned self] c in
            self.dataStores[store, default: [:]][key] = self.readValue(c.L, 1)
            return 0
        }
        _ = lua_pcall(L, 1, 1, 0)
        let r = refValue(L, -1)
        lua_settop(L, -2)
        return r
    }
}
