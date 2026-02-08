#include "module_util.h"
#include "module_util_ext.h"

#include <LuaBridge.h>

#include <vector>
#include <codecvt>
#include <fstream>
#include <sstream>
#include <filesystem>

#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

static std::wstring_convert<std::codecvt_utf8<wchar_t>, wchar_t> convert;

struct PathList
{
	std::vector<std::string> list;
};

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
					.addConstructor(+[](void* ptr, const char* str) { return new (ptr) CString(str); }, 
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
				// function
				.addFunction("Memcpy", +[](void* dst, void* src, size_t size) { memcpy(dst, src, size); })
				.addFunction("UTF8Len", +[](const char* str)
					{
						return convert.from_bytes(str).size();
					})
				.addFunction("UTF8Sub", +[](const char* str, int offset, int count) 
					{
						std::wstring wstr = convert.from_bytes(str);
						return convert.to_bytes(wstr.substr(offset, count));
					})
				.addFunction("GBKToUTF8", Util_GBKToUTF8)
				.addFunction("UTF8ToGBK", Util_UTF8ToGBK)
				.addFunction("UTF8ToUTF16", Util_UTF8ToUTF16)
				.addFunction("SetConsoleShown", +[](bool flag)
					{
						ShowWindow(GetConsoleWindow(), flag ? SW_SHOW : SW_HIDE);
					})
				.addFunction("LoadFileBuffer", +[](const char* path) -> CString*
					{
						std::string utf8Path = path;
						int wideLen = MultiByteToWideChar(CP_UTF8, 0, utf8Path.c_str(), -1, nullptr, 0);
						std::wstring widePath(wideLen, 0);
						MultiByteToWideChar(CP_UTF8, 0, utf8Path.c_str(), -1, &widePath[0], wideLen);
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
								for (const auto& entry : std::filesystem::recursive_directory_iterator(convert.from_bytes(path_dir),
									std::filesystem::directory_options::skip_permission_denied)) 
								{
									if (!files_only || entry.is_regular_file())
										result.list.push_back(entry.path().u8string());
								}
							}
							else 
							{
								for (const auto& entry : std::filesystem::directory_iterator(convert.from_bytes(path_dir),
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
							return convert.to_bytes(filename);
						return std::string();
					})
			.endNamespace()
		.endNamespace();
}