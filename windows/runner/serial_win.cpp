#include "serial_win.h"

#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <string>
#include <thread>
#include <vector>

class SerialWinHost::Impl {
 public:
  void Attach(flutter::BinaryMessenger* messenger) {
    auto codec = &flutter::StandardMethodCodec::GetInstance();
    method_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "rs485_win", codec);
    method_->SetMethodCallHandler(
        [this](const auto& call, auto result) { Handle(call, std::move(result)); });

    events_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
        messenger, "rs485_win/rx", codec);
    events_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
            [this](const flutter::EncodableValue*,
                   std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& sink) {
              sink_ = std::move(sink);
              return nullptr;
            },
            [this](const flutter::EncodableValue*) {
              sink_.reset();
              return nullptr;
            }));
  }

  void Handle(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "list") {
      result->Success(ListPorts());
      return;
    }
    if (call.method_name() == "open") {
      auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      std::string port = "COM7";
      int baud = 19200;
      if (args) {
        auto port_it = args->find(flutter::EncodableValue("port"));
        if (port_it != args->end()) {
          if (auto* value = std::get_if<std::string>(&port_it->second)) {
            port = *value;
          }
        }
        auto baud_it = args->find(flutter::EncodableValue("baud"));
        if (baud_it != args->end()) {
          if (auto* value = std::get_if<int32_t>(&baud_it->second)) {
            baud = *value;
          }
        }
      }
      result->Success(Open(port, baud));
      return;
    }
    if (call.method_name() == "write") {
      auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!args) {
        result->Success(false);
        return;
      }
      auto data_it = args->find(flutter::EncodableValue("data"));
      if (data_it == args->end()) {
        result->Success(false);
        return;
      }
      auto* bytes = std::get_if<std::vector<uint8_t>>(&data_it->second);
      if (!bytes) {
        result->Success(false);
        return;
      }
      result->Success(Write(*bytes));
      return;
    }
    if (call.method_name() == "close") {
      Close();
      result->Success(true);
      return;
    }
    result->NotImplemented();
  }

  flutter::EncodableList ListPorts() {
    flutter::EncodableList ports;
    for (int i = 1; i <= 20; ++i) {
      const std::string name = "COM" + std::to_string(i);
      COMMCONFIG config{};
      DWORD size = sizeof(config);
      if (GetDefaultCommConfigA(name.c_str(), &config, &size)) {
        ports.emplace_back(name);
      }
    }
    return ports;
  }

  bool Open(const std::string& port, int baud) {
    Close();
    const std::wstring path = L"\\\\.\\" + std::wstring(port.begin(), port.end());
    handle_ = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                          OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle_ == INVALID_HANDLE_VALUE) {
      return false;
    }

    DCB dcb{};
    dcb.DCBlength = sizeof(DCB);
    if (!GetCommState(handle_, &dcb)) {
      Close();
      return false;
    }
    dcb.BaudRate = baud;
    dcb.ByteSize = 8;
    dcb.Parity = NOPARITY;
    dcb.StopBits = ONESTOPBIT;
    dcb.fBinary = TRUE;
    dcb.fParity = FALSE;
    dcb.fOutxCtsFlow = FALSE;
    dcb.fOutxDsrFlow = FALSE;
    dcb.fDtrControl = DTR_CONTROL_ENABLE;
    dcb.fRtsControl = RTS_CONTROL_ENABLE;
    dcb.fOutX = FALSE;
    dcb.fInX = FALSE;
    if (!SetCommState(handle_, &dcb)) {
      Close();
      return false;
    }

    COMMTIMEOUTS timeouts{};
    timeouts.ReadIntervalTimeout = 20;
    timeouts.ReadTotalTimeoutConstant = 50;
    timeouts.ReadTotalTimeoutMultiplier = 0;
    timeouts.WriteTotalTimeoutConstant = 50;
    timeouts.WriteTotalTimeoutMultiplier = 10;
    SetCommTimeouts(handle_, &timeouts);
    PurgeComm(handle_, PURGE_RXCLEAR | PURGE_TXCLEAR);

    running_ = true;
    reader_ = std::thread([this] { ReadLoop(); });
    return true;
  }

  bool Write(const std::vector<uint8_t>& data) {
    if (handle_ == INVALID_HANDLE_VALUE || data.empty()) {
      return false;
    }
    DWORD written = 0;
    return WriteFile(handle_, data.data(), static_cast<DWORD>(data.size()),
                     &written, nullptr) == TRUE;
  }

  void Close() {
    running_ = false;
    if (handle_ != INVALID_HANDLE_VALUE) {
      CancelIoEx(handle_, nullptr);
      CloseHandle(handle_);
      handle_ = INVALID_HANDLE_VALUE;
    }
    if (reader_.joinable()) {
      reader_.join();
    }
  }

 private:
  void ReadLoop() {
    std::vector<uint8_t> buffer(512);
    while (running_ && handle_ != INVALID_HANDLE_VALUE) {
      DWORD read = 0;
      const BOOL ok = ReadFile(handle_, buffer.data(),
                               static_cast<DWORD>(buffer.size()), &read, nullptr);
      if (!ok || read == 0) {
        continue;
      }
      std::vector<uint8_t> chunk(buffer.begin(), buffer.begin() + read);
      if (sink_) {
        sink_->Success(flutter::EncodableValue(chunk));
      }
    }
  }

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  HANDLE handle_ = INVALID_HANDLE_VALUE;
  std::atomic<bool> running_{false};
  std::thread reader_;
};

void SerialWinHost::Attach(flutter::BinaryMessenger* messenger) {
  impl_ = std::make_unique<Impl>();
  impl_->Attach(messenger);
}

void SerialWinHost::Close() {
  if (impl_) {
    impl_->Close();
  }
}
