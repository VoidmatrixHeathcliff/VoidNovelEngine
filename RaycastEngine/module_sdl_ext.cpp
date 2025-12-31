#include "module_sdl_ext.h"

static SDL_MessageBoxColorScheme msgBoxColorScheme =
{
	SDL_MessageBoxColor{ 255, 0, 0 },
	SDL_MessageBoxColor{ 0, 255, 0 },
	SDL_MessageBoxColor{ 255, 255, 0 },
	SDL_MessageBoxColor{ 0, 0, 255 },
	SDL_MessageBoxColor{ 255, 0, 255 },
};

bool SDL_ShowConfirmBox(Uint32 flags, const char* title, const char* message, SDL_Window* window, luabridge::LuaRef btn_ok, luabridge::LuaRef btn_cancel)
{
	SDL_MessageBoxButtonData _btnData[2] =
	{
		{
			SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, 1,
			btn_ok ? btn_ok.cast<const char*>().value() : "OK"
		},
		{
			SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, 2,
			btn_cancel ? btn_cancel.cast<const char*>().value() : "Cancel"
		},
	};
	SDL_MessageBoxData _msgboxData =
	{
		flags, window, title, message,
		2, _btnData, &msgBoxColorScheme
	};

	int _btnID = 0;
	SDL_ShowMessageBox(&_msgboxData, &_btnID);
	return _btnID == 1;
}