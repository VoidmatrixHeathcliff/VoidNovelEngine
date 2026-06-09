#pragma once

#include <memory>
#include <string>

#include <lua.hpp>

#include "video_wmf_player.h"

namespace vne::video
{
	class VideoSessionHandle
	{
	public:
		VideoSessionHandle() = default;
		explicit VideoSessionHandle(std::shared_ptr<VideoWmfPlayer> player);

		bool IsValid() const;
		void Play();
		void Pause();
		void Stop();
		void Close();
		void SeekSeconds(double seconds);
		void SetLoop(bool flag);
		void SetVolume(float volume);
		void Tick();

		bool IsReady() const;
		bool IsPlaying() const;
		bool IsEnded() const;
		bool HasError() const;
		bool HasFreshFrame() const;
		bool HasVideo() const;
		bool UpdateTexture(Texture& texture);

		std::string GetErrorMessage() const;
		int GetWidth() const;
		int GetHeight() const;
		double GetDurationSeconds() const;

	private:
		std::shared_ptr<VideoWmfPlayer> player_;
	};
}

void init_video_module(lua_State* L);
