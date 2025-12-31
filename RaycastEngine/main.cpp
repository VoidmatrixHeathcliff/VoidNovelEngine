#include "module.h"

#include <lua.hpp>

int main(int argc, char** argv)
{
	lua_State* L = luaL_newstate();
	luaL_openlibs(L);

	init_modules(L);

	if (luaL_dofile(L, "main.lua"))
	{
		printf("\n%s\n", lua_tostring(L, -1));
		return -1;
	}

	return 0;
}