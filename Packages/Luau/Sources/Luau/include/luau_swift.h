// Small C bridge between Swift and the Luau C API (not part of upstream Luau).
// Swift must never let a C++ exception (lua_error) unwind through its frames, so:
//  - Lua -> Swift calls go through a C++ trampoline. Swift reports errors via *raise
//    (with the message on the stack) and the trampoline raises them after Swift returns.
//  - Swift -> Lua calls use lua_pcall / lua_resume, which catch errors internally.
#pragma once
#include "lua.h"
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Swift handler for every Swift-backed Lua function. `id` identifies the Swift closure.
/// Return the number of results (or the value returned by lua_yield). Set *raise = 1 to
/// raise the error value currently on top of the stack.
typedef int (*luau_swift_dispatch_fn)(lua_State* L, int id, int* raise);

void luau_swift_set_dispatch(luau_swift_dispatch_fn fn);

/// Push a Lua function that calls the dispatch handler with `id`.
void luau_swift_pushfunction(lua_State* L, int id, const char* debugname);

/// Execution deadline (in lua_clock() seconds) checked at VM safepoints; 0 disables.
void luau_swift_set_deadline(double deadline);
/// Install the deadline interrupt on a state.
void luau_swift_install_interrupt(lua_State* L);

/// Compile Luau source to bytecode (caller frees with free()). On a syntax error the
/// returned bytecode encodes the error and luau_load reports it.
char* luau_swift_compile(const char* source, size_t size, size_t* outsize);

/// Pseudo-indices (macros upstream).
int luau_swift_registryindex(void);
int luau_swift_globalsindex(void);
int luau_swift_upvalueindex(int i);

/// Protected tostring (honours __tostring). Pushes the string; returns 0 on success.
int luau_swift_tostring(lua_State* L, int idx);

#ifdef __cplusplus
}
#endif
