#pragma once

#include "module.h"

#include <string>

struct CString
{
	std::string val;

	CString() = default;
	CString(const char* str) : val(str) {}
	CString(const char c, size_t num) : val(num, c) {}
};

void init_util_module(lua_State* L);