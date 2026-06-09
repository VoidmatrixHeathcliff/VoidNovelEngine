#include "module_imgui_text_editor.h"

#include <LuaBridge.h>
#include <imgui.h>
#include "TextEditor.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <memory>
#include <string>

namespace
{
	struct LuaTextEditorHandle
	{
		std::shared_ptr<TextEditor> editor;
		bool lastFocused = false;
		std::string languageId = "lua";

		LuaTextEditorHandle()
			: editor(std::make_shared<TextEditor>())
		{
			editor->SetLanguageDefinition(TextEditor::LanguageDefinition::Lua());
			editor->SetPalette(TextEditor::GetDarkPalette());
			editor->SetShowWhitespaces(false);
		}

		bool IsValid() const
		{
			return editor != nullptr;
		}

		void Destroy()
		{
			editor.reset();
			lastFocused = false;
			languageId = "lua";
		}
	};

	static TextEditor* GetEditor(LuaTextEditorHandle& handle)
	{
		return handle.editor.get();
	}

	static std::string NormalizeLanguageId(const std::string& languageId)
	{
		std::string normalized = languageId;
		std::transform(
			normalized.begin(),
			normalized.end(),
			normalized.begin(),
			[](unsigned char ch)
			{
				return static_cast<char>(std::tolower(ch));
			});
		if (normalized.empty())
			return "lua";
		return normalized;
	}

	static bool IsAsciiWhitespace(char ch)
	{
		return std::isspace(static_cast<unsigned char>(ch)) != 0;
	}

	static bool IsIdentifierStart(char ch)
	{
		const unsigned char value = static_cast<unsigned char>(ch);
		return std::isalpha(value) != 0 || ch == '_';
	}

	static bool IsIdentifierPart(char ch)
	{
		const unsigned char value = static_cast<unsigned char>(ch);
		return std::isalnum(value) != 0 || ch == '_';
	}

	static bool IsLabelIdentifierStart(char ch)
	{
		return IsIdentifierStart(ch) || static_cast<unsigned char>(ch) >= 0x80;
	}

	static bool IsLabelIdentifierPart(char ch)
	{
		return IsIdentifierPart(ch) || static_cast<unsigned char>(ch) >= 0x80;
	}

	static bool IsHexDigit(char ch)
	{
		return std::isxdigit(static_cast<unsigned char>(ch)) != 0;
	}

	static const char* FindFirstNonSpace(const char* lineBegin, const char* lineEnd)
	{
		auto cursor = lineBegin;
		while (cursor < lineEnd && IsAsciiWhitespace(*cursor))
			++cursor;
		return cursor;
	}

	static const char* FindPrevNonSpace(const char* lineBegin, const char* position)
	{
		if (position <= lineBegin)
			return nullptr;

		auto cursor = position;
		while (cursor > lineBegin)
		{
			--cursor;
			if (!IsAsciiWhitespace(*cursor))
				return cursor;
		}
		return nullptr;
	}

	static bool IsAtFirstNonSpace(const char* lineBegin, const char* position)
	{
		return FindFirstNonSpace(lineBegin, position) == position;
	}

	static const char* ScanIdentifier(const char* cursor, const char* end)
	{
		if (cursor >= end || !IsIdentifierStart(*cursor))
			return cursor;

		++cursor;
		while (cursor < end && IsIdentifierPart(*cursor))
			++cursor;
		return cursor;
	}

	static const char* ScanIdentifierOrDotted(const char* cursor, const char* end)
	{
		cursor = ScanIdentifier(cursor, end);
		while (cursor < end && *cursor == '.')
		{
			const auto next = ScanIdentifier(cursor + 1, end);
			if (next == cursor + 1)
				break;
			cursor = next;
		}
		return cursor;
	}

	static const char* ScanLabelIdentifier(const char* cursor, const char* end)
	{
		if (cursor >= end || !IsLabelIdentifierStart(*cursor))
			return cursor;

		++cursor;
		while (cursor < end && IsLabelIdentifierPart(*cursor))
			++cursor;
		return cursor;
	}

	static const char* ScanStringLiteral(const char* cursor, const char* end)
	{
		if (cursor >= end || *cursor != '"')
			return cursor;

		++cursor;
		while (cursor < end)
		{
			if (*cursor == '\\')
			{
				cursor += std::min<std::ptrdiff_t>(2, end - cursor);
				continue;
			}

			if (*cursor == '"')
			{
				++cursor;
				break;
			}

			++cursor;
		}
		return cursor;
	}

	static const char* FindToken(const char* begin, const char* end, const char* token)
	{
		const auto tokenLength = std::strlen(token);
		if (tokenLength == 0)
			return begin;

		for (auto cursor = begin; cursor + tokenLength <= end; ++cursor)
		{
			if (std::memcmp(cursor, token, tokenLength) == 0)
				return cursor;
		}
		return nullptr;
	}

	static bool IsLabelContext(const char* lineBegin, const char* position)
	{
		if (IsAtFirstNonSpace(lineBegin, position))
			return true;

		const auto prev = FindPrevNonSpace(lineBegin, position);
		if (prev == nullptr || *prev != '>')
			return false;

		if (prev == lineBegin)
			return false;
		return *(prev - 1) == '-';
	}

	static bool IsControlKeywordToken(const char* begin, const char* end)
	{
		const auto length = end - begin;
		if (length == 2)
			return std::memcmp(begin, "if", 2) == 0;
		if (length == 3)
			return std::memcmp(begin, "end", 3) == 0;
		if (length == 4)
			return std::memcmp(begin, "elif", 4) == 0
				|| std::memcmp(begin, "else", 4) == 0;
		if (length == 6)
			return std::memcmp(begin, "choice", 6) == 0;
		return false;
	}

	static bool TryTokenizeDialogue(const char* lineBegin, const char* inBegin, const char* inEnd, const char*& outBegin, const char*& outEnd, TextEditor::PaletteIndex& paletteIndex)
	{
		const auto firstNonSpace = FindFirstNonSpace(lineBegin, inEnd);
		if (firstNonSpace >= inEnd)
			return false;

		if (*firstNonSpace == '@'
			|| *firstNonSpace == '#'
			|| *firstNonSpace == '&'
			|| *firstNonSpace == '$'
			|| *firstNonSpace == '-'
			|| *firstNonSpace == ';'
			|| (*firstNonSpace == '/' && firstNonSpace + 1 < inEnd && *(firstNonSpace + 1) == '/'))
		{
			return false;
		}

		const auto separator = FindToken(firstNonSpace, inEnd, ":");
		if (separator == nullptr)
			return false;

		if (inBegin == separator)
		{
			outBegin = inBegin;
			outEnd = inBegin + 1;
			paletteIndex = TextEditor::PaletteIndex::Punctuation;
			return true;
		}

		if (inBegin > separator)
		{
			auto cursor = separator + 1;
			while (cursor < inBegin && IsAsciiWhitespace(*cursor))
				++cursor;
			if (cursor != inBegin)
				return false;

			outBegin = inBegin;
			outEnd = inEnd;
			paletteIndex = TextEditor::PaletteIndex::String;
			return true;
		}

		if (inBegin == firstNonSpace)
		{
			auto roleEnd = separator;
			while (roleEnd > inBegin && IsAsciiWhitespace(*(roleEnd - 1)))
				--roleEnd;
			if (roleEnd <= inBegin)
				return false;

			outBegin = inBegin;
			outEnd = roleEnd;
			paletteIndex = TextEditor::PaletteIndex::Identifier;
			return true;
		}

		return false;
	}

	static bool TryTokenizeChoiceLine(const char* lineBegin, const char* inBegin, const char* inEnd, const char*& outBegin, const char*& outEnd, TextEditor::PaletteIndex& paletteIndex)
	{
		const auto firstNonSpace = FindFirstNonSpace(lineBegin, inEnd);
		if (firstNonSpace >= inEnd || *firstNonSpace != '-')
			return false;

		const auto arrow = FindToken(firstNonSpace + 1, inEnd, "->");
		if (inBegin == firstNonSpace)
		{
			outBegin = inBegin;
			outEnd = inBegin + 1;
			paletteIndex = TextEditor::PaletteIndex::Preprocessor;
			return true;
		}

		if (arrow != nullptr && inBegin == arrow)
		{
			outBegin = inBegin;
			outEnd = inBegin + 2;
			paletteIndex = TextEditor::PaletteIndex::Preprocessor;
			return true;
		}

		if (arrow != nullptr && inBegin > firstNonSpace && inBegin < arrow)
		{
			auto cursor = firstNonSpace + 1;
			while (cursor < inBegin && IsAsciiWhitespace(*cursor))
				++cursor;
			if (cursor != inBegin)
				return false;

			auto optionEnd = arrow;
			while (optionEnd > inBegin && IsAsciiWhitespace(*(optionEnd - 1)))
				--optionEnd;
			if (optionEnd <= inBegin)
				return false;

			outBegin = inBegin;
			outEnd = optionEnd;
			paletteIndex = TextEditor::PaletteIndex::String;
			return true;
		}

		return false;
	}

	static bool TokenizeVns(const char* lineBegin, const char* inBegin, const char* inEnd, const char*& outBegin, const char*& outEnd, TextEditor::PaletteIndex& paletteIndex)
	{
		if (inBegin == nullptr || inBegin >= inEnd)
			return false;

		if (*inBegin == ';')
		{
			outBegin = inBegin;
			outEnd = inEnd;
			paletteIndex = TextEditor::PaletteIndex::Comment;
			return true;
		}

		if (inBegin + 1 < inEnd && inBegin[0] == '/' && inBegin[1] == '/')
		{
			outBegin = inBegin;
			outEnd = inEnd;
			paletteIndex = TextEditor::PaletteIndex::Comment;
			return true;
		}

		if (*inBegin == '"')
		{
			outBegin = inBegin;
			outEnd = ScanStringLiteral(inBegin, inEnd);
			paletteIndex = TextEditor::PaletteIndex::String;
			return true;
		}

		if (TryTokenizeDialogue(lineBegin, inBegin, inEnd, outBegin, outEnd, paletteIndex))
			return true;

		if (TryTokenizeChoiceLine(lineBegin, inBegin, inEnd, outBegin, outEnd, paletteIndex))
			return true;

		if (inBegin + 1 < inEnd && inBegin[0] == '@' && inBegin[1] == '@')
		{
			outBegin = inBegin;
			outEnd = inBegin + 2;
			paletteIndex = TextEditor::PaletteIndex::CharLiteral;
			return true;
		}

		if (*inBegin == '@')
		{
			outBegin = inBegin;
			outEnd = inBegin + 1;
			paletteIndex = TextEditor::PaletteIndex::Preprocessor;
			return true;
		}

		if (*inBegin == '&')
		{
			outBegin = inBegin;
			outEnd = inBegin + 1;
			paletteIndex = TextEditor::PaletteIndex::ResourceIdentifier;
			return true;
		}

		if (inBegin + 1 < inEnd && inBegin[0] == '-' && inBegin[1] == '>')
		{
			outBegin = inBegin;
			outEnd = inBegin + 2;
			paletteIndex = TextEditor::PaletteIndex::Preprocessor;
			return true;
		}

		if (*inBegin == '#')
		{
			if (IsLabelContext(lineBegin, inBegin) && inBegin + 1 < inEnd && IsLabelIdentifierStart(*(inBegin + 1)))
			{
				outBegin = inBegin;
				outEnd = inBegin + 1;
				paletteIndex = TextEditor::PaletteIndex::Punctuation;
				return true;
			}

			auto cursor = inBegin + 1;
			auto hexCount = 0;
			while (cursor < inEnd && IsHexDigit(*cursor) && hexCount < 8)
			{
				++cursor;
				++hexCount;
			}
			if ((hexCount == 6 || hexCount == 8)
				&& (cursor >= inEnd || (!IsIdentifierPart(*cursor) && *cursor != '.')))
			{
				outBegin = inBegin;
				outEnd = cursor;
				paletteIndex = TextEditor::PaletteIndex::Number;
				return true;
			}

			if (inBegin + 1 < inEnd && IsLabelIdentifierStart(*(inBegin + 1)))
			{
				outBegin = inBegin;
				outEnd = inBegin + 1;
				paletteIndex = TextEditor::PaletteIndex::Punctuation;
				return true;
			}
		}

		if (*inBegin == '$' && inBegin + 1 < inEnd && IsIdentifierStart(*(inBegin + 1)))
		{
			outBegin = inBegin;
			outEnd = ScanIdentifierOrDotted(inBegin + 1, inEnd);
			paletteIndex = TextEditor::PaletteIndex::KnownIdentifier;
			return true;
		}

		if ((inEnd - inBegin) >= 7 && std::memcmp(inBegin, "global.", 7) == 0 && IsIdentifierStart(*(inBegin + 7)))
		{
			outBegin = inBegin;
			outEnd = ScanIdentifierOrDotted(inBegin + 7, inEnd);
			paletteIndex = TextEditor::PaletteIndex::KnownIdentifier;
			return true;
		}

		if ((inEnd - inBegin) >= 5 && std::memcmp(inBegin, "temp.", 5) == 0 && IsIdentifierStart(*(inBegin + 5)))
		{
			outBegin = inBegin;
			outEnd = ScanIdentifierOrDotted(inBegin + 5, inEnd);
			paletteIndex = TextEditor::PaletteIndex::KnownIdentifier;
			return true;
		}

		if (std::isdigit(static_cast<unsigned char>(*inBegin)) != 0
			|| (*inBegin == '-' && inBegin + 1 < inEnd && std::isdigit(static_cast<unsigned char>(*(inBegin + 1))) != 0))
		{
			auto cursor = inBegin;
			if (*cursor == '-')
				++cursor;
			while (cursor < inEnd && std::isdigit(static_cast<unsigned char>(*cursor)) != 0)
				++cursor;
			if (cursor < inEnd && *cursor == '.')
			{
				++cursor;
				while (cursor < inEnd && std::isdigit(static_cast<unsigned char>(*cursor)) != 0)
					++cursor;
			}
			outBegin = inBegin;
			outEnd = cursor;
			paletteIndex = TextEditor::PaletteIndex::Number;
			return true;
		}

		const auto prev = FindPrevNonSpace(lineBegin, inBegin);
		if (prev != nullptr && *prev == '#' && IsLabelContext(lineBegin, prev) && IsLabelIdentifierStart(*inBegin))
		{
			outBegin = inBegin;
			outEnd = ScanLabelIdentifier(inBegin, inEnd);
			paletteIndex = TextEditor::PaletteIndex::KnownIdentifier;
			return true;
		}

		if (IsIdentifierStart(*inBegin))
		{
			const auto identifierEnd = ScanIdentifier(inBegin, inEnd);
			auto cursor = identifierEnd;
			while (cursor < inEnd && IsAsciiWhitespace(*cursor))
				++cursor;
			outBegin = inBegin;
			outEnd = identifierEnd;
			paletteIndex = TextEditor::PaletteIndex::Identifier;

			if (prev != nullptr)
			{
				if (*prev == '&')
				{
					paletteIndex = TextEditor::PaletteIndex::ResourceIdentifier;
					return true;
				}

				if (*prev == '@')
				{
					const auto isDoubleAt = prev > lineBegin && *(prev - 1) == '@';
					paletteIndex = isDoubleAt
						? TextEditor::PaletteIndex::CharLiteral
						: (IsControlKeywordToken(inBegin, identifierEnd)
							? TextEditor::PaletteIndex::Keyword
							: TextEditor::PaletteIndex::PreprocIdentifier);
					return true;
				}

				if (*prev == '#' && IsLabelContext(lineBegin, prev))
				{
					paletteIndex = TextEditor::PaletteIndex::KnownIdentifier;
					return true;
				}
			}

			if (cursor < inEnd && *cursor == ':')
			{
				paletteIndex = TextEditor::PaletteIndex::KnownIdentifier;
				return true;
			}
			return true;
		}

		switch (*inBegin)
		{
		case '(':
		case ')':
		case '[':
		case ']':
		case '{':
		case '}':
		case ':':
		case ',':
		case '.':
			outBegin = inBegin;
			outEnd = inBegin + 1;
			paletteIndex = TextEditor::PaletteIndex::Punctuation;
			return true;
		default:
			break;
		}

		return false;
	}

	static const TextEditor::LanguageDefinition& BuildVnsLanguageDefinition()
	{
		static bool initialized = false;
		static TextEditor::LanguageDefinition languageDefinition;
		if (!initialized)
		{
			languageDefinition.mName = "VNS";
			languageDefinition.mTokenize = &TokenizeVns;
			languageDefinition.mCaseSensitive = true;
			languageDefinition.mAutoIndentation = false;
			languageDefinition.mCommentStart.clear();
			languageDefinition.mCommentEnd.clear();
			languageDefinition.mSingleLineComment.clear();
			languageDefinition.mPreprocChar = '\0';
			languageDefinition.mKeywords.insert("if");
			languageDefinition.mKeywords.insert("elif");
			languageDefinition.mKeywords.insert("else");
			languageDefinition.mKeywords.insert("end");
			languageDefinition.mKeywords.insert("choice");
			languageDefinition.mKeywords.insert("jump");
			languageDefinition.mKeywords.insert("node");
			initialized = true;
		}
		return languageDefinition;
	}

	static const TextEditor::LanguageDefinition& ResolveLanguageDefinition(const std::string& languageId)
	{
		const auto normalized = NormalizeLanguageId(languageId);
		if (normalized == "vns")
			return BuildVnsLanguageDefinition();
		return TextEditor::LanguageDefinition::Lua();
	}

	static const TextEditor::Palette& ResolvePalette(const std::string& paletteId)
	{
		if (paletteId == "light")
			return TextEditor::GetLightPalette();
		if (paletteId == "retro_blue")
			return TextEditor::GetRetroBluePalette();
		return TextEditor::GetDarkPalette();
	}

	static void ApplyPaletteTable(TextEditor& editor, luabridge::LuaRef table)
	{
		auto palette = editor.GetPalette();
		const auto maxCount = static_cast<int>(TextEditor::PaletteIndex::Max);
		for (int index = 1; index <= maxCount; ++index)
		{
			auto value = table[index];
			if (value.isNil())
				continue;

			if (value.isNumber())
			{
				palette[index - 1] = static_cast<ImU32>(value.cast<unsigned int>().value());
			}
			else
			{
				ImVec4 color = value.cast<ImVec4>().value();
				palette[index - 1] = ImGui::ColorConvertFloat4ToU32(color);
			}
		}

		editor.SetPalette(palette);
	}

	static ImU32 ResolveColorValue(luabridge::LuaRef value, ImU32 fallback)
	{
		if (value.isNil())
			return fallback;

		if (value.isNumber())
			return static_cast<ImU32>(value.cast<unsigned int>().value());

		return ImGui::ColorConvertFloat4ToU32(value.cast<ImVec4>().value());
	}

	static void SetErrorMarkersFromTable(TextEditor& editor, luabridge::LuaRef table)
	{
		TextEditor::ErrorMarkers markers;
		for (int index = 1;; ++index)
		{
			auto item = table[index];
			if (item.isNil())
				break;

			if (item.isTable())
			{
				auto lineRef = item["line"];
				auto messageRef = item["message"];
				if (!lineRef.isNil() && !messageRef.isNil())
				{
					int line = std::max(1, lineRef.cast<int>().value());
					std::string message = messageRef.cast<std::string>().value();
					markers[line] = message;
				}
			}
		}

		editor.SetErrorMarkers(markers);
	}

	static void ApplyKeywordTable(TextEditor::LanguageDefinition& definition, luabridge::LuaRef table)
	{
		if (table.isNil())
			return;

		for (int index = 1;; ++index)
		{
			auto item = table[index];
			if (item.isNil())
				break;

			std::string keyword;
			if (item.isString())
			{
				keyword = item.cast<std::string>().value();
			}
			else if (item.isTable())
			{
				auto nameRef = item["name"];
				if (!nameRef.isNil())
					keyword = nameRef.cast<std::string>().value();
			}

			if (!keyword.empty())
				definition.mKeywords.insert(keyword);
		}
	}

	static void ApplyIdentifierTable(TextEditor::Identifiers& target, luabridge::LuaRef table)
	{
		if (table.isNil())
			return;

		for (int index = 1;; ++index)
		{
			auto item = table[index];
			if (item.isNil())
				break;

			std::string name;
			std::string declaration;
			if (item.isString())
			{
				name = item.cast<std::string>().value();
				declaration = name;
			}
			else if (item.isTable())
			{
				auto nameRef = item["name"];
				auto declarationRef = item["declaration"];
				if (!nameRef.isNil())
					name = nameRef.cast<std::string>().value();
				if (!declarationRef.isNil())
					declaration = declarationRef.cast<std::string>().value();
			}

			if (name.empty())
				continue;
			if (declaration.empty())
				declaration = name;

			TextEditor::Identifier identifier;
			identifier.mDeclaration = declaration;
			target[name] = identifier;
		}
	}

	static void ApplyLanguageSymbols(TextEditor& editor, const std::string& languageId, luabridge::LuaRef symbolTable)
	{
		auto definition = ResolveLanguageDefinition(languageId);
		if (!symbolTable.isNil())
		{
			ApplyKeywordTable(definition, symbolTable["keywords"]);
			ApplyIdentifierTable(definition.mIdentifiers, symbolTable["identifiers"]);
			ApplyIdentifierTable(definition.mPreprocIdentifiers, symbolTable["preproc_identifiers"]);
		}
		editor.SetLanguageDefinition(definition);
	}
}

void init_imgui_text_editor_module(lua_State* L)
{
	luabridge::getGlobalNamespace(L)
		.beginNamespace("Engine")
			.beginNamespace("ImGUI")
				.beginClass<LuaTextEditorHandle>("TextEditorHandle")
					.addConstructor<void(*)()>()
					.addFunction("IsValid", &LuaTextEditorHandle::IsValid)
				.endClass()
				.beginNamespace("TextEditor")
					.addFunction("Create", +[]()
						{
							return LuaTextEditorHandle();
						})
					.addFunction("Destroy", +[](LuaTextEditorHandle& handle)
						{
							handle.Destroy();
						})
					.addFunction("SetText", +[](LuaTextEditorHandle& handle, const std::string& text)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetText(text);
						})
					.addFunction("GetText", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->GetText();
							return std::string();
						})
					.addFunction("Render", +[](LuaTextEditorHandle& handle, const char* title, luabridge::LuaRef size)
						{
							auto* editor = GetEditor(handle);
							if (!editor)
								return false;

							editor->Render(title, size.isNil() ? ImVec2(0, 0) : size.cast<ImVec2>().value(), false);
							handle.lastFocused = ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows);
							return editor->IsTextChanged();
						})
					.addFunction("SetLanguage", +[](LuaTextEditorHandle& handle, const std::string& languageId)
						{
							auto* editor = GetEditor(handle);
							if (!editor)
								return;

							handle.languageId = NormalizeLanguageId(languageId);
							editor->SetLanguageDefinition(ResolveLanguageDefinition(handle.languageId));
						})
					.addFunction("SetLanguageSymbols", +[](LuaTextEditorHandle& handle, const std::string& languageId, luabridge::LuaRef symbolTable)
						{
							auto* editor = GetEditor(handle);
							if (!editor)
								return;

							handle.languageId = NormalizeLanguageId(languageId);
							ApplyLanguageSymbols(*editor, handle.languageId, symbolTable);
						})
					.addFunction("SetErrorMarkers", +[](LuaTextEditorHandle& handle, luabridge::LuaRef markers)
						{
							auto* editor = GetEditor(handle);
							if (!editor)
								return;

							if (markers.isNil())
							{
								editor->SetErrorMarkers(TextEditor::ErrorMarkers());
								return;
							}

							SetErrorMarkersFromTable(*editor, markers);
						})
					.addFunction("SetPalette", luabridge::overload<LuaTextEditorHandle&, const std::string&>(+[](LuaTextEditorHandle& handle, const std::string& paletteId)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetPalette(ResolvePalette(paletteId));
						}),
						luabridge::overload<LuaTextEditorHandle&, luabridge::LuaRef>(+[](LuaTextEditorHandle& handle, luabridge::LuaRef palette)
						{
							auto* editor = GetEditor(handle);
							if (!editor || palette.isNil())
								return;
							ApplyPaletteTable(*editor, palette);
						}))
					.addFunction("SetCursorPosition", +[](LuaTextEditorHandle& handle, int line, int column)
						{
							if (auto* editor = GetEditor(handle))
							{
								editor->SetCursorPosition(TextEditor::Coordinates(std::max(0, line - 1), std::max(0, column - 1)));
							}
						})
					.addFunction("GetCursorPosition", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
							{
								auto position = editor->GetCursorPosition();
								return ImVec2(static_cast<float>(position.mLine + 1), static_cast<float>(position.mColumn + 1));
							}
							return ImVec2(1.0f, 1.0f);
						})
					.addFunction("GetCursorScreenPosition", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->GetCursorScreenPosition();
							return ImVec2(0.0f, 0.0f);
						})
					.addFunction("SetSelection", +[](LuaTextEditorHandle& handle, int startLine, int startColumn, int endLine, int endColumn)
						{
							if (auto* editor = GetEditor(handle))
							{
								editor->SetSelection(
									TextEditor::Coordinates(std::max(0, startLine - 1), std::max(0, startColumn - 1)),
									TextEditor::Coordinates(std::max(0, endLine - 1), std::max(0, endColumn - 1)));
							}
						})
					.addFunction("InsertText", +[](LuaTextEditorHandle& handle, const std::string& text)
						{
							if (auto* editor = GetEditor(handle))
								editor->InsertTextWithUndo(text);
						})
					.addFunction("GetCurrentLineText", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->GetCurrentLineText();
							return std::string();
						})
					.addFunction("GetSelectedText", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->GetSelectedText();
							return std::string();
						})
					.addFunction("HasSelection", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->HasSelection();
							return false;
						})
					.addFunction("IsFocused", +[](LuaTextEditorHandle& handle)
						{
							return handle.lastFocused;
						})
					.addFunction("SetReadOnly", +[](LuaTextEditorHandle& handle, bool value)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetReadOnly(value);
						})
					.addFunction("SetHandleMouseInputs", +[](LuaTextEditorHandle& handle, bool value)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetHandleMouseInputs(value);
						})
					.addFunction("SetHandleKeyboardInputs", +[](LuaTextEditorHandle& handle, bool value)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetHandleKeyboardInputs(value);
						})
					.addFunction("SetCompletionPopupActive", +[](LuaTextEditorHandle& handle, bool value)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetCompletionPopupActive(value);
						})
					.addFunction("SetShowBuiltInTooltips", +[](LuaTextEditorHandle& handle, bool value)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetShowBuiltInTooltips(value);
						})
					.addFunction("SetLineSpacing", +[](LuaTextEditorHandle& handle, float value)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetLineSpacing(value);
						})
					.addFunction("SetSearchQuery", +[](LuaTextEditorHandle& handle, const std::string& query, bool revealCurrent)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetSearchQuery(query, revealCurrent);
						})
					.addFunction("SetSearchOptions", +[](LuaTextEditorHandle& handle, bool caseSensitive, bool wholeWord, bool revealCurrent)
						{
							if (auto* editor = GetEditor(handle))
								editor->SetSearchOptions(caseSensitive, wholeWord, revealCurrent);
						})
					.addFunction("SetSearchHighlightColors", +[](LuaTextEditorHandle& handle, luabridge::LuaRef matchColor, luabridge::LuaRef currentColor)
						{
							auto* editor = GetEditor(handle);
							if (!editor)
								return;

							editor->SetSearchHighlightColors(
								ResolveColorValue(matchColor, 0x30429dd8),
								ResolveColorValue(currentColor, 0x5078c4ff));
						})
					.addFunction("GetSearchResultCount", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->GetSearchResultCount();
							return 0;
						})
					.addFunction("GetCurrentSearchResultIndex", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->GetCurrentSearchResultIndex();
							return 0;
						})
					.addFunction("FindNextSearchResult", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->FindNextSearchResult();
							return false;
						})
					.addFunction("FindPreviousSearchResult", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->FindPreviousSearchResult();
							return false;
						})
					.addFunction("ReplaceCurrentSearchResult", +[](LuaTextEditorHandle& handle, const std::string& replacement)
						{
							if (auto* editor = GetEditor(handle))
								return editor->ReplaceCurrentSearchResult(replacement);
							return false;
						})
					.addFunction("ReplaceAllSearchResults", +[](LuaTextEditorHandle& handle, const std::string& replacement)
						{
							if (auto* editor = GetEditor(handle))
								return editor->ReplaceAllSearchResults(replacement);
							return 0;
						})
					.addFunction("GetHoveredCoordinates", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
							{
								auto position = editor->GetHoveredCoordinates();
								if (position == TextEditor::Coordinates::Invalid())
									return ImVec2(0.0f, 0.0f);
								return ImVec2(static_cast<float>(position.mLine + 1), static_cast<float>(position.mColumn + 1));
							}
							return ImVec2(0.0f, 0.0f);
						})
					.addFunction("GetHoveredWord", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->GetHoveredWord();
							return std::string();
						})
					.addFunction("CanUndo", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->CanUndo();
							return false;
						})
					.addFunction("CanRedo", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								return editor->CanRedo();
							return false;
						})
					.addFunction("Undo", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								editor->Undo();
						})
					.addFunction("Redo", +[](LuaTextEditorHandle& handle)
						{
							if (auto* editor = GetEditor(handle))
								editor->Redo();
						})
				.endNamespace()
			.endNamespace()
		.endNamespace();
}
