# Mobile Studio for iOS (phase 1: core editor)

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

## Phase 1 scope

**Ported:** opening `.rbxl/.rbxlx/.rbxm/.rbxmx` from Files, creating new places (Baseplate,
Classic and Empty), rendering parts (block, sphere, cylinder, wedge and corner wedge with
materials and surfaces), select (tap, multi-select, select inside models), Move/Scale/Rotate
handles with snapping, Explorer (expand, filter, rename, drag to reparent, context menu),
Properties (typed editors, multi-edit), insert part or object, undo/redo, save `.rbxl`, and
export the selection as `.rbxm`.

**Not ported yet (later phases):**
- Luau runtime and Play mode: `lua/*` (about 18k lines, built on LuaJ) and `engine/PlaySession`
- Avatars and animation: `engine/Avatar`, `AnimPlayer`
- Physics and collisions
- Audio
- Meshes: MeshPart, unions, CSG and Draco. These currently draw as boxes.
- GUI overlay, SurfaceGuis and decals
- Shadow maps and procedural materials
- Roblox account login, cloud publish and Toolbox (`net/*`)
- Plugins
- XML *writing*: `.rbxlx` files are saved as binary `.rbxl`
- Syntax highlighting and autocomplete in the script editor
- The long `InstanceFactory.extraDefaults` table

**Not verified:** this code was written on Windows without a Swift compiler. Expect a round of
small compile fixes the first time it is built in Xcode.
