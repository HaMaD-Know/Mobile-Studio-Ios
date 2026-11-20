// Bridge implementation, see include/luau_swift.h.
#include "luau_swift.h"
#include "lualib.h"
#include "luacode.h"

#include <stdlib.h>
#include <string.h>

static luau_swift_dispatch_fn g_dispatch = nullptr;
static volatile double g_deadline = 0;

extern "C" void luau_swift_set_dispatch(luau_swift_dispatch_fn fn) { g_dispatch = fn; }

static int trampoline(lua_State* L)
{
    int id = lua_tointeger(L, lua_upvalueindex(1));
    int raise = 0;
    int r = g_dispatch ? g_dispatch(L, id, &raise) : 0;
    if (raise)
        lua_error(L); // error value is on top of the stack
    return r;
}

extern "C" void luau_swift_pushfunction(lua_State* L, int id, const char* debugname)
{
    lua_pushinteger(L, id);
    lua_pushcclosurek(L, trampoline, debugname, 1, nullptr);
}

static void interrupt(lua_State* L, int gc)
{
    if (gc >= 0)
        return;
    double d = g_deadline;
    if (d > 0 && lua_clock() > d)
    {
        g_deadline = 0;
        luaL_errorL(L, "Script timeout: exhausted allowed execution time");
    }
}

extern "C" void luau_swift_set_deadline(double deadline) { g_deadline = deadline; }
extern "C" void luau_swift_install_interrupt(lua_State* L) { lua_callbacks(L)->interrupt = interrupt; }

extern "C" char* luau_swift_compile(const char* source, size_t size, size_t* outsize)
{
    lua_CompileOptions opts;
    memset(&opts, 0, sizeof(opts));
    opts.optimizationLevel = 1;
    opts.debugLevel = 1;
    return luau_compile(source, size, &opts, outsize);
}

extern "C" int luau_swift_registryindex(void) { return LUA_REGISTRYINDEX; }
extern "C" int luau_swift_globalsindex(void) { return LUA_GLOBALSINDEX; }
extern "C" int luau_swift_upvalueindex(int i) { return lua_upvalueindex(i); }

static int tostring_impl(lua_State* L)
{
    luaL_tolstring(L, 1, nullptr);
    return 1;
}

extern "C" int luau_swift_tostring(lua_State* L, int idx)
{
    idx = lua_absindex(L, idx);
    lua_pushcclosurek(L, tostring_impl, "tostring", 0, nullptr);
    lua_pushvalue(L, idx);
    return lua_pcall(L, 1, 1, 0);
}
