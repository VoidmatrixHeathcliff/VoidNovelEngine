#pragma once

#include <lua.hpp>

#include <string>

class EncodingConversion
{
public:
	EncodingConversion() = delete;
	EncodingConversion(const EncodingConversion&) = delete;
	EncodingConversion(EncodingConversion&&) = delete;
	~EncodingConversion() = delete;
	EncodingConversion& operator=(const EncodingConversion&) = delete;
	EncodingConversion& operator=(EncodingConversion&&) = delete;

	static std::string    ToString(const std::wstring& wstr);
	static std::wstring   ToWString(const std::string& str);
	static std::string    GBKToUTF8(const std::string& str);
	static std::string    UTF8ToGBK(const std::string& str);
	static std::u16string UTF8toUTF16(const std::string& str);
	static std::u32string UTF8toUTF32(const std::string& str);
	static std::string    UTF16toUTF8(const std::u16string& str);
	static std::u32string UTF16toUTF32(const std::u16string& str);
	static std::string    UTF32toUTF8(const std::u32string& str);
	static std::u16string UTF32toUTF16(const std::u32string& str);
private:
	static std::string    ToGBK(const std::wstring& wstr);
	static std::wstring   FromGBK(const std::string& str);
	static std::string    ToUTF8(const std::wstring& wstr);
	static std::wstring   FromUTF8(const std::string& str);
private:
	static const char* GBK_LOCALE_NAME;
};

int Util_ShellExecute(lua_State* pLuaVM);

int Util_GBKToUTF8(lua_State* pLuaVM);

int Util_UTF8ToGBK(lua_State* pLuaVM); 

int Util_UTF8ToUTF16(lua_State* pLuaVM);