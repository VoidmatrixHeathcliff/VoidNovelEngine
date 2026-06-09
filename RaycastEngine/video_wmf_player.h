#pragma once

#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <wrl/client.h>

struct ID3D11Texture2D;
struct ID3D11RenderTargetView;
struct IMFMediaEngine;
struct IMFMediaEngineNotify;

extern "C"
{
	typedef struct Texture
	{
		unsigned int id;
		int width;
		int height;
		int mipmaps;
		int format;
	} Texture;

	void UpdateTexture(Texture texture, const void* pixels);
}

namespace vne::video
{
	class MediaEngineNotify;

	enum class VideoSessionState
	{
		Idle,
		Opening,
		Ready,
		Playing,
		Paused,
		Ended,
		Error,
		Closed,
	};

	class VideoWmfPlayer
	{
	public:
		static std::shared_ptr<VideoWmfPlayer> Create(const std::string& utf8Path);

		~VideoWmfPlayer();

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
		VideoSessionState GetState() const;

	private:
		friend class MediaEngineNotify;

		VideoWmfPlayer() = default;

		bool Open(const std::string& utf8Path);
		void HandleEvent(DWORD eventCode, DWORD_PTR param1, DWORD param2);
		void CleanupAfterOpenFailure();
		void SyncPlaybackState();
		bool EnsureFrameResources(int width, int height);
		bool UploadFrameToTexture(Texture& texture);
		void SetErrorMessage(const std::string& message);
		void SetErrorFromHRESULT(const char* prefix, HRESULT hr);

		mutable std::mutex mutex_;
		std::string sourcePath_;
		std::string errorMessage_;
		VideoSessionState state_ = VideoSessionState::Idle;
		int width_ = 0;
		int height_ = 0;
		double durationSeconds_ = 0.0;
		bool hasVideo_ = false;
		bool loop_ = false;
		bool freshFrameAvailable_ = false;
		bool needsTextureRefresh_ = false;
		bool hasLastPresentationTime_ = false;
		LONGLONG lastPresentationTime_ = 0;
		bool metadataDirty_ = false;
		bool stateDirty_ = false;
		bool pendingErrorQuery_ = false;
		bool playRequested_ = false;

		Microsoft::WRL::ComPtr<IMFMediaEngineNotify> notify_;
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine_;
		Microsoft::WRL::ComPtr<ID3D11Texture2D> renderTexture_;
		Microsoft::WRL::ComPtr<ID3D11Texture2D> stagingTexture_;
		Microsoft::WRL::ComPtr<ID3D11RenderTargetView> renderTargetView_;
		std::vector<unsigned char> rgbaBuffer_;
	};
}
