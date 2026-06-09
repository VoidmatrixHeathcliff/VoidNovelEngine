#include "module_util_ext.h"
#include "module_util.h"

#include <cJSON.h>
#include <base64.h>
#include <LuaBridge.h>

#include <ctime>
#include <chrono>
#include <thread>
#include <string>
#include <vector>
#include <memory>
#include <algorithm>
#include <iomanip>
#include <sstream>
#include <fstream>
#include <filesystem>
#include <system_error>
#include <stdexcept>
#include <corecrt_io.h>
#include <cctype>

#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <objbase.h>
#include <shellapi.h>

#if defined(_WIN64)
#include <guid.hpp>
#endif

namespace
{
	std::string WindowsErrorMessage(DWORD errorCode);

	std::string BuildErrorMessage(const char* action, const std::string& detail = std::string())
	{
		std::string message = action && action[0] != '\0'
			? std::string(action)
			: std::string("操作失败");
		if (!detail.empty())
			message += ": " + detail;
		return message;
	}

	void SetErrorOrThrow(std::string* error, const std::string& message)
	{
		if (error)
		{
			*error = message;
			return;
		}
		throw std::runtime_error(message);
	}

	std::string ShellExecuteErrorMessage(HINSTANCE handle)
	{
		switch (reinterpret_cast<intptr_t>(handle))
		{
		case 0:
			return "ShellExecuteW 失败：系统内存或资源不足";
		case ERROR_FILE_NOT_FOUND:
			return "ShellExecuteW 失败：找不到指定文件";
		case ERROR_PATH_NOT_FOUND:
			return "ShellExecuteW 失败：找不到指定路径";
		case ERROR_BAD_FORMAT:
			return "ShellExecuteW 失败：可执行文件格式无效";
		case SE_ERR_ACCESSDENIED:
			return "ShellExecuteW 失败：访问被拒绝";
		case SE_ERR_ASSOCINCOMPLETE:
			return "ShellExecuteW 失败：文件关联信息不完整";
		case SE_ERR_DDEBUSY:
			return "ShellExecuteW 失败：DDE 会话繁忙";
		case SE_ERR_DDEFAIL:
			return "ShellExecuteW 失败：DDE 会话启动失败";
		case SE_ERR_DDETIMEOUT:
			return "ShellExecuteW 失败：DDE 会话超时";
		case SE_ERR_DLLNOTFOUND:
			return "ShellExecuteW 失败：找不到关联 DLL";
		case SE_ERR_NOASSOC:
			return "ShellExecuteW 失败：没有关联的打开程序";
		case SE_ERR_OOM:
			return "ShellExecuteW 失败：系统内存不足";
		case SE_ERR_SHARE:
			return "ShellExecuteW 失败：共享冲突";
		default:
			return BuildErrorMessage("ShellExecuteW 失败", std::string("错误码 ") + std::to_string(reinterpret_cast<intptr_t>(handle)));
		}
	}

	std::wstring Utf8ToWide(const std::string& value, std::string* error = nullptr)
	{
		if (value.empty())
			return std::wstring();

		int wideLength = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
		if (wideLength <= 0)
		{
			SetErrorOrThrow(error, BuildErrorMessage("UTF-8 字符串转换为 UTF-16 失败", WindowsErrorMessage(GetLastError())));
			return std::wstring();
		}

		std::wstring wideValue(wideLength, L'\0');
		if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), wideValue.data(), wideLength) <= 0)
		{
			SetErrorOrThrow(error, BuildErrorMessage("UTF-8 字符串转换为 UTF-16 失败", WindowsErrorMessage(GetLastError())));
			return std::wstring();
		}
		return wideValue;
	}

	std::string WideToUtf8(const std::wstring& value, std::string* error = nullptr)
	{
		if (value.empty())
			return std::string();

		int utf8Length = WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
		if (utf8Length <= 0)
		{
			SetErrorOrThrow(error, BuildErrorMessage("UTF-16 字符串转换为 UTF-8 失败", WindowsErrorMessage(GetLastError())));
			return std::string();
		}

		std::string utf8Value(utf8Length, '\0');
		if (WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()), utf8Value.data(), utf8Length, nullptr, nullptr) <= 0)
		{
			SetErrorOrThrow(error, BuildErrorMessage("UTF-16 字符串转换为 UTF-8 失败", WindowsErrorMessage(GetLastError())));
			return std::string();
		}
		return utf8Value;
	}

	std::wstring BytesToWideCodePage(const std::string& value, UINT codePage, DWORD flags = 0, std::string* error = nullptr)
	{
		if (value.empty())
			return std::wstring();

		int wideLength = MultiByteToWideChar(codePage, flags, value.data(), static_cast<int>(value.size()), nullptr, 0);
		if (wideLength <= 0)
		{
			SetErrorOrThrow(error, BuildErrorMessage("多字节字符串转换为宽字符串失败", WindowsErrorMessage(GetLastError())));
			return std::wstring();
		}

		std::wstring wideValue(wideLength, L'\0');
		if (MultiByteToWideChar(codePage, flags, value.data(), static_cast<int>(value.size()), wideValue.data(), wideLength) <= 0)
		{
			SetErrorOrThrow(error, BuildErrorMessage("多字节字符串转换为宽字符串失败", WindowsErrorMessage(GetLastError())));
			return std::wstring();
		}
		return wideValue;
	}

	std::string WideToBytesCodePage(const std::wstring& value, UINT codePage, DWORD flags = 0, std::string* error = nullptr)
	{
		if (value.empty())
			return std::string();

		int byteLength = WideCharToMultiByte(codePage, flags, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
		if (byteLength <= 0)
		{
			SetErrorOrThrow(error, BuildErrorMessage("宽字符串转换为多字节字符串失败", WindowsErrorMessage(GetLastError())));
			return std::string();
		}

		std::string byteValue(byteLength, '\0');
		if (WideCharToMultiByte(codePage, flags, value.data(), static_cast<int>(value.size()), byteValue.data(), byteLength, nullptr, nullptr) <= 0)
		{
			SetErrorOrThrow(error, BuildErrorMessage("宽字符串转换为多字节字符串失败", WindowsErrorMessage(GetLastError())));
			return std::string();
		}
		return byteValue;
	}

	std::wstring Utf16ToWide(const std::u16string& value)
	{
		std::wstring wideValue;
		wideValue.reserve(value.size());
		for (char16_t codeUnit : value)
			wideValue.push_back(static_cast<wchar_t>(codeUnit));
		return wideValue;
	}

	std::u16string WideToUtf16(const std::wstring& value)
	{
		std::u16string utf16Value;
		utf16Value.reserve(value.size());
		for (wchar_t codeUnit : value)
			utf16Value.push_back(static_cast<char16_t>(codeUnit));
		return utf16Value;
	}

	std::u32string Utf16ToUtf32(const std::u16string& value, std::string* error = nullptr)
	{
		std::u32string result;
		result.reserve(value.size());

		for (size_t index = 0; index < value.size(); ++index)
		{
			char32_t codePoint = value[index];
			if (codePoint >= 0xD800 && codePoint <= 0xDBFF)
			{
				if (index + 1 >= value.size())
				{
					SetErrorOrThrow(error, "UTF-16 字符串包含不完整的代理项对");
					return std::u32string();
				}

				char32_t lowSurrogate = value[index + 1];
				if (lowSurrogate < 0xDC00 || lowSurrogate > 0xDFFF)
				{
					SetErrorOrThrow(error, "UTF-16 字符串包含无效代理项对");
					return std::u32string();
				}

				codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + (lowSurrogate - 0xDC00);
				++index;
			}
			else if (codePoint >= 0xDC00 && codePoint <= 0xDFFF)
			{
				SetErrorOrThrow(error, "UTF-16 字符串包含未配对的低代理项");
				return std::u32string();
			}

			result.push_back(codePoint);
		}

		return result;
	}

	std::u16string Utf32ToUtf16(const std::u32string& value, std::string* error = nullptr)
	{
		std::u16string result;
		result.reserve(value.size());

		for (char32_t codePoint : value)
		{
			if (codePoint <= 0xFFFF)
			{
				if (codePoint >= 0xD800 && codePoint <= 0xDFFF)
				{
					SetErrorOrThrow(error, "UTF-32 字符串包含代理项码点");
					return std::u16string();
				}
				result.push_back(static_cast<char16_t>(codePoint));
				continue;
			}

			if (codePoint > 0x10FFFF)
			{
				SetErrorOrThrow(error, "UTF-32 字符串包含超出 Unicode 范围的码点");
				return std::u16string();
			}

			codePoint -= 0x10000;
			result.push_back(static_cast<char16_t>(0xD800 + ((codePoint >> 10) & 0x3FF)));
			result.push_back(static_cast<char16_t>(0xDC00 + (codePoint & 0x3FF)));
		}

		return result;
	}

	std::string TrimTrailingWhitespace(const std::string& value)
	{
		size_t end = value.find_last_not_of(" \t\r\n");
		if (end == std::string::npos)
			return std::string();
		return value.substr(0, end + 1);
	}

	std::string WindowsErrorMessage(DWORD errorCode)
	{
		LPWSTR buffer = nullptr;
		DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS;
		DWORD length = FormatMessageW(flags, nullptr, errorCode, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
			reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
		if (length == 0 || !buffer)
			return "Windows API 调用失败";

	std::wstring message(buffer, length);
	LocalFree(buffer);
	std::string error;
	std::string utf8Message = WideToUtf8(message, &error);
	return TrimTrailingWhitespace(error.empty() ? utf8Message : std::string("Windows API 调用失败"));
}

	std::string StripUtf8Bom(const std::string& value)
	{
		if (value.size() >= 3 && static_cast<unsigned char>(value[0]) == 0xEF
			&& static_cast<unsigned char>(value[1]) == 0xBB
			&& static_cast<unsigned char>(value[2]) == 0xBF)
		{
			return value.substr(3);
		}
		return value;
	}

	std::string ToLowerAscii(std::string value)
	{
		for (char& ch : value)
			ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
		return value;
	}

	bool NormalizeGuidStringValue(const std::string& text, std::string& normalized)
	{
#if defined(_WIN64)
		xg::Guid guid(text);
		if (!guid.isValid())
			return false;
		normalized = ToLowerAscii(guid.str());
		return true;
#else
		std::string error;
		std::wstring wideText = Utf8ToWide(text, &error);
		if (!error.empty() || wideText.empty())
			return false;

		if (wideText.front() != L'{')
			wideText = L"{" + wideText + L"}";

		GUID guid{};
		if (CLSIDFromString(wideText.c_str(), &guid) != NOERROR)
			return false;

		wchar_t buffer[64] = {};
		if (StringFromGUID2(guid, buffer, 64) == 0)
			return false;

		std::wstring result(buffer);
		if (result.size() >= 2 && result.front() == L'{' && result.back() == L'}')
			result = result.substr(1, result.size() - 2);

		normalized = ToLowerAscii(WideToUtf8(result));
		return true;
#endif
	}

	std::string NewGuidStringValue()
	{
#if defined(_WIN64)
		return ToLowerAscii(xg::newGuid().str());
#else
		GUID guid{};
		if (CoCreateGuid(&guid) != S_OK)
			return std::string();

		wchar_t buffer[64] = {};
		if (StringFromGUID2(guid, buffer, 64) == 0)
			return std::string();

		std::wstring result(buffer);
		if (result.size() >= 2 && result.front() == L'{' && result.back() == L'}')
			result = result.substr(1, result.size() - 2);

		return ToLowerAscii(WideToUtf8(result));
#endif
	}

	bool GetFileSizeValue(const std::string& pathUtf8, std::uintmax_t& size, std::string& error)
	{
		std::filesystem::path path(Utf8ToWide(pathUtf8, &error));
		if (!error.empty())
			return false;

		std::error_code ec;
		if (!std::filesystem::is_regular_file(path, ec))
		{
			error = ec ? ec.message() : "文件不存在";
			return false;
		}

		size = std::filesystem::file_size(path, ec);
		if (ec)
		{
			error = ec.message();
			return false;
		}

		return true;
	}

	bool GetFileModifiedTimeValue(const std::string& pathUtf8, std::int64_t& timestamp, std::string& error)
	{
		std::wstring widePath = Utf8ToWide(pathUtf8, &error);
		if (!error.empty())
			return false;

		std::filesystem::path path(widePath);
		if (!error.empty())
			return false;

		std::error_code ec;
		if (!std::filesystem::is_regular_file(path, ec))
		{
			error = ec ? ec.message() : "文件不存在";
			return false;
		}

		WIN32_FILE_ATTRIBUTE_DATA attributeData{};
		if (!GetFileAttributesExW(widePath.c_str(), GetFileExInfoStandard, &attributeData))
		{
			error = WindowsErrorMessage(GetLastError());
			return false;
		}

		ULARGE_INTEGER fileTimeValue{};
		fileTimeValue.LowPart = attributeData.ftLastWriteTime.dwLowDateTime;
		fileTimeValue.HighPart = attributeData.ftLastWriteTime.dwHighDateTime;

		constexpr std::uint64_t WINDOWS_TICK_PER_SECOND = 10000000ULL;
		constexpr std::uint64_t WINDOWS_EPOCH_TO_UNIX_SECONDS = 11644473600ULL;

		std::uint64_t totalSeconds = fileTimeValue.QuadPart / WINDOWS_TICK_PER_SECOND;
		if (totalSeconds < WINDOWS_EPOCH_TO_UNIX_SECONDS)
		{
			timestamp = 0;
			return true;
		}

		timestamp = static_cast<std::int64_t>(totalSeconds - WINDOWS_EPOCH_TO_UNIX_SECONDS);
		return true;
	}

	bool EnsureParentDirectory(const std::filesystem::path& path, std::string& error)
	{
		std::error_code ec;
		std::filesystem::path parent = path.parent_path();
		if (parent.empty())
			return true;

		if (std::filesystem::exists(parent, ec))
		{
			if (ec)
			{
				error = ec.message();
				return false;
			}
			return true;
		}

		std::filesystem::create_directories(parent, ec);
		if (ec)
		{
			error = ec.message();
			return false;
		}
		return true;
	}

	bool ReadFileBytesUtf8(const std::string& pathUtf8, std::string& content, std::string& error)
	{
		std::string convertError;
		std::filesystem::path path(Utf8ToWide(pathUtf8, &convertError));
		if (!convertError.empty())
		{
			error = convertError;
			return false;
		}

		std::ifstream file(path, std::ios::binary);
		if (!file.is_open())
		{
			error = "无法打开文件";
			return false;
		}

		std::ostringstream stream;
		stream << file.rdbuf();
		if (!file.good() && !file.eof())
		{
			error = "读取文件失败";
			return false;
		}

		content = stream.str();
		return true;
	}

	bool WriteFileBytesUtf8(const std::string& pathUtf8, const std::string& content, std::string& error)
	{
		std::string convertError;
		std::filesystem::path path(Utf8ToWide(pathUtf8, &convertError));
		if (!convertError.empty())
		{
			error = convertError;
			return false;
		}
		if (!EnsureParentDirectory(path, error))
			return false;

		std::ofstream file(path, std::ios::binary | std::ios::trunc);
		if (!file.is_open())
		{
			error = "无法打开文件";
			return false;
		}

		file.write(content.data(), static_cast<std::streamsize>(content.size()));
		if (!file.good())
		{
			error = "写入文件失败";
			return false;
		}
		return true;
	}

	std::wstring QuoteCommandArg(const std::wstring& value)
	{
		if (value.empty())
			return L"\"\"";

		if (value.find_first_of(L" \t\n\v\"") == std::wstring::npos)
			return value;

		std::wstring quoted = L"\"";
		size_t slashCount = 0;
		for (wchar_t ch : value)
		{
			if (ch == L'\\')
			{
				++slashCount;
				continue;
			}

			if (ch == L'"')
			{
				quoted.append(slashCount * 2 + 1, L'\\');
				quoted.push_back(L'"');
				slashCount = 0;
				continue;
			}

			if (slashCount > 0)
			{
				quoted.append(slashCount, L'\\');
				slashCount = 0;
			}
			quoted.push_back(ch);
		}
		if (slashCount > 0)
			quoted.append(slashCount * 2, L'\\');
		quoted.push_back(L'"');
		return quoted;
	}

	bool ReadLuaStringArray(lua_State* luaVM, int index, std::vector<std::string>& result, std::string& error)
	{
		if (lua_isnoneornil(luaVM, index))
			return true;

		if (!lua_istable(luaVM, index))
		{
			error = "参数必须是字符串数组";
			return false;
		}

		size_t length = lua_rawlen(luaVM, index);
		for (size_t i = 1; i <= length; ++i)
		{
			lua_rawgeti(luaVM, index, static_cast<lua_Integer>(i));
			if (!lua_isstring(luaVM, -1))
			{
				lua_pop(luaVM, 1);
				error = "参数数组中存在非字符串元素";
				return false;
			}

			size_t strLength = 0;
			const char* str = lua_tolstring(luaVM, -1, &strLength);
			result.emplace_back(str, strLength);
			lua_pop(luaVM, 1);
		}

		return true;
	}

	std::wstring BuildCommandLine(const std::wstring& exePath, const std::vector<std::wstring>& args)
	{
		std::wstring commandLine = QuoteCommandArg(exePath);
		for (const auto& arg : args)
		{
			commandLine.push_back(L' ');
			commandLine += QuoteCommandArg(arg);
		}
		return commandLine;
	}

	bool CreatePipePair(HANDLE& readPipe, HANDLE& writePipe, std::string& error)
	{
		SECURITY_ATTRIBUTES securityAttributes{};
		securityAttributes.nLength = sizeof(securityAttributes);
		securityAttributes.bInheritHandle = TRUE;

		if (!CreatePipe(&readPipe, &writePipe, &securityAttributes, 0))
		{
			error = WindowsErrorMessage(GetLastError());
			return false;
		}
		if (!SetHandleInformation(readPipe, HANDLE_FLAG_INHERIT, 0))
		{
			error = WindowsErrorMessage(GetLastError());
			CloseHandle(readPipe);
			CloseHandle(writePipe);
			readPipe = nullptr;
			writePipe = nullptr;
			return false;
		}
		return true;
	}

	void CloseHandleIfValid(HANDLE& handle)
	{
		if (handle)
		{
			CloseHandle(handle);
			handle = nullptr;
		}
	}

	std::string ReadHandleToString(HANDLE handle)
	{
		std::string output;
		std::vector<char> buffer(8192);

		while (true)
		{
			DWORD bytesRead = 0;
			if (!ReadFile(handle, buffer.data(), static_cast<DWORD>(buffer.size()), &bytesRead, nullptr) || bytesRead == 0)
				break;
			output.append(buffer.data(), buffer.data() + bytesRead);
		}

		return output;
	}

	ProcessResult MakeProcessFailure(const std::string& message)
	{
		ProcessResult result;
		result.success = false;
		result.exit_code = -1;
		result.message = message;
		return result;
	}

	ProcessResult RunProcessCaptureUtf8(const std::string& exePathUtf8, const std::vector<std::string>& argsUtf8, const std::string& cwdUtf8)
	{
		std::string error;
		std::wstring exePath = Utf8ToWide(exePathUtf8, &error);
		if (!error.empty())
			return MakeProcessFailure(error);

		std::wstring cwdPath = Utf8ToWide(cwdUtf8, &error);
		if (!cwdUtf8.empty() && !error.empty())
			return MakeProcessFailure(error);

		std::vector<std::wstring> argsWide;
		argsWide.reserve(argsUtf8.size());
		for (const auto& argUtf8 : argsUtf8)
		{
			std::wstring argWide = Utf8ToWide(argUtf8, &error);
			if (!error.empty())
				return MakeProcessFailure(error);
			argsWide.push_back(argWide);
		}

		HANDLE readPipe = nullptr;
		HANDLE writePipe = nullptr;
		if (!CreatePipePair(readPipe, writePipe, error))
			return MakeProcessFailure(error);

		STARTUPINFOW startupInfo{};
		startupInfo.cb = sizeof(startupInfo);
		startupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
		startupInfo.wShowWindow = SW_HIDE;
		startupInfo.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
		startupInfo.hStdOutput = writePipe;
		startupInfo.hStdError = writePipe;

		PROCESS_INFORMATION processInfo{};
		std::wstring commandLine = BuildCommandLine(exePath, argsWide);
		std::vector<wchar_t> commandLineBuffer(commandLine.begin(), commandLine.end());
		commandLineBuffer.push_back(L'\0');

		BOOL created = CreateProcessW(exePath.c_str(), commandLineBuffer.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr,
			cwdUtf8.empty() ? nullptr : cwdPath.c_str(), &startupInfo, &processInfo);

		CloseHandleIfValid(writePipe);
		if (!created)
		{
			error = WindowsErrorMessage(GetLastError());
			CloseHandleIfValid(readPipe);
			return MakeProcessFailure(error);
		}

		std::string output = ReadHandleToString(readPipe);
		CloseHandleIfValid(readPipe);
		WaitForSingleObject(processInfo.hProcess, INFINITE);

		DWORD exitCode = 0;
		GetExitCodeProcess(processInfo.hProcess, &exitCode);
		CloseHandleIfValid(processInfo.hThread);
		CloseHandleIfValid(processInfo.hProcess);

		ProcessResult result;
		result.exit_code = static_cast<int>(exitCode);
		result.success = exitCode == 0;
		result.stdout_content = output;
		result.message = result.success ? "进程执行成功" : "进程返回非零退出码";
		return result;
	}

	bool StartProcessStreamUtf8(const std::string& exePathUtf8, const std::vector<std::string>& argsUtf8, const std::string& cwdUtf8,
		ProcessPipe& pipe, std::string& error)
	{
		std::wstring exePath = Utf8ToWide(exePathUtf8, &error);
		if (!error.empty())
			return false;

		std::wstring cwdPath = Utf8ToWide(cwdUtf8, &error);
		if (!cwdUtf8.empty() && !error.empty())
			return false;

		std::vector<std::wstring> argsWide;
		argsWide.reserve(argsUtf8.size());
		for (const auto& argUtf8 : argsUtf8)
		{
			std::wstring argWide = Utf8ToWide(argUtf8, &error);
			if (!error.empty())
				return false;
			argsWide.push_back(argWide);
		}

		HANDLE stdoutRead = nullptr;
		HANDLE stdoutWrite = nullptr;
		if (!CreatePipePair(stdoutRead, stdoutWrite, error))
			return false;

		STARTUPINFOW startupInfo{};
		startupInfo.cb = sizeof(startupInfo);
		startupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
		startupInfo.wShowWindow = SW_HIDE;
		startupInfo.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
		startupInfo.hStdOutput = stdoutWrite;
		startupInfo.hStdError = stdoutWrite;

		PROCESS_INFORMATION processInfo{};
		std::wstring commandLine = BuildCommandLine(exePath, argsWide);
		std::vector<wchar_t> commandLineBuffer(commandLine.begin(), commandLine.end());
		commandLineBuffer.push_back(L'\0');

		BOOL created = CreateProcessW(exePath.c_str(), commandLineBuffer.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr,
			cwdUtf8.empty() ? nullptr : cwdPath.c_str(), &startupInfo, &processInfo);

		CloseHandleIfValid(stdoutWrite);
		if (!created)
		{
			error = WindowsErrorMessage(GetLastError());
			CloseHandleIfValid(stdoutRead);
			return false;
		}

		pipe.process_handle = processInfo.hProcess;
		pipe.thread_handle = processInfo.hThread;
		pipe.stdout_read_handle = stdoutRead;
		pipe.null_write_handle = nullptr;
		pipe.is_open = true;
		return true;
	}

	int PushBooleanOrError(lua_State* luaVM, bool success, const std::string& error)
	{
		if (success)
		{
			lua_pushboolean(luaVM, 1);
			return 1;
		}

		lua_pushnil(luaVM);
		lua_pushlstring(luaVM, error.data(), error.size());
		return 2;
	}
}



#if defined(_WIN32) || defined(_WIN64)

const char* EncodingConversion::GBK_LOCALE_NAME = ".936";

#else

const char* EncodingConversion::GBK_LOCALE_NAME = "zh_CN.GBK";

#endif



std::string EncodingConversion::ToString(const std::wstring& wstr)
{
	return WideToBytesCodePage(wstr, CP_ACP);
}



std::wstring EncodingConversion::ToWString(const std::string& str)
{
	return BytesToWideCodePage(str, CP_ACP);
}



std::string EncodingConversion::ToGBK(const std::wstring& wstr)
{
	return WideToBytesCodePage(wstr, 936);
}



std::wstring EncodingConversion::FromGBK(const std::string& str)
{
	return BytesToWideCodePage(str, 936);
}



std::string EncodingConversion::ToUTF8(const std::wstring& wstr)
{
	return WideToUtf8(wstr);
}



std::wstring EncodingConversion::FromUTF8(const std::string& str)
{
	return Utf8ToWide(str);
}



std::string EncodingConversion::GBKToUTF8(const std::string& str)
{
	return WideToUtf8(FromGBK(str));
}



std::string EncodingConversion::UTF8ToGBK(const std::string& str)
{
	return ToGBK(Utf8ToWide(str));
}



std::u16string EncodingConversion::UTF8toUTF16(const std::string& str)
{
	return WideToUtf16(Utf8ToWide(str));
}



std::u32string EncodingConversion::UTF8toUTF32(const std::string& str)
{
	return Utf16ToUtf32(UTF8toUTF16(str));
}



std::string EncodingConversion::UTF16toUTF8(const std::u16string& str)
{
	return WideToUtf8(Utf16ToWide(str));
}



std::u32string EncodingConversion::UTF16toUTF32(const std::u16string& str)
{
	return Utf16ToUtf32(str);
}



std::string EncodingConversion::UTF32toUTF8(const std::u32string& str)
{
	return UTF16toUTF8(Utf32ToUtf16(str));
}



std::u16string EncodingConversion::UTF32toUTF16(const std::u32string& str)
{
	return Utf32ToUtf16(str);
}



int Util_NewGuidString(lua_State* pLuaVM)
{
	std::string guid = NewGuidStringValue();
	lua_pushlstring(pLuaVM, guid.data(), guid.size());
	return 1;
}

int Util_IsGuidString(lua_State* pLuaVM)
{
	std::string normalized;
	lua_pushboolean(pLuaVM, NormalizeGuidStringValue(luaL_checkstring(pLuaVM, 1), normalized));
	return 1;
}

int Util_NormalizeGuidString(lua_State* pLuaVM)
{
	std::string normalized;
	if (!NormalizeGuidStringValue(luaL_checkstring(pLuaVM, 1), normalized))
	{
		lua_pushnil(pLuaVM);
		return 1;
	}

	lua_pushlstring(pLuaVM, normalized.data(), normalized.size());
	return 1;
}

int Util_ShellExecute(lua_State* pLuaVM)

{
	try
	{
		int argc = lua_gettop(pLuaVM);

		std::wstring operation = Utf8ToWide(luaL_checkstring(pLuaVM, 1));
		std::wstring target = Utf8ToWide(luaL_checkstring(pLuaVM, 2));
		std::wstring parameters = argc > 2 ? Utf8ToWide(luaL_checkstring(pLuaVM, 3)) : std::wstring();
		std::wstring directory = argc > 3 ? Utf8ToWide(luaL_checkstring(pLuaVM, 4)) : std::wstring();

		HINSTANCE handle = ShellExecuteW(nullptr,
			operation.c_str(),
			target.c_str(),
			argc > 2 ? parameters.c_str() : nullptr,
			argc > 3 ? directory.c_str() : nullptr,
			argc > 4 ? (int)luaL_checkinteger(pLuaVM, 5) : SW_SHOWNORMAL);

		bool success = reinterpret_cast<intptr_t>(handle) > 32;
		return PushBooleanOrError(pLuaVM, success, success ? std::string() : ShellExecuteErrorMessage(handle));
	}
	catch (const std::exception& ex)
	{
		return PushBooleanOrError(pLuaVM, false, ex.what());
	}

}



int Util_GBKToUTF8(lua_State* pLuaVM)

{

	try

	{

		lua_pushstring(pLuaVM,

			EncodingConversion::GBKToUTF8(luaL_checkstring(pLuaVM, 1)).c_str());

	}

	catch (const std::exception&)

	{

		lua_pushnil(pLuaVM);

	}



	return 1;

}



int Util_UTF8ToGBK(lua_State* pLuaVM)

{

	try

	{

		lua_pushstring(pLuaVM,

			EncodingConversion::UTF8ToGBK(luaL_checkstring(pLuaVM, 1)).c_str());

	}

	catch (const std::exception&)

	{

		lua_pushnil(pLuaVM);

	}



	return 1;

}



int Util_UTF8ToUTF16(lua_State* pLuaVM)

{

	try

	{
		size_t length = 0;
		const char* content = luaL_checklstring(pLuaVM, 1, &length);
		std::u16string utf16 = EncodingConversion::UTF8toUTF16(std::string(content, length));
		lua_pushlstring(pLuaVM,
			reinterpret_cast<const char*>(utf16.data()),
			static_cast<size_t>(utf16.size()) * sizeof(char16_t));

	}

	catch (const std::exception&)

	{

		lua_pushnil(pLuaVM);

	}



	return 1;

}

int Util_ReadAllTextUtf8(lua_State* pLuaVM)
{
	std::string content;
	std::string error;
	if (!ReadFileBytesUtf8(luaL_checkstring(pLuaVM, 1), content, error))
	{
		lua_pushnil(pLuaVM);
		lua_pushlstring(pLuaVM, error.data(), error.size());
		return 2;
	}

	content = StripUtf8Bom(content);
	lua_pushlstring(pLuaVM, content.data(), content.size());
	return 1;
}

int Util_ReadAllBytesUtf8(lua_State* pLuaVM)
{
	std::string content;
	std::string error;
	if (!ReadFileBytesUtf8(luaL_checkstring(pLuaVM, 1), content, error))
	{
		lua_pushnil(pLuaVM);
		lua_pushlstring(pLuaVM, error.data(), error.size());
		return 2;
	}

	CString* buffer = new CString();
	buffer->val = std::move(content);
	(void)luabridge::Stack<CString*>::push(pLuaVM, buffer);
	return 1;
}

int Util_WriteAllTextUtf8(lua_State* pLuaVM)
{
	size_t length = 0;
	const char* content = luaL_checklstring(pLuaVM, 2, &length);
	std::string error;
	bool success = WriteFileBytesUtf8(luaL_checkstring(pLuaVM, 1), std::string(content, length), error);
	return PushBooleanOrError(pLuaVM, success, error);
}

int Util_WriteAllBytesUtf8(lua_State* pLuaVM)
{
	size_t length = 0;
	const char* content = luaL_checklstring(pLuaVM, 2, &length);
	std::string error;
	bool success = WriteFileBytesUtf8(luaL_checkstring(pLuaVM, 1), std::string(content, length), error);
	return PushBooleanOrError(pLuaVM, success, error);
}

int Util_FileExistsUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path path(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	if (!error.empty())
	{
		lua_pushboolean(pLuaVM, 0);
		return 1;
	}

	std::error_code ec;
	lua_pushboolean(pLuaVM, std::filesystem::is_regular_file(path, ec) && !ec);
	return 1;
}

int Util_DirectoryExistsUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path path(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	if (!error.empty())
	{
		lua_pushboolean(pLuaVM, 0);
		return 1;
	}

	std::error_code ec;
	lua_pushboolean(pLuaVM, std::filesystem::is_directory(path, ec) && !ec);
	return 1;
}

int Util_CreateDirectoriesUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path path(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	std::error_code ec;
	if (!std::filesystem::exists(path, ec))
		std::filesystem::create_directories(path, ec);
	if (ec)
		return PushBooleanOrError(pLuaVM, false, ec.message());

	return PushBooleanOrError(pLuaVM, true, std::string());
}

int Util_RemoveFileUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path path(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	std::error_code ec;
	std::filesystem::remove(path, ec);
	if (ec)
		return PushBooleanOrError(pLuaVM, false, ec.message());

	return PushBooleanOrError(pLuaVM, true, std::string());
}

int Util_RemoveDirectoryUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path path(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	bool recursive = lua_toboolean(pLuaVM, 2) != 0;
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	std::error_code ec;
	if (recursive)
		std::filesystem::remove_all(path, ec);
	else
		std::filesystem::remove(path, ec);
	if (ec)
		return PushBooleanOrError(pLuaVM, false, ec.message());

	return PushBooleanOrError(pLuaVM, true, std::string());
}

int Util_RenameUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path source(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	std::filesystem::path destination(Utf8ToWide(luaL_checkstring(pLuaVM, 2), &error));
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);
	if (!EnsureParentDirectory(destination, error))
		return PushBooleanOrError(pLuaVM, false, error);

	std::error_code ec;
	std::filesystem::rename(source, destination, ec);
	if (ec)
		return PushBooleanOrError(pLuaVM, false, ec.message());

	return PushBooleanOrError(pLuaVM, true, std::string());
}

int Util_CopyFileUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path source(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	std::filesystem::path destination(Utf8ToWide(luaL_checkstring(pLuaVM, 2), &error));
	bool overwrite = lua_toboolean(pLuaVM, 3) != 0;
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);
	if (!EnsureParentDirectory(destination, error))
		return PushBooleanOrError(pLuaVM, false, error);

	std::error_code ec;
	std::filesystem::copy_options options = overwrite
		? std::filesystem::copy_options::overwrite_existing
		: std::filesystem::copy_options::none;
	std::filesystem::copy_file(source, destination, options, ec);
	if (ec)
		return PushBooleanOrError(pLuaVM, false, ec.message());

	return PushBooleanOrError(pLuaVM, true, std::string());
}

int Util_CopyDirectoryUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path source(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	std::filesystem::path destination(Utf8ToWide(luaL_checkstring(pLuaVM, 2), &error));
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	std::error_code ec;
	std::filesystem::create_directories(destination, ec);
	if (ec)
		return PushBooleanOrError(pLuaVM, false, ec.message());

	std::filesystem::copy(source, destination,
		std::filesystem::copy_options::recursive | std::filesystem::copy_options::overwrite_existing, ec);
	if (ec)
		return PushBooleanOrError(pLuaVM, false, ec.message());

	return PushBooleanOrError(pLuaVM, true, std::string());
}

int Util_ListDirectoryUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::filesystem::path path(Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error));
	bool recursive = lua_toboolean(pLuaVM, 2) != 0;
	bool filesOnly = lua_toboolean(pLuaVM, 3) != 0;
	if (!error.empty())
	{
		lua_pushnil(pLuaVM);
		lua_pushlstring(pLuaVM, error.data(), error.size());
		return 2;
	}

	PathList result;
	std::error_code ec;
	if (!std::filesystem::exists(path, ec))
	{
		lua_pushnil(pLuaVM);
		lua_pushstring(pLuaVM, "目录不存在");
		return 2;
	}

	if (recursive)
	{
		for (std::filesystem::recursive_directory_iterator it(path, std::filesystem::directory_options::skip_permission_denied, ec), end;
			it != end && !ec; it.increment(ec))
		{
			if (!filesOnly || it->is_regular_file(ec))
			{
				std::string utf8Path = WideToUtf8(it->path().wstring(), &error);
				if (!error.empty())
				{
					lua_pushnil(pLuaVM);
					lua_pushlstring(pLuaVM, error.data(), error.size());
					return 2;
				}
				result.list.push_back(utf8Path);
			}
		}
	}
	else
	{
		for (std::filesystem::directory_iterator it(path, std::filesystem::directory_options::skip_permission_denied, ec), end;
			it != end && !ec; it.increment(ec))
		{
			if (!filesOnly || it->is_regular_file(ec))
			{
				std::string utf8Path = WideToUtf8(it->path().wstring(), &error);
				if (!error.empty())
				{
					lua_pushnil(pLuaVM);
					lua_pushlstring(pLuaVM, error.data(), error.size());
					return 2;
				}
				result.list.push_back(utf8Path);
			}
		}
	}

	if (ec)
	{
		std::string message = ec.message();
		lua_pushnil(pLuaVM);
		lua_pushlstring(pLuaVM, message.data(), message.size());
		return 2;
	}

	std::sort(result.list.begin(), result.list.end());
	(void)luabridge::Stack<PathList>::push(pLuaVM, result);
	return 1;
}

int Util_GetFileSizeUtf8(lua_State* pLuaVM)
{
	std::uintmax_t size = 0;
	std::string error;
	if (!GetFileSizeValue(luaL_checkstring(pLuaVM, 1), size, error))
	{
		lua_pushnil(pLuaVM);
		lua_pushlstring(pLuaVM, error.data(), error.size());
		return 2;
	}

	lua_pushinteger(pLuaVM, static_cast<lua_Integer>(size));
	return 1;
}

int Util_GetFileModifiedTimeUtf8(lua_State* pLuaVM)
{
	std::int64_t timestamp = 0;
	std::string error;
	if (!GetFileModifiedTimeValue(luaL_checkstring(pLuaVM, 1), timestamp, error))
	{
		lua_pushnil(pLuaVM);
		lua_pushlstring(pLuaVM, error.data(), error.size());
		return 2;
	}

	lua_pushinteger(pLuaVM, static_cast<lua_Integer>(timestamp));
	return 1;
}

int Util_SetFileHiddenUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::wstring widePath = Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error);
	bool hidden = lua_toboolean(pLuaVM, 2) != 0;
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	DWORD attributes = GetFileAttributesW(widePath.c_str());
	if (attributes == INVALID_FILE_ATTRIBUTES)
		return PushBooleanOrError(pLuaVM, false, WindowsErrorMessage(GetLastError()));

	bool isHidden = (attributes & FILE_ATTRIBUTE_HIDDEN) != 0;
	if (isHidden == hidden)
		return PushBooleanOrError(pLuaVM, true, std::string());

	if (hidden)
		attributes |= FILE_ATTRIBUTE_HIDDEN;
	else
		attributes &= ~FILE_ATTRIBUTE_HIDDEN;

	if (!SetFileAttributesW(widePath.c_str(), attributes))
		return PushBooleanOrError(pLuaVM, false, WindowsErrorMessage(GetLastError()));

	return PushBooleanOrError(pLuaVM, true, std::string());
}

int Util_RunProcessUtf8(lua_State* pLuaVM)
{
	std::vector<std::string> args;
	std::string error;
	if (!ReadLuaStringArray(pLuaVM, 2, args, error))
	{
		ProcessResult result = MakeProcessFailure(error);
		(void)luabridge::Stack<ProcessResult>::push(pLuaVM, result);
		return 1;
	}

	std::string cwd;
	if (!lua_isnoneornil(pLuaVM, 3))
		cwd = luaL_checkstring(pLuaVM, 3);

	ProcessResult result = RunProcessCaptureUtf8(luaL_checkstring(pLuaVM, 1), args, cwd);
	(void)luabridge::Stack<ProcessResult>::push(pLuaVM, result);
	return 1;
}

int Util_RunProcessAndCaptureUtf8(lua_State* pLuaVM)
{
	return Util_RunProcessUtf8(pLuaVM);
}

int Util_StartProcessUtf8(lua_State* pLuaVM)
{
	std::vector<std::string> args;
	std::string error;
	if (!ReadLuaStringArray(pLuaVM, 2, args, error))
	{
		lua_pushnil(pLuaVM);
		lua_pushlstring(pLuaVM, error.data(), error.size());
		return 2;
	}

	std::string cwd;
	if (!lua_isnoneornil(pLuaVM, 3))
		cwd = luaL_checkstring(pLuaVM, 3);

	ProcessPipe* pipe = new ProcessPipe();
	if (!StartProcessStreamUtf8(luaL_checkstring(pLuaVM, 1), args, cwd, *pipe, error))
	{
		delete pipe;
		lua_pushnil(pLuaVM);
		lua_pushlstring(pLuaVM, error.data(), error.size());
		return 2;
	}

	(void)luabridge::Stack<ProcessPipe*>::push(pLuaVM, pipe);
	return 1;
}

int Util_OpenPathOrUrlUtf8(lua_State* pLuaVM)
{
	std::string error;
	std::wstring target = Utf8ToWide(luaL_checkstring(pLuaVM, 1), &error);
	if (!error.empty())
		return PushBooleanOrError(pLuaVM, false, error);

	HINSTANCE handle = ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
	bool success = reinterpret_cast<intptr_t>(handle) > 32;
	return PushBooleanOrError(pLuaVM, success, success ? std::string() : ShellExecuteErrorMessage(handle));
}
