#pragma once

#include <string>

#ifndef NOMINMAX
#define NOMINMAX
#endif
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

namespace vne::video
{
	std::wstring Utf8ToWide(const std::string& value);
	std::string WideToUtf8(const std::wstring& value);
	std::wstring BuildFileUrlFromUtf8Path(const std::string& utf8Path);
	std::string HrToUtf8String(HRESULT hr);
}
