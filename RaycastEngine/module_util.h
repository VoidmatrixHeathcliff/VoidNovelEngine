#pragma once

#include "module.h"

#include <string>
#include <vector>

struct CString
{
	std::string val;

	CString() = default;
	CString(const char* str) : val(str) {}
	CString(const char c, size_t num) : val(num, c) {}
};

struct PathList
{
	std::vector<std::string> list;
};

struct ProcessResult
{
	bool success = false;
	int exit_code = -1;
	std::string stdout_content;
	std::string stderr_content;
	std::string message;
};

struct ProcessPipe
{
	void* process_handle = nullptr;
	void* thread_handle = nullptr;
	void* stdout_read_handle = nullptr;
	void* null_write_handle = nullptr;
	bool is_open = false;
};

void init_util_module(lua_State* L);
