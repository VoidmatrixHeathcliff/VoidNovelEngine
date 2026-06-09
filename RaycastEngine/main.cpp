#include "module.h"

#include <lua.hpp>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <ctime>
#include <exception>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <string>

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <Windows.h>
#endif

namespace
{
	std::string CurrentTimestamp()
	{
		const auto now = std::chrono::system_clock::now();
		const std::time_t time = std::chrono::system_clock::to_time_t(now);
		std::tm localTime = {};
#if defined(_WIN32)
		localtime_s(&localTime, &time);
#else
		localtime_r(&time, &localTime);
#endif

		std::ostringstream stream;
		stream << std::put_time(&localTime, "%Y-%m-%d %H:%M:%S");
		return stream.str();
	}

	void AppendDiagnosticLog(const char* fileName, const std::string& message)
	{
		std::ofstream file(fileName, std::ios::app);
		if (!file.is_open())
			return;

		file << "[" << CurrentTimestamp() << "] " << message << "\n";
	}

#if defined(_WIN32)
	std::string FormatUnhandledException(EXCEPTION_POINTERS* exceptionPointers)
	{
		std::ostringstream stream;
		stream << "Unhandled SEH exception";
		if (exceptionPointers != nullptr && exceptionPointers->ExceptionRecord != nullptr)
		{
			const EXCEPTION_RECORD* record = exceptionPointers->ExceptionRecord;
			stream << ", code=0x" << std::hex << std::uppercase << record->ExceptionCode;
			stream << ", address=0x" << reinterpret_cast<std::uintptr_t>(record->ExceptionAddress);
		}
		return stream.str();
	}

	std::string FormatWindowsError(const char* action, DWORD errorCode)
	{
		std::ostringstream stream;
		stream << action << " failed, error=" << errorCode;
		return stream.str();
	}

	std::wstring GetExecutablePathWide(std::string* error = nullptr)
	{
		DWORD capacity = MAX_PATH;
		for (;;)
		{
			std::wstring buffer(capacity, L'\0');
			DWORD length = GetModuleFileNameW(nullptr, buffer.data(), capacity);
			if (length == 0)
			{
				if (error) *error = FormatWindowsError("GetModuleFileNameW", GetLastError());
				return std::wstring();
			}

			if (length < capacity)
			{
				buffer.resize(length);
				return buffer;
			}

			capacity *= 2;
		}
	}

	std::wstring GetDirectoryName(std::wstring path)
	{
		size_t separator = path.find_last_of(L"\\/");
		if (separator == std::wstring::npos)
			return std::wstring();
		if (separator == 0)
			return path.substr(0, 1);
		if (path[separator - 1] == L':')
			return path.substr(0, separator + 1);
		return path.substr(0, separator);
	}

	std::wstring JoinPath(const std::wstring& directory, const wchar_t* fileName)
	{
		if (directory.empty())
			return fileName ? std::wstring(fileName) : std::wstring();

		std::wstring path = directory;
		if (path.back() != L'\\' && path.back() != L'/')
			path.push_back(L'\\');
		if (fileName)
			path += fileName;
		return path;
	}

	bool SetWorkingDirectoryToExecutableDirectory(std::wstring& executableDirectory, std::string& error)
	{
		std::string pathError;
		std::wstring executablePath = GetExecutablePathWide(&pathError);
		if (executablePath.empty())
		{
			error = pathError.empty() ? "failed to resolve executable path" : pathError;
			return false;
		}

		executableDirectory = GetDirectoryName(executablePath);
		if (executableDirectory.empty())
		{
			error = "failed to resolve executable directory";
			return false;
		}

		if (!SetCurrentDirectoryW(executableDirectory.c_str()))
		{
			error = FormatWindowsError("SetCurrentDirectoryW", GetLastError());
			return false;
		}

		return true;
	}

	bool ReadFileBytesWide(const std::wstring& path, std::string& content, std::string& error)
	{
		HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
			FILE_ATTRIBUTE_NORMAL, nullptr);
		if (file == INVALID_HANDLE_VALUE)
		{
			error = FormatWindowsError("CreateFileW", GetLastError());
			return false;
		}

		LARGE_INTEGER fileSize{};
		if (!GetFileSizeEx(file, &fileSize))
		{
			error = FormatWindowsError("GetFileSizeEx", GetLastError());
			CloseHandle(file);
			return false;
		}

		if (fileSize.QuadPart < 0 || static_cast<unsigned long long>(fileSize.QuadPart) > content.max_size())
		{
			error = "startup script is too large";
			CloseHandle(file);
			return false;
		}

		content.assign(static_cast<size_t>(fileSize.QuadPart), '\0');
		size_t offset = 0;
		while (offset < content.size())
		{
			DWORD chunkSize = static_cast<DWORD>(std::min<size_t>(content.size() - offset, 1024 * 1024));
			DWORD bytesRead = 0;
			if (!ReadFile(file, content.data() + offset, chunkSize, &bytesRead, nullptr))
			{
				error = FormatWindowsError("ReadFile", GetLastError());
				CloseHandle(file);
				return false;
			}
			if (bytesRead == 0)
				break;
			offset += bytesRead;
		}

		CloseHandle(file);
		if (offset != content.size())
			content.resize(offset);
		return true;
	}

	void NormalizeStartupScriptForLua(std::string& script)
	{
		if (script.size() >= 3
			&& static_cast<unsigned char>(script[0]) == 0xEF
			&& static_cast<unsigned char>(script[1]) == 0xBB
			&& static_cast<unsigned char>(script[2]) == 0xBF)
		{
			script.erase(0, 3);
		}

		if (!script.empty() && script[0] == '#')
		{
			size_t lineEnd = script.find_first_of("\r\n");
			if (lineEnd == std::string::npos)
			{
				script.assign("\n");
				return;
			}

			size_t nextLine = lineEnd + 1;
			if (script[lineEnd] == '\r' && nextLine < script.size() && script[nextLine] == '\n')
				++nextLine;
			script.erase(0, nextLine);
			script.insert(0, "\n");
		}
	}

	int LoadAndRunStartupScript(lua_State* L, const std::wstring& executableDirectory)
	{
		std::wstring scriptPath = JoinPath(executableDirectory, L"main.lua");
		std::string script;
		std::string error;
		if (!ReadFileBytesWide(scriptPath, script, error))
		{
			std::string message = "failed to read startup script main.lua: " + error;
			lua_pushlstring(L, message.data(), message.size());
			return LUA_ERRFILE;
		}

		NormalizeStartupScriptForLua(script);
		int loadResult = luaL_loadbufferx(L, script.data(), script.size(), "@main.lua", "bt");
		if (loadResult != LUA_OK)
			return loadResult;

		return lua_pcall(L, 0, LUA_MULTRET, 0);
	}

	LONG WINAPI VneUnhandledExceptionFilter(EXCEPTION_POINTERS* exceptionPointers)
	{
		AppendDiagnosticLog("crash_report.log", FormatUnhandledException(exceptionPointers));
		return EXCEPTION_EXECUTE_HANDLER;
	}
#endif

	void VneTerminateHandler() noexcept
	{
		std::string message = "std::terminate called";
		try
		{
			std::exception_ptr exception = std::current_exception();
			if (exception)
				std::rethrow_exception(exception);
		}
		catch (const std::exception& ex)
		{
			message += std::string(": ") + ex.what();
		}
		catch (...)
		{
			message += ": unknown exception";
		}

		AppendDiagnosticLog("terminate_report.log", message);
		std::abort();
	}
}

int main(int argc, char** argv)
{
#if defined(_WIN32)
	SetUnhandledExceptionFilter(VneUnhandledExceptionFilter);
#endif
	std::set_terminate(VneTerminateHandler);

#if defined(_WIN32)
	std::wstring executableDirectory;
	{
		std::string error;
		if (!SetWorkingDirectoryToExecutableDirectory(executableDirectory, error))
		{
			AppendDiagnosticLog("terminate_report.log", std::string("Startup path initialization failed: ") + error);
			return -1;
		}
	}
#endif

	lua_State* L = luaL_newstate();
	if (L == nullptr)
	{
		AppendDiagnosticLog("terminate_report.log", "luaL_newstate failed");
		return -1;
	}

	try
	{
		luaL_openlibs(L);
		init_modules(L);
	}
	catch (const std::exception& ex)
	{
		AppendDiagnosticLog("terminate_report.log", std::string("C++ exception during startup: ") + ex.what());
		lua_close(L);
		return -1;
	}
	catch (...)
	{
		AppendDiagnosticLog("terminate_report.log", "Unknown C++ exception during startup");
		lua_close(L);
		return -1;
	}

	int luaResult = 0;
	try
	{
#if defined(_WIN32)
		luaResult = LoadAndRunStartupScript(L, executableDirectory);
#else
		luaResult = luaL_dofile(L, "main.lua");
#endif
	}
	catch (const std::exception& ex)
	{
		AppendDiagnosticLog("terminate_report.log", std::string("C++ exception during Lua execution: ") + ex.what());
		lua_close(L);
		return -1;
	}
	catch (...)
	{
		AppendDiagnosticLog("terminate_report.log", "Unknown C++ exception during Lua execution");
		lua_close(L);
		return -1;
	}

	if (luaResult != 0)
	{
		const char* message = lua_tostring(L, -1);
		printf("\n%s\n", message ? message : "unknown Lua error");
		AppendDiagnosticLog("terminate_report.log", std::string("Lua startup error: ") + (message ? message : "unknown Lua error"));
		lua_close(L);
		return -1;
	}

	lua_close(L);
	return 0;
}
