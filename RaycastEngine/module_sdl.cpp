#include "module_sdl.h"
#include "module_sdl_ext.h"

#include <system_error>

#include <Map.h>
#include <SDL.h>
#include <SDL_ttf.h>
#include <SDL_net.h>
#include <SDL_mixer.h>
#include <SDL_image.h>
#include <LuaBridge.h>
#include <SDL2_gfxPrimitives.h>

#include <string>

struct LockResult
{
	int pitch = 0;
	bool valid = false;
	void* data = nullptr;
};

struct NetRecvBuffer
{
	size_t len = 0;
	char* data = nullptr;
};

struct PointList
{
	std::vector<SDL_Point> list;

	void add(int x, int y) { list.push_back({x, y}); };
	void add(const SDL_Point& point) { list.push_back(point); };
	void pop() { list.pop_back(); };
	void clear() { list.clear(); };
	int size() const { return (int)list.size(); };
};

void init_sdl_module(lua_State* L)
{
	luabridge::getGlobalNamespace(L)
		.beginNamespace("Engine")
			.beginNamespace("SDL")
				// enum
				.beginNamespace("SubSystem")
					.addVariable("TIMER", SDL_INIT_TIMER)
					.addVariable("AUDIO", SDL_INIT_AUDIO)
					.addVariable("VIDEO", SDL_INIT_VIDEO)
					.addVariable("JOYSTICK", SDL_INIT_JOYSTICK)
					.addVariable("HAPTIC", SDL_INIT_HAPTIC)
					.addVariable("GAMECONTROLLER", SDL_INIT_GAMECONTROLLER)
					.addVariable("EVENTS", SDL_INIT_EVENTS)
					.addVariable("SENSOR", SDL_INIT_SENSOR)
					.addVariable("EVERYTHING", SDL_INIT_EVERYTHING)
				.endNamespace()
				.beginNamespace("MessageBoxFlags")
					.addVariable("ERROR", SDL_MESSAGEBOX_ERROR)
					.addVariable("WARNING", SDL_MESSAGEBOX_WARNING)
					.addVariable("INFORMATION", SDL_MESSAGEBOX_INFORMATION)
					.addVariable("BUTTONS_LEFT_TO_RIGHT", SDL_MESSAGEBOX_BUTTONS_LEFT_TO_RIGHT)
					.addVariable("BUTTONS_RIGHT_TO_LEFT", SDL_MESSAGEBOX_BUTTONS_RIGHT_TO_LEFT)
				.endNamespace()
				.beginNamespace("WindowPosition")
					.addVariable("CENTERED", SDL_WINDOWPOS_CENTERED)
					.addVariable("UNDEFINED", SDL_WINDOWPOS_UNDEFINED)
				.endNamespace()
				.beginNamespace("WindowFlags")
					.addVariable("FULLSCREEN", SDL_WINDOW_FULLSCREEN)
					.addVariable("SHOWN", SDL_WINDOW_SHOWN)
					.addVariable("HIDDEN", SDL_WINDOW_HIDDEN)
					.addVariable("BORDERLESS", SDL_WINDOW_BORDERLESS)
					.addVariable("RESIZABLE", SDL_WINDOW_RESIZABLE)
					.addVariable("MINIMIZED", SDL_WINDOW_MINIMIZED)
					.addVariable("MAXIMIZED", SDL_WINDOW_MAXIMIZED)
					.addVariable("MOUSE_GRABBED", SDL_WINDOW_MOUSE_GRABBED)
					.addVariable("INPUT_FOCUS", SDL_WINDOW_INPUT_FOCUS)
					.addVariable("MOUSE_FOCUS", SDL_WINDOW_MOUSE_FOCUS)
					.addVariable("FULLSCREEN_DESKTOP", SDL_WINDOW_FULLSCREEN_DESKTOP)
					.addVariable("ALLOW_HIGHDPI", SDL_WINDOW_ALLOW_HIGHDPI)
					.addVariable("MOUSE_CAPTURE", SDL_WINDOW_MOUSE_CAPTURE)
					.addVariable("ALWAYS_ON_TOP", SDL_WINDOW_ALWAYS_ON_TOP)
					.addVariable("SKIP_TASKBAR", SDL_WINDOW_SKIP_TASKBAR)
					.addVariable("KEYBOARD_GRABBED", SDL_WINDOW_KEYBOARD_GRABBED)
					.addVariable("INPUT_GRABBED", SDL_WINDOW_INPUT_GRABBED)
				.endNamespace()
				.beginNamespace("RendererFlags")
					.addVariable("SOFTWARE", SDL_RENDERER_SOFTWARE)
					.addVariable("ACCELERATED", SDL_RENDERER_ACCELERATED)
					.addVariable("PRESENTVSYNC", SDL_RENDERER_PRESENTVSYNC)
					.addVariable("TARGETTEXTURE", SDL_RENDERER_TARGETTEXTURE)
				.endNamespace()
				.beginNamespace("BlendMode")
					.addVariable("NONE", SDL_BLENDMODE_NONE)
					.addVariable("BLEND", SDL_BLENDMODE_BLEND)
					.addVariable("ADD", SDL_BLENDMODE_ADD)
					.addVariable("MOD", SDL_BLENDMODE_MOD)
					.addVariable("MUL", SDL_BLENDMODE_MUL)
					.addVariable("INVALID", SDL_BLENDMODE_INVALID)
				.endNamespace()
				.beginNamespace("PixelFormat")
					.addVariable("UNKNOWN", SDL_PIXELFORMAT_UNKNOWN)
					.addVariable("INDEX1LSB", SDL_PIXELFORMAT_INDEX1LSB)
					.addVariable("INDEX1MSB", SDL_PIXELFORMAT_INDEX1MSB)
					.addVariable("INDEX2LSB", SDL_PIXELFORMAT_INDEX2LSB)
					.addVariable("INDEX2MSB", SDL_PIXELFORMAT_INDEX2MSB)
					.addVariable("INDEX4LSB", SDL_PIXELFORMAT_INDEX4LSB)
					.addVariable("INDEX4MSB", SDL_PIXELFORMAT_INDEX4MSB)
					.addVariable("INDEX8", SDL_PIXELFORMAT_INDEX8)
					.addVariable("RGB332", SDL_PIXELFORMAT_RGB332)
					.addVariable("XRGB4444", SDL_PIXELFORMAT_XRGB4444)
					.addVariable("RGB444", SDL_PIXELFORMAT_RGB444)
					.addVariable("XBGR4444", SDL_PIXELFORMAT_XBGR4444)
					.addVariable("BGR444", SDL_PIXELFORMAT_BGR444)
					.addVariable("XRGB1555", SDL_PIXELFORMAT_XRGB1555)
					.addVariable("RGB555", SDL_PIXELFORMAT_RGB555)
					.addVariable("XBGR1555", SDL_PIXELFORMAT_XBGR1555)
					.addVariable("BGR555", SDL_PIXELFORMAT_BGR555)
					.addVariable("ARGB4444", SDL_PIXELFORMAT_ARGB4444)
					.addVariable("RGBA4444", SDL_PIXELFORMAT_RGBA4444)
					.addVariable("ABGR4444", SDL_PIXELFORMAT_ABGR4444)
					.addVariable("BGRA4444", SDL_PIXELFORMAT_BGRA4444)
					.addVariable("ARGB1555", SDL_PIXELFORMAT_ARGB1555)
					.addVariable("RGBA5551", SDL_PIXELFORMAT_RGBA5551)
					.addVariable("ABGR1555", SDL_PIXELFORMAT_ABGR1555)
					.addVariable("BGRA5551", SDL_PIXELFORMAT_BGRA5551)
					.addVariable("RGB565", SDL_PIXELFORMAT_RGB565)
					.addVariable("BGR565", SDL_PIXELFORMAT_BGR565)
					.addVariable("RGB24", SDL_PIXELFORMAT_RGB24)
					.addVariable("BGR24", SDL_PIXELFORMAT_BGR24)
					.addVariable("XRGB8888", SDL_PIXELFORMAT_XRGB8888)
					.addVariable("RGB888", SDL_PIXELFORMAT_RGB888)
					.addVariable("RGBX8888", SDL_PIXELFORMAT_RGBX8888)
					.addVariable("XBGR8888", SDL_PIXELFORMAT_XBGR8888)
					.addVariable("BGR888", SDL_PIXELFORMAT_BGR888)
					.addVariable("BGRX8888", SDL_PIXELFORMAT_BGRX8888)
					.addVariable("ARGB8888", SDL_PIXELFORMAT_ARGB8888)
					.addVariable("RGBA8888", SDL_PIXELFORMAT_RGBA8888)
					.addVariable("ABGR8888", SDL_PIXELFORMAT_ABGR8888)
					.addVariable("BGRA8888", SDL_PIXELFORMAT_BGRA8888)
					.addVariable("ARGB2101010", SDL_PIXELFORMAT_ARGB2101010)
					.addVariable("RGBA32", SDL_PIXELFORMAT_RGBA32)
					.addVariable("ARGB32", SDL_PIXELFORMAT_ARGB32)
					.addVariable("BGRA32", SDL_PIXELFORMAT_BGRA32)
					.addVariable("ABGR32", SDL_PIXELFORMAT_ABGR32)
					.addVariable("RGBX32", SDL_PIXELFORMAT_RGBX32)
					.addVariable("XRGB32", SDL_PIXELFORMAT_XRGB32)
					.addVariable("BGRX32", SDL_PIXELFORMAT_BGRX32)
					.addVariable("XBGR32", SDL_PIXELFORMAT_XBGR32)
					.addVariable("YV12", SDL_PIXELFORMAT_YV12)
					.addVariable("IYUV", SDL_PIXELFORMAT_IYUV)
					.addVariable("YUY2", SDL_PIXELFORMAT_YUY2)
					.addVariable("UYVY", SDL_PIXELFORMAT_UYVY)
					.addVariable("YVYU", SDL_PIXELFORMAT_YVYU)
					.addVariable("NV12", SDL_PIXELFORMAT_NV12)
					.addVariable("NV21", SDL_PIXELFORMAT_NV21)
					.addVariable("EXTERNAL_OES", SDL_PIXELFORMAT_EXTERNAL_OES)
				.endNamespace()
				.beginNamespace("TextureAccess")
					.addVariable("STATIC", SDL_TEXTUREACCESS_STATIC)
					.addVariable("STREAMING", SDL_TEXTUREACCESS_STREAMING)
					.addVariable("TARGET", SDL_TEXTUREACCESS_TARGET)
				.endNamespace()
				.beginNamespace("EventType")
					.addVariable("QUIT", SDL_QUIT)
					.addVariable("APP_TERMINATING", SDL_APP_TERMINATING)
					.addVariable("APP_LOWMEMORY", SDL_APP_LOWMEMORY)
					.addVariable("APP_WILLENTERBACKGROUND", SDL_APP_WILLENTERBACKGROUND)
					.addVariable("APP_DIDENTERBACKGROUND", SDL_APP_DIDENTERBACKGROUND)
					.addVariable("APP_WILLENTERFOREGROUND", SDL_APP_WILLENTERFOREGROUND)
					.addVariable("APP_DIDENTERFOREGROUND", SDL_APP_DIDENTERFOREGROUND)
					.addVariable("LOCALECHANGED", SDL_LOCALECHANGED)
					.addVariable("DISPLAYEVENT", SDL_DISPLAYEVENT)
					.addVariable("WINDOWEVENT", SDL_WINDOWEVENT)
					.addVariable("SYSWMEVENT", SDL_SYSWMEVENT)
					.addVariable("KEYDOWN", SDL_KEYDOWN)
					.addVariable("KEYUP", SDL_KEYUP)
					.addVariable("TEXTEDITING", SDL_TEXTEDITING)
					.addVariable("TEXTINPUT", SDL_TEXTINPUT)
					.addVariable("KEYMAPCHANGED", SDL_KEYMAPCHANGED)
					.addVariable("TEXTEDITING_EXT", SDL_TEXTEDITING_EXT)
					.addVariable("MOUSEMOTION", SDL_MOUSEMOTION)
					.addVariable("MOUSEBUTTONDOWN", SDL_MOUSEBUTTONDOWN)
					.addVariable("MOUSEBUTTONUP", SDL_MOUSEBUTTONUP)
					.addVariable("MOUSEWHEEL", SDL_MOUSEWHEEL)
					.addVariable("JOYAXISMOTION", SDL_JOYAXISMOTION)
					.addVariable("JOYBALLMOTION", SDL_JOYBALLMOTION)
					.addVariable("JOYHATMOTION", SDL_JOYHATMOTION)
					.addVariable("JOYBUTTONDOWN", SDL_JOYBUTTONDOWN)
					.addVariable("JOYBUTTONUP", SDL_JOYBUTTONUP)
					.addVariable("JOYDEVICEADDED", SDL_JOYDEVICEADDED)
					.addVariable("JOYDEVICEREMOVED", SDL_JOYDEVICEREMOVED)
					.addVariable("JOYBATTERYUPDATED", SDL_JOYBATTERYUPDATED)
					.addVariable("CONTROLLERAXISMOTION", SDL_CONTROLLERAXISMOTION)
					.addVariable("CONTROLLERBUTTONDOWN", SDL_CONTROLLERBUTTONDOWN)
					.addVariable("CONTROLLERBUTTONUP", SDL_CONTROLLERBUTTONUP)
					.addVariable("CONTROLLERDEVICEADDED", SDL_CONTROLLERDEVICEADDED)
					.addVariable("CONTROLLERDEVICEREMOVED", SDL_CONTROLLERDEVICEREMOVED)
					.addVariable("CONTROLLERDEVICEREMAPPED", SDL_CONTROLLERDEVICEREMAPPED)
					.addVariable("CONTROLLERTOUCHPADDOWN", SDL_CONTROLLERTOUCHPADDOWN)
					.addVariable("CONTROLLERTOUCHPADMOTION", SDL_CONTROLLERTOUCHPADMOTION)
					.addVariable("CONTROLLERTOUCHPADUP", SDL_CONTROLLERTOUCHPADUP)
					.addVariable("CONTROLLERSENSORUPDATE", SDL_CONTROLLERSENSORUPDATE)
					.addVariable("CONTROLLERUPDATECOMPLETE_RESERVED_FOR_SDL3", SDL_CONTROLLERUPDATECOMPLETE_RESERVED_FOR_SDL3)
					.addVariable("CONTROLLERSTEAMHANDLEUPDATED", SDL_CONTROLLERSTEAMHANDLEUPDATED)
					.addVariable("FINGERDOWN", SDL_FINGERDOWN)
					.addVariable("FINGERUP", SDL_FINGERUP)
					.addVariable("FINGERMOTION", SDL_FINGERMOTION)
					.addVariable("DOLLARGESTURE", SDL_DOLLARGESTURE)
					.addVariable("DOLLARRECORD", SDL_DOLLARRECORD)
					.addVariable("MULTIGESTURE", SDL_MULTIGESTURE)
					.addVariable("CLIPBOARDUPDATE", SDL_CLIPBOARDUPDATE)
					.addVariable("DROPFILE", SDL_DROPFILE)
					.addVariable("DROPTEXT", SDL_DROPTEXT)
					.addVariable("DROPBEGIN", SDL_DROPBEGIN)
					.addVariable("DROPCOMPLETE", SDL_DROPCOMPLETE)
					.addVariable("AUDIODEVICEADDED", SDL_AUDIODEVICEADDED)
					.addVariable("AUDIODEVICEREMOVED", SDL_AUDIODEVICEREMOVED)
					.addVariable("SENSORUPDATE", SDL_SENSORUPDATE)
					.addVariable("RENDER_TARGETS_RESET", SDL_RENDER_TARGETS_RESET)
					.addVariable("RENDER_DEVICE_RESET", SDL_RENDER_DEVICE_RESET)
					.addVariable("POLLSENTINEL", SDL_POLLSENTINEL)
					.addVariable("USEREVENT", SDL_USEREVENT)
				.endNamespace()
				.beginNamespace("ScaleMode")
					.addVariable("NEAREST", SDL_ScaleModeNearest)
					.addVariable("LINEAR", SDL_ScaleModeLinear)
					.addVariable("BEST", SDL_ScaleModeBest)
				.endNamespace()
				.beginNamespace("IMGInitFlags")
					.addVariable("JPG", IMG_INIT_JPG)
					.addVariable("PNG", IMG_INIT_PNG)
					.addVariable("TIF", IMG_INIT_TIF)
					.addVariable("WEBP", IMG_INIT_WEBP)
					.addVariable("JXL", IMG_INIT_JXL)
					.addVariable("AVIF", IMG_INIT_AVIF)
				.endNamespace()
				.beginNamespace("MIXInitFlags")
					.addVariable("FLAC", MIX_INIT_FLAC)
					.addVariable("MOD", MIX_INIT_MOD)
					.addVariable("MP3", MIX_INIT_MP3)
					.addVariable("OGG", MIX_INIT_OGG)
					.addVariable("MID", MIX_INIT_MID)
					.addVariable("OPUS", MIX_INIT_OPUS)
					.addVariable("WAVPACK", MIX_INIT_WAVPACK)
				.endNamespace()
				.beginNamespace("AudioFormat")
					.addVariable("DEFAULT", MIX_DEFAULT_FORMAT)
					.addVariable("U8", AUDIO_U8)
					.addVariable("S8", AUDIO_S8)
					.addVariable("U16LSB", AUDIO_U16LSB)
					.addVariable("S16LSB", AUDIO_S16LSB)
					.addVariable("U16MSB", AUDIO_U16MSB)
					.addVariable("S16MSB", AUDIO_S16MSB)
					.addVariable("U16", AUDIO_U16)
					.addVariable("S16", AUDIO_S16)
					.addVariable("S32LSB", AUDIO_S32LSB)
					.addVariable("S32MSB", AUDIO_S32MSB)
					.addVariable("S32", AUDIO_S32)
					.addVariable("F32LSB", AUDIO_F32LSB)
					.addVariable("F32MSB", AUDIO_F32MSB)
					.addVariable("F32", AUDIO_F32)
					.addVariable("U16SYS", AUDIO_U16SYS)
					.addVariable("S16SYS", AUDIO_S16SYS)
					.addVariable("S32SYS", AUDIO_S32SYS)
					.addVariable("F32SYS", AUDIO_F32SYS)
				.endNamespace()
				.addVariable("MAX_VOLUME", MIX_MAX_VOLUME)
				// usertype
				.beginClass<PointList>("PointList")
					.addFunction("add", luabridge::overload<int, int>(&PointList::add), luabridge::overload<const SDL_Point&>(&PointList::add))
					.addFunction("pop", &PointList::pop)
					.addFunction("clear", &PointList::clear)
					.addFunction("size", &PointList::size)
					.addConstructor<void()>()
				.endClass()
				.beginClass<LockResult>("LockResult")
					.addProperty("data", &LockResult::data, &LockResult::data)
					.addProperty("pitch", &LockResult::pitch, &LockResult::pitch)
					.addProperty("valid", &LockResult::valid, &LockResult::valid)
					.addConstructor<void()>()
				.endClass()
				.beginClass<SDL_Color>("Color")
					.addProperty("r", &SDL_Color::r, &SDL_Color::r)
					.addProperty("g", &SDL_Color::g, &SDL_Color::g)
					.addProperty("b", &SDL_Color::b, &SDL_Color::b)
					.addProperty("a", &SDL_Color::a, &SDL_Color::a)
					.addConstructor(+[](void* ptr, Uint8 r, Uint8 g, Uint8 b, Uint8 a) 
						{ return new (ptr) SDL_Color({ r, g, b, a }); },
						+[](void* ptr) { return new (ptr) SDL_Color(); })
				.endClass()
				.beginClass<SDL_Rect>("Rect")
					.addProperty("x", &SDL_Rect::x, &SDL_Rect::x)
					.addProperty("y", &SDL_Rect::y, &SDL_Rect::y)
					.addProperty("w", &SDL_Rect::w, &SDL_Rect::w)
					.addProperty("h", &SDL_Rect::h, &SDL_Rect::h)
					.addConstructor(+[](void* ptr, int x, int y, int width, int height)
						{ return new (ptr) SDL_Rect({ x, y, width, height }); },
						+[](void* ptr) { return new (ptr) SDL_Rect(); })
				.endClass()
				.beginClass<SDL_Window>("Window")
					
				.endClass()
				.beginClass<SDL_Renderer>("Renderer")
					
				.endClass()
				.beginClass<SDL_Event>("Event")
					.addProperty("type", &SDL_Event::type)
					.addConstructor<void()>()
				.endClass()
				.beginClass<SDL_Surface>("Surface")
					.addProperty("w", &SDL_Surface::w)
					.addProperty("h", &SDL_Surface::h)
					.addProperty("pitch", &SDL_Surface::pitch)
					.addProperty("pixels", &SDL_Surface::pixels)
				.endClass()
				.beginClass<SDL_Texture>("Texture")
					
				.endClass()
				.beginClass<Mix_Music>("Music")

				.endClass()
				.beginClass<Mix_Chunk>("Chunk")

				.endClass()
				.beginClass<TTF_Font>("Font")

				.endClass()
				.beginClass<IPaddress>("IPaddress")
					.addConstructor<void()>()
				.endClass()
				.beginClass<_TCPsocket>("TCPsocket")

				.endClass()
				.beginClass<_SDLNet_SocketSet>("SDLNet_SocketSet")

				.endClass()
				.beginClass<NetRecvBuffer>("NetRecvBuffer")
					.addProperty("data", +[](const NetRecvBuffer* buffer) { return (const char*)buffer->data; })
					.addFunction("__len", +[](const NetRecvBuffer* buffer) { return buffer->len; })
					.addConstructor<void()>()
				.endClass()
				// basic
				.addFunction("Init", SDL_Init)
				.addFunction("Quit", SDL_Quit)
				.addFunction("Delay", SDL_Delay)
				.addFunction("GetBasePath", +[]() 
					{ 
						char* path = SDL_GetBasePath();
						std::string str_path = path;
						SDL_free(path);
						return str_path;
					})
				.addFunction("GetPrefPath", +[](const char* org, const char* app) 
					{ 
						char* path = SDL_GetPrefPath(org, app);
						std::string str_path = path;
						SDL_free(path);
						return str_path;
					})
				.addFunction("SetHint", +[](const char* name, const char* value) { return SDL_SetHint(name, value) == SDL_TRUE;})
				.addFunction("ShowSimpleMessageBox", SDL_ShowSimpleMessageBox)
				.addFunction("ShowConfirmBox", SDL_ShowConfirmBox)
				.addFunction("CreateWindow", SDL_CreateWindow)
				.addFunction("DestroyWindow", SDL_DestroyWindow)
				.addFunction("SetWindowIcon", SDL_SetWindowIcon)
				.addFunction("CreateRenderer", SDL_CreateRenderer)
				.addFunction("DestroyRenderer", SDL_DestroyRenderer)
				.addFunction("CreateTexture", SDL_CreateTexture)
				.addFunction("DestroyTexture", SDL_DestroyTexture)
				.addFunction("UpdateTexture", SDL_UpdateTexture)
				.addFunction("LockTexture", +[](SDL_Texture* texture, LockResult* result, luabridge::LuaRef rect)
					{ result->valid = !SDL_LockTexture(texture, rect ? (const SDL_Rect*)rect : nullptr, &result->data, &result->pitch); })
				.addFunction("UnlockTexture", SDL_UnlockTexture)
				.addFunction("QueryTexture", +[](SDL_Texture* texture)
					{
						Uint32 format; int access, w, h; SDL_QueryTexture(texture, &format, &access, &w, &h);
						return std::map<std::string, int>({ {"format", format}, { "access", access }, { "w", w }, { "h", h } });
					})
				.addFunction("SetTextureScaleMode", +[](SDL_Texture* texture, int mode) { SDL_SetTextureScaleMode(texture, (SDL_ScaleMode)mode);})
				.addFunction("SetTextureBlendMode", +[](SDL_Texture* texture, int mode) { SDL_SetTextureBlendMode(texture, (SDL_BlendMode)mode); })
				.addFunction("CreateRGBSurface", SDL_CreateRGBSurface)
				.addFunction("SetSurfaceBlendMode", +[](SDL_Surface* surface, int mode) { SDL_SetSurfaceBlendMode(surface, (SDL_BlendMode)mode); })
				.addFunction("FreeSurface", SDL_FreeSurface)
				.addFunction("ConvertSurfaceFormat", SDL_ConvertSurfaceFormat)
				.addFunction("RenderReadPixels", SDL_RenderReadPixels)
				.addFunction("GetError", SDL_GetError)
				.addFunction("PollEvent", SDL_PollEvent)
				.addFunction("SetClipboardText", SDL_SetClipboardText)
				.addFunction("GetClipboardText", +[]() 
					{
						char* buffer = SDL_GetClipboardText();
						std::string str_content = buffer; SDL_free(buffer);
						return str_content;
					})
				.addFunction("SetRenderTarget", SDL_SetRenderTarget)
				.addFunction("GetRenderTarget", SDL_GetRenderTarget)
				.addFunction("SetRenderDrawColor", SDL_SetRenderDrawColor)
				.addFunction("RenderClear", SDL_RenderClear)
				.addFunction("RenderPresent", SDL_RenderPresent)
				.addFunction("GetNumVideoDisplays", SDL_GetNumVideoDisplays)
				.addFunction("GetDesktopDisplayMode", +[](int idx)
					{
						SDL_DisplayMode mode; SDL_GetDesktopDisplayMode(idx, &mode);
						return std::map<std::string, int>({ {"format", mode.format}, 
							{ "refresh_rate", mode.refresh_rate }, { "w", mode.w }, { "h", mode.h } });
					})
				.addFunction("GetDisplayBounds", +[](int idx)
					{
						SDL_Rect rect; SDL_GetDisplayBounds(idx, &rect);
						return rect;
					})
				// mixer
				.addFunction("InitMIX", Mix_Init)
				.addFunction("QuitMIX", Mix_Quit)
				.addFunction("OpenAudio", Mix_OpenAudio)
				.addFunction("LoadMUS", Mix_LoadMUS)
				.addFunction("FreeMusic", Mix_FreeMusic)
				.addFunction("PlayMusic", Mix_PlayMusic)
				.addFunction("FadeInMusic", Mix_FadeInMusic)
				.addFunction("HaltMusic", Mix_HaltMusic)
				.addFunction("FadeOutMusic", Mix_FadeOutMusic)
				.addFunction("ResumeMusic", Mix_ResumeMusic)
				.addFunction("LoadWAV", Mix_LoadWAV)
				.addFunction("FreeChunk", Mix_FreeChunk)
				.addFunction("PlayChannel", Mix_PlayChannel)
				.addFunction("FadeInChannel", Mix_FadeInChannel)
				.addFunction("HaltChannel", Mix_HaltChannel)
				.addFunction("FadeOutChannel", Mix_FadeOutChannel)
				.addFunction("Volume", Mix_Volume)
				.addFunction("VolumeMusic", Mix_VolumeMusic)
				.addFunction("VolumeChunk", Mix_VolumeChunk)
				.addFunction("SetPanning", Mix_SetPanning)
				// image
				.addFunction("InitIMG", IMG_Init)
				.addFunction("QuitIMG", IMG_Quit)
				.addFunction("LoadImage", IMG_Load)
				.addFunction("LoadTexture", IMG_LoadTexture)
				.addFunction("SaveJPG", IMG_SaveJPG)
				.addFunction("SavePNG", IMG_SavePNG)
				// gfx
				.addFunction("ThickLineRGBA", thickLineRGBA)
				.addFunction("FilledEllipseRGBA", filledEllipseRGBA)
				.addFunction("AAEllipseRGBA", aaellipseRGBA)
				.addFunction("FilledTrigonRGBA", filledTrigonRGBA)
				.addFunction("AATrigonRGBA", aatrigonRGBA)
				.addFunction("FilledPolygonRGBA",  +[](SDL_Renderer* renderer, const PointList& list, Uint8 r, Uint8 g, Uint8 b, Uint8 a)
					{
						std::vector<Sint16> x_list(list.list.size());
						std::vector<Sint16> y_list(list.list.size());
						for (size_t i = 0; i < list.list.size(); ++i)
							x_list[i] = list.list[i].x, y_list[i] = list.list[i].y;
						filledPolygonRGBA(renderer, x_list.data(), y_list.data(), (int)list.list.size(), r, g, b, a);
					})
				.addFunction("AAPolygonRGBA",  +[](SDL_Renderer* renderer, const PointList& list, Uint8 r, Uint8 g, Uint8 b, Uint8 a)
					{
						std::vector<Sint16> x_list(list.list.size());
						std::vector<Sint16> y_list(list.list.size());
						for (size_t i = 0; i < list.list.size(); ++i)
							x_list[i] = list.list[i].x, y_list[i] = list.list[i].y;
						aapolygonRGBA(renderer, x_list.data(), y_list.data(), (int)list.list.size(), r, g, b, a);
					})
				// ttf
				.addFunction("InitTTF", TTF_Init)
				.addFunction("QuitTTF", TTF_Quit)
				.addFunction("OpenFont", TTF_OpenFont)
				.addFunction("CloseFont", TTF_CloseFont)
				.addFunction("RenderUTF8Blended", TTF_RenderUTF8_Blended)
				.addFunction("RenderUTF8BlendedWrapped", TTF_RenderUTF8_Blended_Wrapped)
				// net
				.addFunction("InitNET", SDLNet_Init)
				.addFunction("ResolveHost", SDLNet_ResolveHost)
				.addFunction("TCP_Open", SDLNet_TCP_Open)
				.addFunction("TCP_Close", SDLNet_TCP_Close)
				.addFunction("AllocSocketSet", SDLNet_AllocSocketSet)
				.addFunction("FreeSocketSet", SDLNet_FreeSocketSet)
				.addFunction("TCP_AddSocket", SDLNet_TCP_AddSocket)
				.addFunction("DelSocket", SDLNet_DelSocket)
				.addFunction("TCP_Accept", SDLNet_TCP_Accept)
				.addFunction("CheckSockets", SDLNet_CheckSockets)
				.addFunction("SocketReady", +[](TCPsocket socket) { return SDLNet_SocketReady(socket); }, +[](UDPsocket socket) { return SDLNet_SocketReady(socket); })
				.addFunction("AllocNetRecvBuffer", +[](NetRecvBuffer* buffer, size_t len) 
					{
						buffer->len = len;
						buffer->data = (char*)malloc(sizeof(char) * len);
						if (buffer->data) memset(buffer->data, 0, len); 
					})
				.addFunction("FreeNetRecvBuffer", +[](NetRecvBuffer* buffer) { free(buffer->data); buffer->data = nullptr; })
				.addFunction("TCP_Recv", +[](TCPsocket socket, NetRecvBuffer* buffer) { return SDLNet_TCP_Recv(socket, buffer->data, (int)buffer->len); })
				.addFunction("TCP_Send", +[](TCPsocket socket, const std::string data) { return SDLNet_TCP_Send(socket, data.data(), (int)data.size()); })
			.endNamespace()
		.endNamespace();
}
