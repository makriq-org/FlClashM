#include <windows.h>
#include <wininet.h>

#include <array>
#include <iostream>
#include <string>
#include <vector>

#include "proxy_state.h"

namespace {

struct Settings {
  DWORD flags = 0;
  std::wstring server;
  std::wstring bypass;
  std::wstring pac;
  DWORD autodiscovery = 0;
  bool operator==(const Settings& other) const {
    return flags == other.flags && server == other.server &&
           bypass == other.bypass && pac == other.pac &&
           autodiscovery == other.autodiscovery;
  }
};

bool Read(Settings* out) {
  std::array<INTERNET_PER_CONN_OPTIONW, 5> options{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS_UI;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[4].dwOption = INTERNET_PER_CONN_AUTODISCOVERY_FLAGS;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data();
  DWORD size = sizeof(list);
  bool ok = InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                                 &list, &size) != 0;
  if (ok) {
    out->flags = options[0].Value.dwValue;
    out->server = options[1].Value.pszValue ? options[1].Value.pszValue : L"";
    out->bypass = options[2].Value.pszValue ? options[2].Value.pszValue : L"";
    out->pac = options[3].Value.pszValue ? options[3].Value.pszValue : L"";
    out->autodiscovery = options[4].Value.dwValue;
  }
  for (size_t i : {1, 2, 3}) if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
  return ok;
}

bool Write(const Settings& settings) {
  std::array<INTERNET_PER_CONN_OPTIONW, 5> options{};
  options[0].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[0].Value.pszValue = const_cast<wchar_t*>(settings.server.c_str());
  options[1].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[1].Value.pszValue = const_cast<wchar_t*>(settings.bypass.c_str());
  options[2].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[2].Value.pszValue = const_cast<wchar_t*>(settings.pac.c_str());
  options[3].dwOption = INTERNET_PER_CONN_AUTODISCOVERY_FLAGS;
  options[3].Value.dwValue = settings.autodiscovery;
  options[4].dwOption = INTERNET_PER_CONN_FLAGS;
  options[4].Value.dwValue = settings.flags;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data();
  return InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, sizeof(list)) &&
         InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) &&
         InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

std::wstring Executable(const wchar_t* name) {
  std::vector<wchar_t> buffer(32768);
  DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                    static_cast<DWORD>(buffer.size()));
  if (!length || length >= buffer.size()) return L"";
  std::wstring path(buffer.data(), length);
  return path.substr(0, path.find_last_of(L"\\/")) + L"\\" + name;
}

bool StartWatchdog() {
  HANDLE child_in = nullptr, parent_in = nullptr;
  HANDLE parent_out = nullptr, child_out = nullptr;
  SECURITY_ATTRIBUTES attrs{sizeof(attrs), nullptr, TRUE};
  if (!CreatePipe(&child_in, &parent_in, &attrs, 0) ||
      !CreatePipe(&parent_out, &child_out, &attrs, 0)) return false;
  SetHandleInformation(parent_in, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(parent_out, HANDLE_FLAG_INHERIT, 0);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = child_in;
  startup.hStdOutput = child_out;
  startup.hStdError = child_out;
  PROCESS_INFORMATION process{};
  const auto path = Executable(L"proxy_watchdog.exe");
  std::wstring command = L"\"" + path + L"\" " +
                         std::to_wstring(GetCurrentProcessId());
  bool launched = CreateProcessW(path.c_str(), command.data(), nullptr, nullptr,
                                  TRUE, CREATE_NO_WINDOW, nullptr, nullptr,
                                  &startup, &process) != 0;
  CloseHandle(child_in);
  CloseHandle(child_out);
  if (!launched) return false;
  CloseHandle(process.hThread);
  bool ready = false;
  for (int i = 0; i < 500; ++i) {
    DWORD available = 0;
    if (PeekNamedPipe(parent_out, nullptr, 0, nullptr, &available, nullptr) &&
        available > 0) {
      char marker = 0; DWORD read = 0;
      ready = ReadFile(parent_out, &marker, 1, &read, nullptr) && read == 1 && marker == 'R';
      break;
    }
    if (WaitForSingleObject(process.hProcess, 0) != WAIT_TIMEOUT) break;
    Sleep(10);
  }
  CloseHandle(parent_out);
  CloseHandle(process.hProcess);
  if (!ready) { CloseHandle(parent_in); return false; }
  // Deliberately leave parent_in open until ExitProcess; the watchdog will
  // receive EOF and restore the snapshot without Flutter cleanup.
  return true;
}

int CrashOwner() {
  if (!StartWatchdog()) return 21;
  std::wstring error;
  if (!proxy::StartOwnedProxy(17988, {L"<local>"}, &error)) return 22;
  ExitProcess(0);
  return 0;
}

int Run() {
  Settings original;
  if (!Read(&original)) return 1;
  struct RestoreOnExit {
    Settings original;
    ~RestoreOnExit() {
      std::wstring error;
      const bool stopped = proxy::StopOwnedProxy(&error);
      const bool restored = Write(original);
      if (!stopped || !restored) {
        std::wcerr << L"Failed to restore runner proxy settings: " << error << std::endl;
        ExitProcess(90);
      }
    }
  } restore{original};
  Settings baseline = original;
  baseline.flags = PROXY_TYPE_DIRECT | PROXY_TYPE_AUTO_DETECT |
                   PROXY_TYPE_AUTO_PROXY_URL;
  baseline.server = L"existing.example:8080";
  baseline.bypass = L"*.before.example;<local>";
  baseline.pac = L"http://pac.before.example/config.pac";
  if (!Write(baseline) || !Read(&baseline)) return 2;
  std::wstring error;
  if (!proxy::StopOwnedProxy(&error)) return 3;
  Settings actual;
  if (!Read(&actual) || !(actual == baseline)) return 4;
  if (!proxy::StartOwnedProxy(17888, {L"*.flclashm.test"}, &error)) {
    std::wcerr << error << std::endl; return 5;
  }
  if (!Read(&actual) || actual.flags != (PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY) ||
      actual.server != L"127.0.0.1:17888" ||
      actual.pac != baseline.pac || actual.autodiscovery != baseline.autodiscovery)
    return 6;
  if (!proxy::StopOwnedProxy(&error) || !Read(&actual) || !(actual == baseline))
    return 7;
  if (!proxy::StartOwnedProxy(17888, {}, &error)) return 11;
  if (!Read(&actual)) return 12;
  actual.bypass = L"changed.by.user.example";
  if (!Write(actual) || !proxy::StopOwnedProxy(&error) || !Read(&actual) ||
      actual.bypass != L"changed.by.user.example" ||
      actual.flags != baseline.flags || actual.server != baseline.server) return 13;
  if (!Write(baseline)) return 14;
  // Simulate the owner process ending without StopOwnedProxy. The watchdog
  // must restore the original PAC/autodetect/proxy state promptly.
  const auto path = Executable(L"proxy_lifecycle_test.exe");
  std::wstring command = L"\"" + path + L"\" --crash-owner";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION child{};
  if (!CreateProcessW(path.c_str(), command.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child)) return 8;
  CloseHandle(child.hThread);
  WaitForSingleObject(child.hProcess, 10000);
  DWORD exit_code = 0;
  GetExitCodeProcess(child.hProcess, &exit_code);
  CloseHandle(child.hProcess);
  if (exit_code != 0) return 9;
  for (int i = 0; i < 500; ++i) {
    if (Read(&actual) && actual == baseline) return 0;
    Sleep(10);
  }
  return 10;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc == 2 && std::wstring(argv[1]) == L"--crash-owner") return CrashOwner();
  int result = Run();
  if (result != 0) std::wcerr << L"proxy_lifecycle_test failed: " << result << std::endl;
  return result;
}
