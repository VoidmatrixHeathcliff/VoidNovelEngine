#pragma once

#include <mutex>
#include <string>

#include <wrl/client.h>

struct ID3D11Device;
struct ID3D11DeviceContext;
struct IMFDXGIDeviceManager;
struct IMFMediaEngineClassFactory;

namespace vne::video
{
	class VideoWmfService
	{
	public:
		static VideoWmfService& Instance();

		bool IsSupported();
		const std::string& GetCapabilityMessage();

		ID3D11Device* GetDevice();
		ID3D11DeviceContext* GetContext();
		IMFDXGIDeviceManager* GetDxgiManager();
		IMFMediaEngineClassFactory* GetClassFactory();

	private:
		VideoWmfService() = default;
		~VideoWmfService();
		VideoWmfService(const VideoWmfService&) = delete;
		VideoWmfService& operator=(const VideoWmfService&) = delete;

		bool EnsureInitialized();
		void Reset();
		void SetFailureMessage(const char* prefix, HRESULT hr);

		std::mutex mutex_;
		bool initAttempted_ = false;
		bool supported_ = false;
		bool coInitialized_ = false;
		bool mfStarted_ = false;
		UINT dxgiResetToken_ = 0;
		std::string capabilityMessage_ = "video service has not been initialized";
		Microsoft::WRL::ComPtr<ID3D11Device> device_;
		Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
		Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> dxgiManager_;
		Microsoft::WRL::ComPtr<IMFMediaEngineClassFactory> classFactory_;
	};
}
