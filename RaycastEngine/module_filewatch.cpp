#include "module_filewatch.h"

#include <LuaBridge.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#if defined(_WIN64)
#include <efsw.h>
#endif

namespace
{
	struct FileWatchEventData
	{
		std::string action;
		std::string dir;
		std::string filename;
		std::string old_filename;
		std::string path;
		std::string old_path;
		std::int64_t timestamp_ms = 0;
	};

	std::int64_t CurrentTimestampMs()
	{
		using namespace std::chrono;
		return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
	}

	std::string NormalizeSlashes(std::string value)
	{
		std::replace(value.begin(), value.end(), '\\', '/');
		size_t pos = 0;
		while ((pos = value.find("//", pos)) != std::string::npos)
			value.erase(pos, 1);
		return value;
	}

	std::string JoinPath(std::string dir, const std::string& name)
	{
		dir = NormalizeSlashes(std::move(dir));
		std::string fileName = NormalizeSlashes(name);
		if (fileName.empty())
			return dir;
		if (dir.empty())
			return fileName;
		if (dir.back() != '/')
			dir.push_back('/');
		if (!fileName.empty() && fileName.front() == '/')
			fileName.erase(fileName.begin());
		return dir + fileName;
	}

#if defined(_WIN64)
	std::string LastEfswError()
	{
		const char* error = efsw_getlasterror();
		return (error && *error) ? std::string(error) : "file watcher error";
	}

	const char* ActionToString(efsw_action action)
	{
		switch (action)
		{
		case EFSW_ADD:
			return "add";
		case EFSW_DELETE:
			return "delete";
		case EFSW_MODIFIED:
			return "modified";
		case EFSW_MOVED:
			return "moved";
		default:
			return "unknown";
		}
	}
#endif

	class LuaFileWatcher
	{
	public:
		LuaFileWatcher() : LuaFileWatcher(false) {}

		explicit LuaFileWatcher(bool genericMode)
		{
#if defined(_WIN64)
			watcher_ = efsw_create(genericMode ? 1 : 0);
			if (watcher_ == nullptr)
				lastError_ = LastEfswError();
#else
			(void)genericMode;
			lastError_ = "file watching is not supported on this target";
#endif
		}

		~LuaFileWatcher()
		{
			dispose();
		}

		long addWatch(const std::string& directory, bool recursive)
		{
#if defined(_WIN64)
			if (disposed_)
			{
				lastError_ = "watcher has been disposed";
				return -1;
			}
			if (watcher_ == nullptr)
			{
				if (lastError_.empty())
					lastError_ = "watcher has not been initialized";
				return -1;
			}

			efsw_clearlasterror();
			long watchId = efsw_addwatch(watcher_, directory.c_str(), &LuaFileWatcher::HandleFileAction, recursive ? 1 : 0, this);
			if (watchId < 0)
			{
				lastError_ = LastEfswError();
				return watchId;
			}

			watchIds_.push_back(watchId);
			return watchId;
#else
			(void)directory;
			(void)recursive;
			lastError_ = "file watching is not supported on this target";
			return -1;
#endif
		}

		bool start()
		{
#if defined(_WIN64)
			if (disposed_)
			{
				lastError_ = "watcher has been disposed";
				return false;
			}
			if (watcher_ == nullptr)
			{
				if (lastError_.empty())
					lastError_ = "watcher has not been initialized";
				return false;
			}
			if (started_)
				return true;

			efsw_clearlasterror();
			efsw_watch(watcher_);
			started_ = true;
			return true;
#else
			lastError_ = "file watching is not supported on this target";
			return false;
#endif
		}

		luabridge::LuaRef poll(lua_State* L)
		{
			std::vector<FileWatchEventData> eventList;
			{
				std::lock_guard<std::mutex> lock(mutex_);
				eventList.swap(pendingEvents_);
			}

			lua_createtable(L, static_cast<int>(eventList.size()), 0);
			int index = 1;
			for (const auto& eventData : eventList)
			{
				lua_createtable(L, 0, 7);

				lua_pushstring(L, eventData.action.c_str());
				lua_setfield(L, -2, "action");

				lua_pushstring(L, eventData.dir.c_str());
				lua_setfield(L, -2, "dir");

				lua_pushstring(L, eventData.filename.c_str());
				lua_setfield(L, -2, "filename");

				lua_pushstring(L, eventData.old_filename.c_str());
				lua_setfield(L, -2, "old_filename");

				lua_pushstring(L, eventData.path.c_str());
				lua_setfield(L, -2, "path");

				lua_pushstring(L, eventData.old_path.c_str());
				lua_setfield(L, -2, "old_path");

				lua_pushinteger(L, static_cast<lua_Integer>(eventData.timestamp_ms));
				lua_setfield(L, -2, "timestamp_ms");

				lua_rawseti(L, -2, index);
				++index;
			}

			return luabridge::LuaRef::fromStack(L, -1);
		}

		void dispose()
		{
			if (disposed_)
				return;

			disposed_ = true;
			started_ = false;
			{
				std::lock_guard<std::mutex> lock(mutex_);
				pendingEvents_.clear();
			}

#if defined(_WIN64)
			if (watcher_ != nullptr)
			{
				efsw_release(watcher_);
				watcher_ = nullptr;
			}
			watchIds_.clear();
#endif
		}

		bool isValid() const
		{
#if defined(_WIN64)
			return !disposed_ && watcher_ != nullptr;
#else
			return false;
#endif
		}

		bool isStarted() const
		{
			return started_;
		}

		const std::string& lastError() const
		{
			return lastError_;
		}

	private:
#if defined(_WIN64)
		static void HandleFileAction(efsw_watcher watcher, efsw_watchid watchid, const char* dir,
			const char* filename, efsw_action action, const char* oldFilename, void* param)
		{
			(void)watcher;
			LuaFileWatcher* self = static_cast<LuaFileWatcher*>(param);
			if (self == nullptr)
				return;
			self->enqueueEvent(watchid, dir ? dir : "", filename ? filename : "", action, oldFilename ? oldFilename : "");
		}

		void enqueueEvent(long watchid, const std::string& dir, const std::string& filename, efsw_action action, const std::string& oldFilename)
		{
			(void)watchid;
			if (disposed_)
				return;

			FileWatchEventData eventData;
			eventData.action = ActionToString(action);
			eventData.dir = NormalizeSlashes(dir);
			eventData.filename = NormalizeSlashes(filename);
			eventData.old_filename = NormalizeSlashes(oldFilename);
			eventData.path = JoinPath(eventData.dir, eventData.filename);
			eventData.old_path = JoinPath(eventData.dir, eventData.old_filename);
			eventData.timestamp_ms = CurrentTimestampMs();

			std::lock_guard<std::mutex> lock(mutex_);
			pendingEvents_.push_back(std::move(eventData));
		}

	private:
		efsw_watcher watcher_ = nullptr;
		std::vector<long> watchIds_;
#endif
		std::mutex mutex_;
		std::vector<FileWatchEventData> pendingEvents_;
		std::string lastError_;
		bool started_ = false;
		bool disposed_ = false;
	};
}

void init_filewatch_module(lua_State* L)
{
	luabridge::getGlobalNamespace(L)
		.beginNamespace("Engine")
			.beginNamespace("FileWatcher")
				.beginClass<LuaFileWatcher>("Watcher")
					.addConstructor<void()>()
					.addConstructor<void(bool)>()
					.addProperty("valid", &LuaFileWatcher::isValid)
					.addProperty("started", &LuaFileWatcher::isStarted)
					.addProperty("last_error", &LuaFileWatcher::lastError)
					.addFunction("add_watch", &LuaFileWatcher::addWatch)
					.addFunction("start", &LuaFileWatcher::start)
					.addFunction("poll", &LuaFileWatcher::poll)
					.addFunction("dispose", &LuaFileWatcher::dispose)
				.endClass()
			.endNamespace()
		.endNamespace();
}
