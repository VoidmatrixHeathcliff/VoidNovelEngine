#include "module_util.h"
#include "module_util_ext.h"

#include <LuaBridge.h>

#include <vector>
#include <fstream>
#include <sstream>
#include <filesystem>
#include <cctype>

#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

namespace
{
	std::wstring Utf8ToWide(const char* value, std::string* error = nullptr)
	{
		if (value == nullptr || value[0] == '\0')
			return std::wstring();

		int wideLength = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, nullptr, 0);
		if (wideLength <= 0)
		{
			if (error) *error = "UTF-8 字符串转换为 UTF-16 失败";
			return std::wstring();
		}

		std::wstring wideValue(static_cast<size_t>(wideLength), L'\0');
		if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, wideValue.data(), wideLength) <= 0)
		{
			if (error) *error = "UTF-8 字符串转换为 UTF-16 失败";
			return std::wstring();
		}
		wideValue.resize(static_cast<size_t>(wideLength) - 1);
		return wideValue;
	}

	std::string WideToUtf8(const std::wstring& value, std::string* error = nullptr)
	{
		if (value.empty())
			return std::string();

		int utf8Length = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
		if (utf8Length <= 0)
		{
			if (error) *error = "UTF-16 字符串转换为 UTF-8 失败";
			return std::string();
		}

		std::string utf8Value(utf8Length, '\0');
		if (WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), utf8Value.data(), utf8Length, nullptr, nullptr) <= 0)
		{
			if (error) *error = "UTF-16 字符串转换为 UTF-8 失败";
			return std::string();
		}
		return utf8Value;
	}

	int Util_UTF8Len(lua_State* pLuaVM)
	{
		std::string error;
		std::wstring wideText = Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error);
		if (!error.empty())
			return luaL_error(pLuaVM, "%s", error.c_str());

		lua_pushinteger(pLuaVM, static_cast<lua_Integer>(wideText.size()));
		return 1;
	}

	int Util_UTF8Sub(lua_State* pLuaVM)
	{
		std::string error;
		std::wstring wideText = Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error);
		if (!error.empty())
			return luaL_error(pLuaVM, "%s", error.c_str());

		int offset = static_cast<int>(luaL_checkinteger(pLuaVM, 2));
		int count = static_cast<int>(luaL_checkinteger(pLuaVM, 3));
		size_t start = offset <= 0 ? 0 : static_cast<size_t>(offset);
		if (start >= wideText.size())
		{
			lua_pushliteral(pLuaVM, "");
			return 1;
		}

		size_t length = count < 0 ? std::wstring::npos : static_cast<size_t>(count);
		std::string utf8Text = WideToUtf8(wideText.substr(start, length), &error);
		if (!error.empty())
			return luaL_error(pLuaVM, "%s", error.c_str());

		lua_pushlstring(pLuaVM, utf8Text.data(), utf8Text.size());
		return 1;
	}
}

static HANDLE ProcessPipeHandle(void* handle)
{
	return reinterpret_cast<HANDLE>(handle);
}

static void CloseProcessPipeHandles(ProcessPipe* pipe)
{
	if (!pipe) return;
	if (pipe->stdout_read_handle)
	{
		CloseHandle(ProcessPipeHandle(pipe->stdout_read_handle));
		pipe->stdout_read_handle = nullptr;
	}
	if (pipe->null_write_handle)
	{
		CloseHandle(ProcessPipeHandle(pipe->null_write_handle));
		pipe->null_write_handle = nullptr;
	}
	if (pipe->thread_handle)
	{
		CloseHandle(ProcessPipeHandle(pipe->thread_handle));
		pipe->thread_handle = nullptr;
	}
	if (pipe->process_handle)
	{
		CloseHandle(ProcessPipeHandle(pipe->process_handle));
		pipe->process_handle = nullptr;
	}
	pipe->is_open = false;
}

static void CloseAndDestroyProcessPipe(ProcessPipe* pipe)
{
	if (!pipe) return;
	if (pipe->process_handle)
	{
		DWORD exitCode = STILL_ACTIVE;
		HANDLE process = ProcessPipeHandle(pipe->process_handle);
		if (GetExitCodeProcess(process, &exitCode) && exitCode == STILL_ACTIVE)
		{
			TerminateProcess(process, ERROR_CANCELLED);
			WaitForSingleObject(process, 1000);
		}
	}
	CloseProcessPipeHandles(pipe);
	delete pipe;
}

static std::string ReadProcessPipe(ProcessPipe* pipe, size_t size)
{
	if (!pipe || !pipe->stdout_read_handle || size == 0)
		return std::string();

	std::string buffer;
	buffer.reserve(size);

	std::vector<char> chunk(std::min<size_t>(size, 65536));
	size_t remaining = size;

	while (remaining > 0)
	{
		DWORD readSize = 0;
		DWORD requestSize = static_cast<DWORD>(std::min<size_t>(remaining, chunk.size()));
		if (!ReadFile(ProcessPipeHandle(pipe->stdout_read_handle), chunk.data(), requestSize, &readSize, nullptr) || readSize == 0)
			break;

		buffer.append(chunk.data(), chunk.data() + readSize);
		remaining -= readSize;
	}

	return buffer;
}

static size_t GetProcessPipeAvailable(ProcessPipe* pipe)
{
	if (!pipe || !pipe->stdout_read_handle)
		return 0;

	DWORD availableBytes = 0;
	if (!PeekNamedPipe(ProcessPipeHandle(pipe->stdout_read_handle), nullptr, 0, nullptr, &availableBytes, nullptr))
		return 0;

	return static_cast<size_t>(availableBytes);
}

static int WaitProcessPipe(ProcessPipe* pipe, unsigned int timeout)
{
	if (!pipe || !pipe->process_handle)
		return -1;

	DWORD waitResult = WaitForSingleObject(ProcessPipeHandle(pipe->process_handle), timeout);
	if (waitResult != WAIT_OBJECT_0)
		return -1;

	DWORD exitCode = 0;
	if (!GetExitCodeProcess(ProcessPipeHandle(pipe->process_handle), &exitCode))
		return -1;

	return static_cast<int>(exitCode);
}

void init_util_module(lua_State* L)
{
	luabridge::getGlobalNamespace(L)
		.beginNamespace("Engine")
			.beginNamespace("Util")
				// usertype
				.beginClass<CString>("CString")
					.addFunction("get", +[](const CString* str) { return str->val; })
					.addFunction("raw", +[](const CString* str) { return (void*)str->val.data(); })
					.addFunction("set", +[](CString* str, const std::string& val) { str->val = val; })
					.addFunction("empty", +[](CString* str) { return str->val.empty(); })
					.addFunction("__len", +[](const CString* str) { return str->val.size(); })
					.addFunction("__tostring", +[](const CString* str) { return str->val; })
					.addConstructor(+[](void* ptr, const char* str) { return new (ptr) CString(str ? str : ""); },
						+[](void* ptr, const char c, size_t num) { return new (ptr) CString(c, num); },
						+[](void* ptr) { return new (ptr) CString(); })
				.endClass()
				.beginClass<PathList>("PathList")
					.addProperty("capacity", +[](const PathList& file_path_list) { return file_path_list.list.capacity(); })
					.addProperty("count", +[](const PathList& file_path_list) { return file_path_list.list.size(); })
					.addFunction("get", +[](const PathList& file_path_list, unsigned int i) -> const char*
						{
							if (i >= file_path_list.list.size())
								return nullptr;
							return file_path_list.list[i].c_str();
						})
				.endClass()
				.beginClass<ProcessResult>("ProcessResult")
					.addProperty("success", &ProcessResult::success, &ProcessResult::success)
					.addProperty("exit_code", &ProcessResult::exit_code, &ProcessResult::exit_code)
					.addProperty("stdout", &ProcessResult::stdout_content, &ProcessResult::stdout_content)
					.addProperty("stderr", &ProcessResult::stderr_content, &ProcessResult::stderr_content)
					.addProperty("message", &ProcessResult::message, &ProcessResult::message)
					.addConstructor<void()>()
				.endClass()
				.beginClass<ProcessPipe>("ProcessPipe")
					.addProperty("open", +[](const ProcessPipe& pipe) { return pipe.is_open; })
					.addFunction("available", +[](ProcessPipe* pipe) { return GetProcessPipeAvailable(pipe); })
					.addFunction("read", +[](ProcessPipe* pipe, size_t size) { return ReadProcessPipe(pipe, size); })
					.addFunction("wait", +[](ProcessPipe* pipe, unsigned int timeout) { return WaitProcessPipe(pipe, timeout); })
					.addFunction("close", +[](ProcessPipe* pipe) { CloseProcessPipeHandles(pipe); })
				.endClass()
				// function
				.addFunction("Memcpy", +[](void* dst, void* src, size_t size) { memcpy(dst, src, size); })
				.addFunction("UTF8Len", Util_UTF8Len)
				.addFunction("UTF8Sub", Util_UTF8Sub)
				.addFunction("GBKToUTF8", Util_GBKToUTF8)
				.addFunction("UTF8ToGBK", Util_UTF8ToGBK)
				.addFunction("UTF8ToUTF16", Util_UTF8ToUTF16)
				.addFunction("NewGuidString", Util_NewGuidString)
				.addFunction("IsGuidString", Util_IsGuidString)
				.addFunction("NormalizeGuidString", Util_NormalizeGuidString)
				.addFunction("ReadAllTextUtf8", Util_ReadAllTextUtf8)
				.addFunction("ReadAllBytesUtf8", Util_ReadAllBytesUtf8)
				.addFunction("WriteAllTextUtf8", Util_WriteAllTextUtf8)
				.addFunction("WriteAllBytesUtf8", Util_WriteAllBytesUtf8)
				.addFunction("FileExistsUtf8", Util_FileExistsUtf8)
				.addFunction("DirectoryExistsUtf8", Util_DirectoryExistsUtf8)
				.addFunction("CreateDirectoriesUtf8", Util_CreateDirectoriesUtf8)
				.addFunction("RemoveFileUtf8", Util_RemoveFileUtf8)
				.addFunction("RemoveDirectoryUtf8", Util_RemoveDirectoryUtf8)
				.addFunction("RenameUtf8", Util_RenameUtf8)
				.addFunction("CopyFileUtf8", Util_CopyFileUtf8)
				.addFunction("CopyDirectoryUtf8", Util_CopyDirectoryUtf8)
				.addFunction("ListDirectoryUtf8", Util_ListDirectoryUtf8)
				.addFunction("GetFileSizeUtf8", Util_GetFileSizeUtf8)
				.addFunction("GetFileModifiedTimeUtf8", Util_GetFileModifiedTimeUtf8)
				.addFunction("SetFileHiddenUtf8", Util_SetFileHiddenUtf8)
				.addFunction("RunProcessUtf8", Util_RunProcessUtf8)
				.addFunction("RunProcessAndCaptureUtf8", Util_RunProcessAndCaptureUtf8)
				.addFunction("StartProcessUtf8", Util_StartProcessUtf8)
				.addFunction("OpenPathOrUrlUtf8", Util_OpenPathOrUrlUtf8)
				.addFunction("UnloadProcessPipe", +[](ProcessPipe* pipe) { CloseAndDestroyProcessPipe(pipe); })
				.addFunction("SetConsoleShown", +[](bool flag)
					{
						ShowWindow(GetConsoleWindow(), flag ? SW_SHOW : SW_HIDE);
					})
				.addFunction("LoadFileBuffer", +[](const char* path) -> CString*
					{
						if (!path)
							return nullptr;
						std::string utf8Path = path;
						int wideLen = MultiByteToWideChar(CP_UTF8, 0, utf8Path.c_str(), -1, nullptr, 0);
						if (wideLen <= 0)
							return nullptr;
						std::wstring widePath(wideLen, 0);
						if (MultiByteToWideChar(CP_UTF8, 0, utf8Path.c_str(), -1, &widePath[0], wideLen) <= 0)
							return nullptr;
						std::ifstream file(widePath, std::ios::binary);
						if (!file.good()) return nullptr;
						CString* buffer = new CString();
						std::stringstream ss; ss << file.rdbuf();
						buffer->val = ss.str();
						file.close();
						return buffer;
					})
				.addFunction("UnloadFileBuffer", +[](CString* buffer)
					{
						delete buffer;
					})
				.addFunction("LoadDirectory", +[](const char* path_dir, luabridge::LuaRef recursive, luabridge::LuaRef files_only)
					{
						PathList result;
						try 
						{
							if (recursive) 
							{
								for (const auto& entry : std::filesystem::recursive_directory_iterator(Utf8ToWide(path_dir),
									std::filesystem::directory_options::skip_permission_denied)) 
								{
									if (!files_only || entry.is_regular_file())
										result.list.push_back(entry.path().u8string());
								}
							}
							else 
							{
								for (const auto& entry : std::filesystem::directory_iterator(Utf8ToWide(path_dir),
									std::filesystem::directory_options::skip_permission_denied)) 
								{
									if (!files_only || entry.is_regular_file())
										result.list.push_back(entry.path().u8string());
								}
							}
						}
						catch (const std::filesystem::filesystem_error&) { }
						return result;
					})
				.addFunction("ShellExecute", Util_ShellExecute)
				.addFunction("GetExeFilePath", +[]() 
					{
						wchar_t filename[MAX_PATH];
						if (GetModuleFileName(NULL, filename, MAX_PATH) > 0) 
							return WideToUtf8(filename);
						return std::string();
					})
			.endNamespace()
		.endNamespace();
}
