#include "module_json.h"
#include "module_json_ext.h"

#include <cJSON.h>
#include <LuaBridge.h>

void init_json_module(lua_State* L)
{
	luabridge::getGlobalNamespace(L)
		.beginNamespace("Engine")
			.beginNamespace("JSON")
				// usertype
				.beginClass<cJSON>("ImGuiViewport")
					.addProperty("next", &cJSON::next)
					.addProperty("prev", &cJSON::prev)
					.addProperty("child", &cJSON::child)
					.addProperty("type", &cJSON::type)
					.addProperty("string", &cJSON::valuestring)
					.addProperty("int", &cJSON::valueint)
					.addProperty("double", &cJSON::valuedouble)
					.addProperty("name", &cJSON::string)
				.endClass()
				// function
				.addFunction("Parse", cJSON_Parse)
				.addFunction("ParseWithLength", cJSON_ParseWithLength)
				.addFunction("Delete", cJSON_Delete)
				.addFunction("CreateArray", cJSON_CreateArray)
				.addFunction("CreateObject", cJSON_CreateObject)
				.addFunction("AddItemToArray", cJSON_AddItemToArray)
				.addFunction("AddItemToObject", cJSON_AddItemToObject)
				.addFunction("CreateBool", cJSON_CreateBool)
				.addFunction("CreateString", cJSON_CreateString)
				.addFunction("CreateNumber", cJSON_CreateNumber)
				.addFunction("GetObjectItem", cJSON_GetObjectItem)
				.addFunction("Print", +[](cJSON* json, luabridge::LuaRef format, lua_State* L) 
					{
						char* buffer = (format ? format : false) ? cJSON_Print(json) : cJSON_PrintUnformatted(json);
						lua_pushstring(L, buffer); free(buffer);
					})
				.addFunction("ParseToLua", JSON_ParseToLua)
				.addFunction("PrintFromLua", JSON_PrintFromLua)
			.endNamespace()
		.endNamespace();
}
