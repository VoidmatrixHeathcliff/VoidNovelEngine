#include "video_wmf_player.h"

#include "video_common.h"
#include "video_wmf_service.h"

#include <algorithm>

#include <AudioSessionTypes.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfmediaengine.h>
#include <d3d11.h>
#include <oleauto.h>

namespace vne::video
{
	class MediaEngineNotify final : public IMFMediaEngineNotify
	{
	public:
		explicit MediaEngineNotify(VideoWmfPlayer* owner) : owner_(owner) {}

		STDMETHODIMP QueryInterface(REFIID riid, void** object) override
		{
			if (object == nullptr)
				return E_POINTER;
			if (riid == IID_IUnknown || riid == IID_IMFMediaEngineNotify)
			{
				*object = static_cast<IMFMediaEngineNotify*>(this);
				AddRef();
				return S_OK;
			}
			*object = nullptr;
			return E_NOINTERFACE;
		}

		STDMETHODIMP_(ULONG) AddRef() override
		{
			return static_cast<ULONG>(InterlockedIncrement(&refCount_));
		}

		STDMETHODIMP_(ULONG) Release() override
		{
			ULONG result = static_cast<ULONG>(InterlockedDecrement(&refCount_));
			if (result == 0)
				delete this;
			return result;
		}

		STDMETHODIMP EventNotify(DWORD eventCode, DWORD_PTR param1, DWORD param2) override
		{
			if (owner_ != nullptr)
				owner_->HandleEvent(eventCode, param1, param2);
			return S_OK;
		}

	private:
		~MediaEngineNotify() = default;

		volatile long refCount_ = 1;
		VideoWmfPlayer* owner_ = nullptr;
	};

	namespace
	{
		const MFVideoNormalizedRect kFullSourceRect = { 0.0f, 0.0f, 1.0f, 1.0f };
		const MFARGB kBlackBorder = { 255, 0, 0, 0 };
	}

	std::shared_ptr<VideoWmfPlayer> VideoWmfPlayer::Create(const std::string& utf8Path)
	{
		std::shared_ptr<VideoWmfPlayer> player(new VideoWmfPlayer());
		player->Open(utf8Path);
		return player;
	}

	VideoWmfPlayer::~VideoWmfPlayer()
	{
		Close();
	}

	bool VideoWmfPlayer::Open(const std::string& utf8Path)
	{
		VideoWmfService& service = VideoWmfService::Instance();
		if (!service.IsSupported())
		{
			SetErrorMessage(service.GetCapabilityMessage());
			return false;
		}

		Microsoft::WRL::ComPtr<IMFAttributes> attributes;
		HRESULT hr = MFCreateAttributes(attributes.GetAddressOf(), 6);
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to create MediaEngine attributes", hr);
			return false;
		}

		Microsoft::WRL::ComPtr<IMFMediaEngineNotify> notify(new MediaEngineNotify(this));
		notify_ = notify;

		hr = attributes->SetUnknown(MF_MEDIA_ENGINE_CALLBACK, notify_.Get());
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to bind MediaEngine callback", hr);
			return false;
		}

		hr = attributes->SetUnknown(MF_MEDIA_ENGINE_DXGI_MANAGER, service.GetDxgiManager());
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to bind DXGI device manager", hr);
			return false;
		}

		hr = attributes->SetUINT32(MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM);
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to set video output format", hr);
			return false;
		}

		hr = attributes->SetUINT32(MF_MEDIA_ENGINE_AUDIO_CATEGORY, AudioCategory_GameMedia);
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to set media audio category", hr);
			return false;
		}

		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		hr = service.GetClassFactory()->CreateInstance(0, attributes.Get(), engine.GetAddressOf());
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to create IMFMediaEngine instance", hr);
			return false;
		}

		{
			std::lock_guard<std::mutex> lock(mutex_);
			sourcePath_ = utf8Path;
			engine_ = engine;
			state_ = VideoSessionState::Opening;
			freshFrameAvailable_ = false;
			needsTextureRefresh_ = false;
			errorMessage_.clear();
			durationSeconds_ = 0.0;
			width_ = 0;
			height_ = 0;
			hasVideo_ = false;
			hasLastPresentationTime_ = false;
			lastPresentationTime_ = 0;
			metadataDirty_ = true;
			stateDirty_ = true;
			pendingErrorQuery_ = false;
			playRequested_ = false;
		}

		std::wstring fileUrl = BuildFileUrlFromUtf8Path(utf8Path);
		if (fileUrl.empty())
		{
			SetErrorMessage("failed to build video file URL");
			CleanupAfterOpenFailure();
			return false;
		}

		BSTR source = SysAllocString(fileUrl.c_str());
		if (source == nullptr)
		{
			SetErrorMessage("failed to allocate video source string");
			CleanupAfterOpenFailure();
			return false;
		}

		hr = engine->SetSource(source);
		SysFreeString(source);
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to set media source", hr);
			CleanupAfterOpenFailure();
			return false;
		}

		hr = engine->Load();
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to load media source", hr);
			CleanupAfterOpenFailure();
			return false;
		}
		return true;
	}

	void VideoWmfPlayer::SetErrorMessage(const std::string& message)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		state_ = VideoSessionState::Error;
		errorMessage_ = message;
	}

	void VideoWmfPlayer::SetErrorFromHRESULT(const char* prefix, HRESULT hr)
	{
		std::string message = prefix ? prefix : "video playback failed";
		message += ": ";
		message += HrToUtf8String(hr);
		SetErrorMessage(message);
	}

	void VideoWmfPlayer::CleanupAfterOpenFailure()
	{
		std::lock_guard<std::mutex> lock(mutex_);
		engine_.Reset();
		notify_.Reset();
		renderTargetView_.Reset();
		renderTexture_.Reset();
		stagingTexture_.Reset();
		rgbaBuffer_.clear();
		hasVideo_ = false;
		width_ = 0;
		height_ = 0;
		durationSeconds_ = 0.0;
		freshFrameAvailable_ = false;
		needsTextureRefresh_ = false;
		hasLastPresentationTime_ = false;
		lastPresentationTime_ = 0;
		metadataDirty_ = false;
		stateDirty_ = false;
		pendingErrorQuery_ = false;
		playRequested_ = false;
	}

	void VideoWmfPlayer::HandleEvent(DWORD eventCode, DWORD_PTR param1, DWORD param2)
	{
		std::lock_guard<std::mutex> lock(mutex_);
		switch (eventCode)
		{
		case MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA:
			metadataDirty_ = true;
			stateDirty_ = true;
			needsTextureRefresh_ = true;
			break;
		case MF_MEDIA_ENGINE_EVENT_CANPLAY:
			stateDirty_ = true;
			if (state_ != VideoSessionState::Closed && state_ != VideoSessionState::Error)
				state_ = VideoSessionState::Ready;
			needsTextureRefresh_ = true;
			break;
		case MF_MEDIA_ENGINE_EVENT_PLAYING:
			stateDirty_ = true;
			if (state_ != VideoSessionState::Closed && state_ != VideoSessionState::Error)
				state_ = VideoSessionState::Playing;
			needsTextureRefresh_ = true;
			break;
		case MF_MEDIA_ENGINE_EVENT_PAUSE:
			stateDirty_ = true;
			if (state_ != VideoSessionState::Closed && state_ != VideoSessionState::Error && state_ != VideoSessionState::Ended)
				state_ = VideoSessionState::Paused;
			needsTextureRefresh_ = true;
			break;
		case MF_MEDIA_ENGINE_EVENT_SEEKED:
			metadataDirty_ = true;
			stateDirty_ = true;
			needsTextureRefresh_ = true;
			freshFrameAvailable_ = true;
			hasLastPresentationTime_ = false;
			lastPresentationTime_ = 0;
			break;
		case MF_MEDIA_ENGINE_EVENT_ENDED:
			stateDirty_ = true;
			state_ = VideoSessionState::Ended;
			needsTextureRefresh_ = true;
			freshFrameAvailable_ = true;
			break;
		case MF_MEDIA_ENGINE_EVENT_ERROR:
			stateDirty_ = true;
			pendingErrorQuery_ = true;
			errorMessage_ = "WMF playback error";
			if (param1 != 0 || param2 != 0)
			{
				errorMessage_ += " (event params: ";
				errorMessage_ += std::to_string(static_cast<unsigned long long>(param1));
				errorMessage_ += " / ";
				errorMessage_ += std::to_string(static_cast<unsigned long long>(param2));
				errorMessage_ += ")";
			}
			break;
		default:
			break;
		}
	}

	void VideoWmfPlayer::Play()
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			engine = engine_;
			playRequested_ = true;
		}
		if (engine != nullptr)
			engine->Play();
	}

	void VideoWmfPlayer::Pause()
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			engine = engine_;
			playRequested_ = false;
		}
		if (engine != nullptr)
			engine->Pause();
	}

	void VideoWmfPlayer::Stop()
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			engine = engine_;
			needsTextureRefresh_ = true;
			freshFrameAvailable_ = true;
			hasLastPresentationTime_ = false;
			lastPresentationTime_ = 0;
			playRequested_ = false;
			stateDirty_ = true;
		}
		if (engine != nullptr)
		{
			engine->Pause();
			engine->SetCurrentTime(0.0);
		}
	}

	void VideoWmfPlayer::Close()
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (state_ == VideoSessionState::Closed)
				return;
			state_ = VideoSessionState::Closed;
			freshFrameAvailable_ = false;
			needsTextureRefresh_ = false;
			engine = engine_;
			renderTargetView_.Reset();
			renderTexture_.Reset();
			stagingTexture_.Reset();
			engine_.Reset();
			notify_.Reset();
			rgbaBuffer_.clear();
			hasLastPresentationTime_ = false;
			lastPresentationTime_ = 0;
			metadataDirty_ = false;
			stateDirty_ = false;
			pendingErrorQuery_ = false;
			playRequested_ = false;
		}

		if (engine != nullptr)
		{
			engine->Pause();
			engine->Shutdown();
		}
	}

	void VideoWmfPlayer::SeekSeconds(double seconds)
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			engine = engine_;
			needsTextureRefresh_ = true;
			freshFrameAvailable_ = true;
			hasLastPresentationTime_ = false;
			lastPresentationTime_ = 0;
			stateDirty_ = true;
		}
		if (engine != nullptr)
			engine->SetCurrentTime((std::max)(0.0, seconds));
	}

	void VideoWmfPlayer::SetLoop(bool flag)
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			loop_ = flag;
			engine = engine_;
		}
		if (engine != nullptr)
			engine->SetLoop(flag);
	}

	void VideoWmfPlayer::SetVolume(float volume)
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			engine = engine_;
		}
		if (engine != nullptr)
			engine->SetVolume(std::clamp(static_cast<double>(volume), 0.0, 1.0));
	}

	void VideoWmfPlayer::SyncPlaybackState()
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		VideoSessionState currentState = VideoSessionState::Idle;
		bool metadataDirty = false;
		bool pendingErrorQuery = false;
		bool playRequested = false;
		bool currentHasVideo = false;
		int currentWidth = 0;
		int currentHeight = 0;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (state_ == VideoSessionState::Closed || state_ == VideoSessionState::Error)
				return;
			engine = engine_;
			currentState = state_;
			metadataDirty = metadataDirty_;
			pendingErrorQuery = pendingErrorQuery_;
			playRequested = playRequested_;
			currentHasVideo = hasVideo_;
			currentWidth = width_;
			currentHeight = height_;
		}

		if (engine == nullptr)
			return;

		const bool ended = engine->IsEnded() == TRUE;
		const UINT readyState = engine->GetReadyState();
		if (playRequested && !ended && engine->IsPaused() == TRUE && readyState >= MF_MEDIA_ENGINE_READY_HAVE_CURRENT_DATA)
			engine->Play();

		const bool canReadMetadata = readyState >= MF_MEDIA_ENGINE_READY_HAVE_METADATA;
		const bool needsMetadataRefresh = canReadMetadata
			&& (metadataDirty
				|| currentState == VideoSessionState::Opening
				|| !currentHasVideo
				|| currentWidth <= 0
				|| currentHeight <= 0);
		bool hasVideo = false;
		int width = 0;
		int height = 0;
		double durationSeconds = 0.0;
		if (needsMetadataRefresh)
		{
			hasVideo = engine->HasVideo() == TRUE;
			if (hasVideo)
			{
				DWORD nativeWidth = 0;
				DWORD nativeHeight = 0;
				if (SUCCEEDED(engine->GetNativeVideoSize(&nativeWidth, &nativeHeight)))
				{
					width = static_cast<int>(nativeWidth);
					height = static_cast<int>(nativeHeight);
				}
			}
			durationSeconds = engine->GetDuration();
		}

		bool hasError = false;
		std::string errorMessage;
		if (pendingErrorQuery)
		{
			Microsoft::WRL::ComPtr<IMFMediaError> mediaError;
			if (SUCCEEDED(engine->GetError(mediaError.GetAddressOf())) && mediaError != nullptr)
			{
				hasError = true;
				errorMessage = "WMF playback error (code=";
				errorMessage += std::to_string(static_cast<unsigned int>(mediaError->GetErrorCode()));
				const HRESULT extendedError = mediaError->GetExtendedErrorCode();
				if (extendedError != S_OK)
				{
					errorMessage += ", hr=";
					errorMessage += HrToUtf8String(extendedError);
				}
				errorMessage += ")";
			}
		}

		const bool paused = engine->IsPaused() == TRUE;
		VideoSessionState nextState = currentState;
		if (hasError)
		{
			nextState = VideoSessionState::Error;
		}
		else if (ended)
		{
			nextState = VideoSessionState::Ended;
		}
		else if (readyState >= MF_MEDIA_ENGINE_READY_HAVE_CURRENT_DATA)
		{
			nextState = paused ? (playRequested ? VideoSessionState::Ready : VideoSessionState::Paused) : VideoSessionState::Playing;
		}
		else if (readyState >= MF_MEDIA_ENGINE_READY_HAVE_METADATA)
		{
			nextState = VideoSessionState::Ready;
		}
		else
		{
			nextState = VideoSessionState::Opening;
		}

		std::lock_guard<std::mutex> lock(mutex_);
		if (state_ == VideoSessionState::Closed)
			return;
		if (needsMetadataRefresh)
		{
			hasVideo_ = hasVideo;
			if (width > 0)
				width_ = width;
			if (height > 0)
				height_ = height;
			if (durationSeconds >= 0.0)
				durationSeconds_ = durationSeconds;
			metadataDirty_ = hasVideo && width > 0 && height > 0 ? false : metadataDirty_;
		}
		if (pendingErrorQuery)
		{
			pendingErrorQuery_ = false;
			if (hasError)
			{
				state_ = VideoSessionState::Error;
				errorMessage_ = errorMessage;
				return;
			}
		}
		if (stateDirty_ || state_ == VideoSessionState::Opening)
		{
			state_ = nextState;
			stateDirty_ = false;
		}
	}

	void VideoWmfPlayer::Tick()
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (state_ == VideoSessionState::Closed || state_ == VideoSessionState::Error)
				return;
			engine = engine_;
		}

		if (engine == nullptr)
			return;

		SyncPlaybackState();

		bool hasVideo = false;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (state_ == VideoSessionState::Closed || state_ == VideoSessionState::Error)
				return;
			hasVideo = hasVideo_;
		}

		if (!hasVideo)
			return;

		LONGLONG presentationTime = 0;
		HRESULT hr = engine->OnVideoStreamTick(&presentationTime);
		if (hr == S_OK)
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (!hasLastPresentationTime_ || lastPresentationTime_ != presentationTime)
			{
				hasLastPresentationTime_ = true;
				lastPresentationTime_ = presentationTime;
				freshFrameAvailable_ = true;
			}
		}
	}

	bool VideoWmfPlayer::EnsureFrameResources(int width, int height)
	{
		if (width <= 0 || height <= 0)
			return false;

		ID3D11Device* device = VideoWmfService::Instance().GetDevice();
		if (device == nullptr)
			return false;

		if (renderTexture_ != nullptr && stagingTexture_ != nullptr && renderTargetView_ != nullptr)
		{
			D3D11_TEXTURE2D_DESC desc = {};
			renderTexture_->GetDesc(&desc);
			if (desc.Width == static_cast<UINT>(width) && desc.Height == static_cast<UINT>(height))
				return true;
		}

		renderTargetView_.Reset();
		renderTexture_.Reset();
		stagingTexture_.Reset();

		D3D11_TEXTURE2D_DESC renderDesc = {};
		renderDesc.Width = static_cast<UINT>(width);
		renderDesc.Height = static_cast<UINT>(height);
		renderDesc.MipLevels = 1;
		renderDesc.ArraySize = 1;
		renderDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
		renderDesc.SampleDesc.Count = 1;
		renderDesc.Usage = D3D11_USAGE_DEFAULT;
		renderDesc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;

		HRESULT hr = device->CreateTexture2D(&renderDesc, nullptr, renderTexture_.GetAddressOf());
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to create video render texture", hr);
			return false;
		}

		hr = device->CreateRenderTargetView(renderTexture_.Get(), nullptr, renderTargetView_.GetAddressOf());
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to create video render target view", hr);
			return false;
		}

		D3D11_TEXTURE2D_DESC stagingDesc = renderDesc;
		stagingDesc.Usage = D3D11_USAGE_STAGING;
		stagingDesc.BindFlags = 0;
		stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
		stagingDesc.MiscFlags = 0;

		hr = device->CreateTexture2D(&stagingDesc, nullptr, stagingTexture_.GetAddressOf());
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to create video staging texture", hr);
			return false;
		}

		rgbaBuffer_.assign(static_cast<size_t>(width) * static_cast<size_t>(height) * 4, 0);
		return true;
	}

	bool VideoWmfPlayer::UploadFrameToTexture(Texture& texture)
	{
		Microsoft::WRL::ComPtr<IMFMediaEngine> engine;
		int width = 0;
		int height = 0;
		bool needsRefresh = false;
		{
			std::lock_guard<std::mutex> lock(mutex_);
			if (state_ == VideoSessionState::Closed || state_ == VideoSessionState::Error || !hasVideo_)
				return false;
			engine = engine_;
			width = width_;
			height = height_;
			needsRefresh = freshFrameAvailable_ || needsTextureRefresh_;
		}

		if (engine == nullptr || !needsRefresh || texture.id == 0 || width <= 0 || height <= 0)
			return false;

		if (!EnsureFrameResources(width, height))
			return false;

		RECT dstRect = { 0, 0, width, height };
		HRESULT hr = engine->TransferVideoFrame(renderTexture_.Get(), &kFullSourceRect, &dstRect, &kBlackBorder);
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to transfer video frame", hr);
			return false;
		}

		ID3D11DeviceContext* context = VideoWmfService::Instance().GetContext();
		if (context == nullptr)
		{
			SetErrorMessage("failed to get video render context");
			return false;
		}

		context->CopyResource(stagingTexture_.Get(), renderTexture_.Get());

		D3D11_MAPPED_SUBRESOURCE mapped = {};
		hr = context->Map(stagingTexture_.Get(), 0, D3D11_MAP_READ, 0, &mapped);
		if (FAILED(hr))
		{
			SetErrorFromHRESULT("failed to read back video frame", hr);
			return false;
		}

		const size_t dstStride = static_cast<size_t>(width) * 4;
		unsigned char* dst = rgbaBuffer_.data();
		const auto* src = static_cast<const unsigned char*>(mapped.pData);
		for (int y = 0; y < height; ++y)
		{
			const unsigned char* srcRow = src + static_cast<size_t>(y) * mapped.RowPitch;
			unsigned char* dstRow = dst + static_cast<size_t>(y) * dstStride;
			for (int x = 0; x < width; ++x)
			{
				const size_t srcIndex = static_cast<size_t>(x) * 4;
				const size_t dstIndex = static_cast<size_t>(x) * 4;
				dstRow[dstIndex + 0] = srcRow[srcIndex + 2];
				dstRow[dstIndex + 1] = srcRow[srcIndex + 1];
				dstRow[dstIndex + 2] = srcRow[srcIndex + 0];
				dstRow[dstIndex + 3] = srcRow[srcIndex + 3];
			}
		}
		context->Unmap(stagingTexture_.Get(), 0);

		::UpdateTexture(texture, rgbaBuffer_.data());

		{
			std::lock_guard<std::mutex> lock(mutex_);
			freshFrameAvailable_ = false;
			needsTextureRefresh_ = false;
		}
		return true;
	}

	bool VideoWmfPlayer::UpdateTexture(Texture& texture)
	{
		return UploadFrameToTexture(texture);
	}

	bool VideoWmfPlayer::IsReady() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return state_ == VideoSessionState::Ready
			|| state_ == VideoSessionState::Playing
			|| state_ == VideoSessionState::Paused
			|| state_ == VideoSessionState::Ended;
	}

	bool VideoWmfPlayer::IsPlaying() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return state_ == VideoSessionState::Playing;
	}

	bool VideoWmfPlayer::IsEnded() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return state_ == VideoSessionState::Ended;
	}

	bool VideoWmfPlayer::HasError() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return state_ == VideoSessionState::Error;
	}

	bool VideoWmfPlayer::HasFreshFrame() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return freshFrameAvailable_ || needsTextureRefresh_;
	}

	bool VideoWmfPlayer::HasVideo() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return hasVideo_;
	}

	std::string VideoWmfPlayer::GetErrorMessage() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return errorMessage_;
	}

	int VideoWmfPlayer::GetWidth() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return width_;
	}

	int VideoWmfPlayer::GetHeight() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return height_;
	}

	double VideoWmfPlayer::GetDurationSeconds() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return durationSeconds_;
	}

	VideoSessionState VideoWmfPlayer::GetState() const
	{
		std::lock_guard<std::mutex> lock(mutex_);
		return state_;
	}
}
