#include "video_common.h"

#include <filesystem>
#include <sstream>
#include <vector>

#include <Shlwapi.h>

namespace vne::video
{
	std::wstring Utf8ToWide(const std::string& value)
	{
		if (value.empty())
			return std::wstring();

		int wideLength = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
		if (wideLength <= 0)
			return std::wstring();

		std::wstring wide(static_cast<size_t>(wideLength - 1), L'\0');
		MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, wide.data(), wideLength);
		return wide;
	}

	std::string WideToUtf8(const std::wstring& value)
	{
		if (value.empty())
			return std::string();

		int utf8Length = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
		if (utf8Length <= 0)
			return std::string();

		std::string utf8(static_cast<size_t>(utf8Length - 1), '\0');
		WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, utf8.data(), utf8Length, nullptr, nullptr);
		return utf8;
	}

	std::wstring BuildFileUrlFromUtf8Path(const std::string& utf8Path)
	{
		if (utf8Path.empty())
			return std::wstring();

		std::filesystem::path absolutePath = std::filesystem::absolute(std::filesystem::path(Utf8ToWide(utf8Path))).lexically_normal();
		std::wstring widePath = absolutePath.native();

		DWORD urlLength = 0;
		HRESULT hr = UrlCreateFromPathW(widePath.c_str(), nullptr, &urlLength, 0);
		if (hr == E_POINTER && urlLength > 0)
		{
			std::vector<wchar_t> buffer(static_cast<size_t>(urlLength), L'\0');
			hr = UrlCreateFromPathW(widePath.c_str(), buffer.data(), &urlLength, 0);
			if (SUCCEEDED(hr))
				return std::wstring(buffer.data());
		}

		for (wchar_t& ch : widePath)
		{
			if (ch == L'\\')
				ch = L'/';
		}

		if (widePath.size() >= 2 && widePath[1] == L':')
			return L"file:///" + widePath;
		return L"file://" + widePath;
	}

	std::string HrToUtf8String(HRESULT hr)
	{
		wchar_t* wideMessage = nullptr;
		DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS;
		DWORD length = FormatMessageW(flags, nullptr, static_cast<DWORD>(hr), 0, reinterpret_cast<LPWSTR>(&wideMessage), 0, nullptr);
		if (length > 0 && wideMessage != nullptr)
		{
			std::wstring message(wideMessage, length);
			LocalFree(wideMessage);
			while (!message.empty() && (message.back() == L'\r' || message.back() == L'\n' || message.back() == L' '))
				message.pop_back();
			return WideToUtf8(message);
		}

		std::ostringstream oss;
		oss << "HRESULT 0x" << std::hex << std::uppercase << static_cast<unsigned long>(hr);
		return oss.str();
	}
}
