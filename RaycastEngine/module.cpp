#include "module.h"

#include "module_sdl.h"
#include "module_json.h"
#include "module_util.h"
#include "module_imgui.h"
#include "module_raylib.h"
#include "module_micro_pather.h"

void init_modules(lua_State* L)
{
	init_sdl_module(L);
	init_json_module(L);
	init_util_module(L);
	init_imgui_module(L);
	init_raylib_module(L);
	init_micro_pather_module(L);
}