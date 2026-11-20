# Mobile Studio for iOS

This is a Swift/SwiftUI/Metal port of the Android app `com.exampletest.mobilestudiotest`. It was
rebuilt from the decompiled APK, which is in `../_decompiled/` (`sources/` is the raw jadx
output and `clean/` is a stripped copy that's easier to read).

## Build (needs a Mac with Xcode 15.3 or later)

```sh
brew install xcodegen
cd ios
xcodegen                      # creates MobileStudio.xcodeproj from project.yml
open MobileStudio.xcodeproj   # pick your team under Signing, then run on a device or simulator
```

Core tests: `swift test --package-path Packages/StudioCore`

No Mac? `.github/workflows/ios.yml` runs the tests and a simulator build on GitHub's macOS
runners on every push (see the repository's Actions tab).

## Install on an iPhone from Windows

Every CI run also builds an unsigned `MobileStudio.ipa`.

1. Open the latest run under **Actions**. Download **MobileStudio-unsigned-ipa** from
   *Artifacts* and unzip it.
2. Install [Sideloadly](https://sideloadly.io) and iTunes, and connect the iPhone by USB.
3. Drag `MobileStudio.ipa` into Sideloadly, enter your Apple ID, and click **Start**.
4. On the iPhone, trust your Apple ID under *Settings → General → VPN & Device Management*.
   On iOS 16 and later, also turn on *Settings → Privacy & Security → Developer Mode*.

With a free Apple ID the app expires after 7 days. Re-install it with Sideloadly to renew.

## Layout

| Path | What it is | Ported from (Android) |
|---|---|---|
| `Packages/StudioCore/Model` | Instance tree, DataModel, value types, ClassDb, enums, BrickColors, InstanceFactory, PartData | `model/*` |
| `Packages/StudioCore/Format` | `.rbxl`/`.rbxm` binary reader and writer (LZ4 + ZSTD), `.rbxlx`/`.rbxmx` XML reader, gzip unwrap | `format/*` |
| `Packages/StudioCore/Core` | PlaceFactory templates, UndoManager, EditSession (selection, insert, delete, duplicate, copy/paste, group) | `core/PlaceFactory`, `core/UndoManager`, `core/Studio` |
| `Packages/StudioCore/Generated` | BrickColor, Enum and ClassDb tables generated from the decompiled source by `tools/gen_tables.py` | `model/BrickColors`, `Enums`, `ClassDb` |
| `MobileStudio/Render` | Metal renderer with the original GLSL shaders ported (studs and surface types, material textures and normal maps, sky), mesh shapes, fly camera, picking | `render/SceneRenderer`, `Meshes`, `FlyCamera`, `MaterialTextures` |
| `MobileStudio/UI` | Start screen, viewport gestures, Move/Scale/Rotate handles, Explorer, Properties, Output, simple script editor | `ui/*` |
| `MobileStudio/Resources/materials` | Material textures, copied unchanged from the APK's `assets/materials` | |

## What's ported

- **Editor:** open/save `.rbxl/.rbxlx/.rbxm/.rbxmx`, new place templates, Explorer, Properties,
  Move/Scale/Rotate with snapping, undo/redo, insert objects, Toolbox, plugins (toolbar buttons,
  settings, dock widgets), command bar, Luau script editor (highlighting, autocomplete, syntax check).
- **Rendering:** parts with materials and surfaces, MeshParts / SpecialMeshes (mesh v1-v7 incl. Draco),
  unions (CSG v2-v6), decals and textures, sun shadows, sky.
- **Scripting (Luau 0.744):** Roblox data types, Instance API, ~40 services, task scheduler, signals,
  require, tweens, DataStores (in memory), HttpService (when HttpEnabled).
- **Play mode:** R6 and R15 characters with Roblox's default animations, your Roblox avatar
  (body colours, shirts, pants, T-shirts, accessories, face) when signed in, physics with joints,
  touches, camera, tools, prompts, chat, leaderstats, ScreenGuis/BillboardGuis/SurfaceGuis.
- **Roblox account:** sign in, Open Cloud API key, open your places, publish.

## Known limits

- Physics is simplified (translation-only rigid bodies, no rotation dynamics).
- SurfaceGuis are drawn as screen overlays over their face, not rendered into the 3D surface.
- R15 uses a blocky rig; R15 body meshes from your avatar aren't loaded (accessories are).
- Solid modeling (Union/Negate) isn't available; Draco edgebreaker meshes are skipped (as on Android).
- Purchases, teleports and server/client separation aren't simulated.
