#include "proxy_plugin.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "proxy_state.h"

namespace proxy {
namespace {

HANDLE watchdog_pipe = nullptr;
HANDLE watchdog_process = nullptr;

std::string ToUtf8(const std::wstring& value) {
  int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.c_str(),
                                 static_cast<int>(value.size()), nullptr, 0,
                                 nullptr, nullptr);
  if (size <= 0) return "Windows proxy error";
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.c_str(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

bool FromUtf8(const std::string& value, std::wstring* result) {
  if (value.empty()) { result->clear(); return true; }
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                 value.data(), static_cast<int>(value.size()),
                                 nullptr, 0);
  if (size <= 0) return false;
  result->resize(size);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                             value.data(), static_cast<int>(value.size()),
                             result->data(), size) == size;
}

bool WatchdogPath(std::wstring* path, std::wstring* error) {
  HMODULE module = GetModuleHandleW(L"proxy_plugin.dll");
  if (!module) { *error = L"proxy_plugin.dll is not loaded"; return false; }
  std::vector<wchar_t> buffer(MAX_PATH);
  DWORD length = 0;
  for (;;) {
    length = GetModuleFileNameW(module, buffer.data(),
                                static_cast<DWORD>(buffer.size()));
    if (length == 0) { *error = L"GetModuleFileNameW failed"; return false; }
    if (length < buffer.size() - 1) break;
    if (buffer.size() >= 32768) { *error = L"Proxy plugin path too long"; return false; }
    buffer.resize(buffer.size() * 2);
  }
  std::wstring dll_path(buffer.data(), length);
  auto slash = dll_path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) { *error = L"Invalid proxy plugin path"; return false; }
  *path = dll_path.substr(0, slash + 1) + L"proxy_watchdog.exe";
  return true;
}

void ReleaseWatchdog(bool clean) {
  if (watchdog_pipe) {
    if (clean) { const char done = 'C'; DWORD written = 0;
      WriteFile(watchdog_pipe, &done, 1, &written, nullptr); }
    CloseHandle(watchdog_pipe); watchdog_pipe = nullptr; }
  if (watchdog_process) { CloseHandle(watchdog_process); watchdog_process = nullptr; }
}

bool EnsureWatchdog(std::wstring* error) {
  if (watchdog_pipe) {
    if (WaitForSingleObject(watchdog_process, 0) == WAIT_TIMEOUT) return true;
    ReleaseWatchdog(false);
  }
  std::wstring path;
  if (!WatchdogPath(&path, error)) return false;
  HANDLE child_stdin = nullptr, parent_stdin = nullptr;
  HANDLE parent_stdout = nullptr, child_stdout = nullptr;
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), nullptr, TRUE};
  if (!CreatePipe(&child_stdin, &parent_stdin, &attributes, 0) ||
      !CreatePipe(&parent_stdout, &child_stdout, &attributes, 0)) {
    *error = L"Cannot create proxy watchdog pipes";
    if (child_stdin) CloseHandle(child_stdin);
    if (parent_stdin) CloseHandle(parent_stdin);
    if (parent_stdout) CloseHandle(parent_stdout);
    if (child_stdout) CloseHandle(child_stdout);
    return false;
  }
  if (!SetHandleInformation(parent_stdin, HANDLE_FLAG_INHERIT, 0) ||
      !SetHandleInformation(parent_stdout, HANDLE_FLAG_INHERIT, 0)) {
    *error = L"Cannot protect proxy watchdog pipe handles";
    CloseHandle(child_stdin); CloseHandle(parent_stdin);
    CloseHandle(parent_stdout); CloseHandle(child_stdout);
    return false;
  }
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = child_stdin;
  startup.hStdOutput = child_stdout;
  startup.hStdError = child_stdout;
  PROCESS_INFORMATION process{};
  std::wstring command = L"\"" + path + L"\" " +
                         std::to_wstring(GetCurrentProcessId());
  bool launched = CreateProcessW(path.c_str(), command.data(), nullptr, nullptr,
                                  TRUE, CREATE_NO_WINDOW, nullptr, nullptr,
                                  &startup, &process) != 0;
  CloseHandle(child_stdin);
  CloseHandle(child_stdout);
  if (!launched) {
    *error = L"CreateProcessW(proxy watchdog): " + std::to_wstring(GetLastError());
    CloseHandle(parent_stdin);
    CloseHandle(parent_stdout);
    return false;
  }
  CloseHandle(process.hThread);
  bool ready = false;
  for (int i = 0; i < 500; ++i) {
    DWORD available = 0;
    if (PeekNamedPipe(parent_stdout, nullptr, 0, nullptr, &available, nullptr) &&
        available > 0) {
      char marker = 0;
      DWORD received = 0;
      ready = ReadFile(parent_stdout, &marker, 1, &received, nullptr) &&
              received == 1 && marker == 'R';
      break;
    }
    if (WaitForSingleObject(process.hProcess, 0) != WAIT_TIMEOUT) break;
    Sleep(10);
  }
  CloseHandle(parent_stdout);
  if (!ready || WaitForSingleObject(process.hProcess, 0) != WAIT_TIMEOUT) {
    *error = L"Proxy watchdog did not become ready";
    CloseHandle(parent_stdin);
    CloseHandle(process.hProcess);
    return false;
  }
  watchdog_pipe = parent_stdin;
  watchdog_process = process.hProcess;
  return true;
}

void Fail(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result,
          const std::wstring& error) {
  result->Error("proxy_error", ToUtf8(error));
}

}  // namespace

void ProxyPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "proxy", &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<ProxyPlugin>();
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}

ProxyPlugin::ProxyPlugin() = default;
ProxyPlugin::~ProxyPlugin() { ReleaseWatchdog(false); }

void ProxyPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::wstring error;
  if (method_call.method_name() == "StopProxy") {
    if (!StopOwnedProxy(&error)) { Fail(result, error); return; }
    ReleaseWatchdog(true);
    result->Success(true);
    return;
  }
  if (method_call.method_name() == "StartProxy") {
    const auto* args = method_call.arguments()
                           ? std::get_if<flutter::EncodableMap>(method_call.arguments())
                           : nullptr;
    if (!args) { result->Error("invalid_arguments", "Missing proxy arguments"); return; }
    const auto port_it = args->find(flutter::EncodableValue("port"));
    const auto bypass_it = args->find(flutter::EncodableValue("bypassDomain"));
    if (port_it == args->end() || bypass_it == args->end()) {
      result->Error("invalid_arguments", "Missing proxy port or bypass list");
      return;
    }
    const auto* port = std::get_if<int>(&port_it->second);
    const auto* bypass = std::get_if<flutter::EncodableList>(&bypass_it->second);
    if (!port || !bypass) {
      result->Error("invalid_arguments", "Invalid proxy port or bypass list");
      return;
    }
    std::vector<std::wstring> domains;
    for (const auto& value : *bypass) {
      const auto* domain = std::get_if<std::string>(&value);
      std::wstring wide;
      if (!domain || !FromUtf8(*domain, &wide)) {
        result->Error("invalid_arguments", "Invalid UTF-8 bypass domain");
        return;
      }
      domains.push_back(std::move(wide));
    }
    if (!EnsureWatchdog(&error)) { Fail(result, error); return; }
    if (!StartOwnedProxy(*port, domains, &error)) {
      Fail(result, error);
      return;
    }
    result->Success(true);
    return;
  }
  result->NotImplemented();
}

}  // namespace proxy
