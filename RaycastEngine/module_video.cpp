#include "module_video.h"

#include "video_wmf_service.h"

#include <LuaBridge.h>

namespace vne::video
{
	VideoSessionHandle::VideoSessionHandle(std::shared_ptr<VideoWmfPlayer> player)
		: player_(std::move(player))
	{
	}

	bool VideoSessionHandle::IsValid() const
	{
		return player_ != nullptr;
	}

	void VideoSessionHandle::Play()
	{
		if (player_ != nullptr)
			player_->Play();
	}

	void VideoSessionHandle::Pause()
	{
		if (player_ != nullptr)
			player_->Pause();
	}

	void VideoSessionHandle::Stop()
	{
		if (player_ != nullptr)
			player_->Stop();
	}

	void VideoSessionHandle::Close()
	{
		if (player_ != nullptr)
			player_->Close();
		player_.reset();
	}

	void VideoSessionHandle::SeekSeconds(double seconds)
	{
		if (player_ != nullptr)
			player_->SeekSeconds(seconds);
	}

	void VideoSessionHandle::SetLoop(bool flag)
	{
		if (player_ != nullptr)
			player_->SetLoop(flag);
	}

	void VideoSessionHandle::SetVolume(float volume)
	{
		if (player_ != nullptr)
			player_->SetVolume(volume);
	}

	void VideoSessionHandle::Tick()
	{
		if (player_ != nullptr)
			player_->Tick();
	}

	bool VideoSessionHandle::IsReady() const
	{
		return player_ != nullptr && player_->IsReady();
	}

	bool VideoSessionHandle::IsPlaying() const
	{
		return player_ != nullptr && player_->IsPlaying();
	}

	bool VideoSessionHandle::IsEnded() const
	{
		return player_ != nullptr && player_->IsEnded();
	}

	bool VideoSessionHandle::HasError() const
	{
		return player_ != nullptr && player_->HasError();
	}

	bool VideoSessionHandle::HasFreshFrame() const
	{
		return player_ != nullptr && player_->HasFreshFrame();
	}

	bool VideoSessionHandle::HasVideo() const
	{
		return player_ != nullptr && player_->HasVideo();
	}

	bool VideoSessionHandle::UpdateTexture(Texture& texture)
	{
		return player_ != nullptr && player_->UpdateTexture(texture);
	}

	std::string VideoSessionHandle::GetErrorMessage() const
	{
		return player_ != nullptr ? player_->GetErrorMessage() : std::string();
	}

	int VideoSessionHandle::GetWidth() const
	{
		return player_ != nullptr ? player_->GetWidth() : 0;
	}

	int VideoSessionHandle::GetHeight() const
	{
		return player_ != nullptr ? player_->GetHeight() : 0;
	}

	double VideoSessionHandle::GetDurationSeconds() const
	{
		return player_ != nullptr ? player_->GetDurationSeconds() : 0.0;
	}
}

void init_video_module(lua_State* L)
{
	using namespace vne::video;

	luabridge::getGlobalNamespace(L)
		.beginNamespace("Engine")
			.beginNamespace("Video")
				.beginClass<VideoSessionHandle>("VideoSessionHandle")
					.addConstructor<void(*)()>()
					.addFunction("IsValid", &VideoSessionHandle::IsValid)
					.addFunction("Play", &VideoSessionHandle::Play)
					.addFunction("Pause", &VideoSessionHandle::Pause)
					.addFunction("Stop", &VideoSessionHandle::Stop)
					.addFunction("Close", &VideoSessionHandle::Close)
					.addFunction("SeekSeconds", &VideoSessionHandle::SeekSeconds)
					.addFunction("SetLoop", &VideoSessionHandle::SetLoop)
					.addFunction("SetVolume", &VideoSessionHandle::SetVolume)
					.addFunction("Tick", &VideoSessionHandle::Tick)
					.addFunction("IsReady", &VideoSessionHandle::IsReady)
					.addFunction("IsPlaying", &VideoSessionHandle::IsPlaying)
					.addFunction("IsEnded", &VideoSessionHandle::IsEnded)
					.addFunction("HasError", &VideoSessionHandle::HasError)
					.addFunction("HasFreshFrame", &VideoSessionHandle::HasFreshFrame)
					.addFunction("HasVideo", &VideoSessionHandle::HasVideo)
					.addFunction("UpdateTexture", +[](VideoSessionHandle& session, Texture& texture)
						{
							return session.UpdateTexture(texture);
						})
					.addFunction("GetErrorMessage", &VideoSessionHandle::GetErrorMessage)
					.addFunction("GetWidth", &VideoSessionHandle::GetWidth)
					.addFunction("GetHeight", &VideoSessionHandle::GetHeight)
					.addFunction("GetDurationSeconds", &VideoSessionHandle::GetDurationSeconds)
				.endClass()
				.addFunction("IsSupported", +[]()
					{
						return VideoWmfService::Instance().IsSupported();
					})
				.addFunction("GetCapabilityMessage", +[]()
					{
						return VideoWmfService::Instance().GetCapabilityMessage();
					})
				.addFunction("CreateSession", +[](const std::string& pathUtf8)
					{
						return VideoSessionHandle(VideoWmfPlayer::Create(pathUtf8));
					})
			.endNamespace()
		.endNamespace();
}
