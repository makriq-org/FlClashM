#include <windows.h>

#include <cstdlib>
#include <string>

#include "proxy_state.h"

// Runs in the interactive user's account. The inherited stdin pipe remains
// open only while the GUI process is alive. A closed pipe triggers recovery
// even when Flutter cannot run its normal shutdown callback.
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR args, int) {
  wchar_t* end = nullptr;
  DWORD parent_pid = static_cast<DWORD>(std::wcstoul(args, &end, 10));
  if (parent_pid == 0 || end == args || *end != L'\0') return 1;
  HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, parent_pid);
  if (!parent) return 1;
  FILETIME created{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(parent, &created, &exited, &kernel, &user)) {
    CloseHandle(parent);
    return 1;
  }
  const auto owner_created =
      (static_cast<ULONGLONG>(created.dwHighDateTime) << 32) |
       created.dwLowDateTime;
  HANDLE parent_pipe = GetStdHandle(STD_INPUT_HANDLE);
  HANDLE ready_pipe = GetStdHandle(STD_OUTPUT_HANDLE);
  if (!parent_pipe || parent_pipe == INVALID_HANDLE_VALUE ||
      !ready_pipe || ready_pipe == INVALID_HANDLE_VALUE) return 2;
  DWORD written = 0;
  const char ready = 'R';
  if (!WriteFile(ready_pipe, &ready, 1, &written, nullptr) || written != 1)
    return 3;
  CloseHandle(ready_pipe);
  char buffer = 0;
  DWORD received = 0;
  while (ReadFile(parent_pipe, &buffer, 1, &received, nullptr) && received != 0) {
    if (buffer == 'C') { CloseHandle(parent_pipe); CloseHandle(parent); return 0; }
  }
  CloseHandle(parent_pipe);
  WaitForSingleObject(parent, INFINITE);
  CloseHandle(parent);
  std::wstring error;
  return proxy::RecoverOwnedProxy(parent_pid, owner_created, &error) ? 0 : 4;
}
