#include "video_wmf_service.h"

#include "video_common.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfmediaengine.h>
#include <d3d10_1.h>
#include <d3d11.h>

namespace vne::video
{
	namespace
	{
		constexpr UINT kD3dFlags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
	}

	VideoWmfService& VideoWmfService::Instance()
	{
		static VideoWmfService instance;
		return instance;
	}

	VideoWmfService::~VideoWmfService()
	{
		Reset();
	}

	void VideoWmfService::Reset()
	{
		classFactory_.Reset();
		dxgiManager_.Reset();
		context_.Reset();
		device_.Reset();

		if (mfStarted_)
		{
			MFShutdown();
			mfStarted_ = false;
		}

		if (coInitialized_)
		{
			CoUninitialize();
			coInitialized_ = false;
		}
	}

	void VideoWmfService::SetFailureMessage(const char* prefix, HRESULT hr)
	{
		std::string message = prefix ? prefix : "WMF initialization failed";
		message += ": ";
		message += HrToUtf8String(hr);
		capabilityMessage_ = message;
	}

	bool VideoWmfService::EnsureInitialized()
	{
		std::lock_guard<std::mutex> lock(mutex_);
		if (initAttempted_)
			return supported_;

		initAttempted_ = true;
		capabilityMessage_ = "initializing video service";

		HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
		if (SUCCEEDED(hr))
		{
			coInitialized_ = true;
		}
		else if (hr != RPC_E_CHANGED_MODE)
		{
			SetFailureMessage("failed to initialize COM", hr);
			return false;
		}

		hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
		if (FAILED(hr))
		{
			SetFailureMessage("failed to initialize Media Foundation", hr);
			return false;
		}
		mfStarted_ = true;

		const D3D_FEATURE_LEVEL featureLevels[] =
		{
			D3D_FEATURE_LEVEL_11_1,
			D3D_FEATURE_LEVEL_11_0,
			D3D_FEATURE_LEVEL_10_1,
			D3D_FEATURE_LEVEL_10_0,
		};

		D3D_FEATURE_LEVEL featureLevel = D3D_FEATURE_LEVEL_10_0;
		hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, kD3dFlags,
			featureLevels, ARRAYSIZE(featureLevels), D3D11_SDK_VERSION,
			device_.GetAddressOf(), &featureLevel, context_.GetAddressOf());
		if (FAILED(hr))
		{
			hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, kD3dFlags,
				featureLevels, ARRAYSIZE(featureLevels), D3D11_SDK_VERSION,
				device_.GetAddressOf(), &featureLevel, context_.GetAddressOf());
		}
		if (FAILED(hr))
		{
			SetFailureMessage("failed to create D3D11 device", hr);
			return false;
		}

		Microsoft::WRL::ComPtr<ID3D10Multithread> multithread;
		hr = context_.As(&multithread);
		if (FAILED(hr) || multithread == nullptr)
		{
			SetFailureMessage("failed to acquire D3D multithread guard", FAILED(hr) ? hr : E_NOINTERFACE);
			return false;
		}
		multithread->SetMultithreadProtected(TRUE);

		hr = MFCreateDXGIDeviceManager(&dxgiResetToken_, dxgiManager_.GetAddressOf());
		if (FAILED(hr))
		{
			SetFailureMessage("failed to create DXGI device manager", hr);
			return false;
		}

		hr = dxgiManager_->ResetDevice(device_.Get(), dxgiResetToken_);
		if (FAILED(hr))
		{
			SetFailureMessage("failed to bind DXGI device manager", hr);
			return false;
		}

		hr = CoCreateInstance(CLSID_MFMediaEngineClassFactory, nullptr, CLSCTX_INPROC_SERVER,
			IID_PPV_ARGS(classFactory_.GetAddressOf()));
		if (FAILED(hr))
		{
			SetFailureMessage("failed to create IMFMediaEngineClassFactory", hr);
			return false;
		}

		supported_ = true;
		capabilityMessage_ = "Windows Media Foundation backend is available";
		return true;
	}

	bool VideoWmfService::IsSupported()
	{
		return EnsureInitialized();
	}

	const std::string& VideoWmfService::GetCapabilityMessage()
	{
		EnsureInitialized();
		return capabilityMessage_;
	}

	ID3D11Device* VideoWmfService::GetDevice()
	{
		return EnsureInitialized() ? device_.Get() : nullptr;
	}

	ID3D11DeviceContext* VideoWmfService::GetContext()
	{
		return EnsureInitialized() ? context_.Get() : nullptr;
	}

	IMFDXGIDeviceManager* VideoWmfService::GetDxgiManager()
	{
		return EnsureInitialized() ? dxgiManager_.Get() : nullptr;
	}

	IMFMediaEngineClassFactory* VideoWmfService::GetClassFactory()
	{
		return EnsureInitialized() ? classFactory_.Get() : nullptr;
	}
}
