# Vendored Luau

Source: https://github.com/luau-lang/luau, tag `0.744` (MIT, see LICENSE.txt).
Only `Common`, `Ast`, `Bytecode`, `Compiler` and `VM` are included.

Local changes:
- `lua.h`, `luaconf.h`, `lualib.h` (from `VM/include`) and `luacode.h` (from `Compiler/include`)
  moved to `Sources/Luau/include` so SwiftPM exposes them as the module's public C headers.
- `luaconf.h` / `luacode.h`: `LUA_API` / `LUACODE_API` default to `extern "C"` when compiled as
  C++, so Swift can link against the C API.

Added (not upstream):
- `include/luau_swift.h` + `SwiftShim/luau_swift.cpp`: Swift bridge (error-safe trampoline,
  execution deadline interrupt, compile helper, pseudo-index helpers).
