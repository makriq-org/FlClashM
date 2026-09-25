#include "proxy_state.h"

#include <windows.h>
#include <wininet.h>
#include <ras.h>
#include <raserror.h>

#include <algorithm>
#include <array>
#include <string>
#include <vector>

namespace proxy {
namespace {

constexpr wchar_t kJournalPath[] = L"Software\\FlClashM\\SystemProxyOwner";
constexpr wchar_t kMutexName[] = L"Global\\FlClashM.SystemProxyOwner";
constexpr DWORD kOwnedFlags = PROXY_TYPE_DIRECT | PROXY_TYPE_PROXY;

struct ConnectionState {
  std::wstring name;
  DWORD flags = 0;
  std::wstring server;
  std::wstring bypass;
  std::wstring auto_config_url;
  DWORD auto_discovery_flags = 0;
};

struct Entry {
  ConnectionState before;
  std::wstring owned_server;
  std::wstring owned_bypass;
};

struct Journal {
  DWORD owner_pid = 0;
  ULONGLONG owner_created = 0;
  std::vector<Entry> entries;
};

class RegKey {
 public:
  explicit RegKey(HKEY key = nullptr) : key_(key) {}
  ~RegKey() { if (key_) RegCloseKey(key_); }
  RegKey(const RegKey&) = delete;
  RegKey& operator=(const RegKey&) = delete;
  HKEY get() const { return key_; }
  HKEY* out() { return &key_; }
 private:
  HKEY key_;
};

class MutexLock {
 public:
  explicit MutexLock(std::wstring* error) {
    mutex_ = CreateMutexW(nullptr, FALSE, kMutexName);
    if (!mutex_) { *error = L"CreateMutexW: " + std::to_wstring(GetLastError()); return; }
    DWORD result = WaitForSingleObject(mutex_, 10000);
    if (result == WAIT_OBJECT_0 || result == WAIT_ABANDONED) {
      locked_ = true;
    } else {
      *error = L"WaitForSingleObject(proxy mutex): " + std::to_wstring(result);
    }
  }
  ~MutexLock() {
    if (locked_) ReleaseMutex(mutex_);
    if (mutex_) CloseHandle(mutex_);
  }
  bool ok() const { return locked_; }
 private:
  HANDLE mutex_ = nullptr;
  bool locked_ = false;
};

std::wstring WinError(const wchar_t* operation) {
  return std::wstring(operation) + L": " + std::to_wstring(GetLastError());
}

bool ReadDword(HKEY key, const wchar_t* name, DWORD* value) {
  DWORD type = 0, size = sizeof(*value);
  return RegQueryValueExW(key, name, nullptr, &type,
                          reinterpret_cast<BYTE*>(value), &size) == ERROR_SUCCESS &&
         type == REG_DWORD && size == sizeof(*value);
}

bool WriteDword(HKEY key, const wchar_t* name, DWORD value) {
  return RegSetValueExW(key, name, 0, REG_DWORD,
                        reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS;
}

bool ReadQword(HKEY key, const wchar_t* name, ULONGLONG* value) {
  DWORD type = 0, size = sizeof(*value);
  return RegQueryValueExW(key, name, nullptr, &type,
                          reinterpret_cast<BYTE*>(value), &size) == ERROR_SUCCESS &&
         type == REG_QWORD && size == sizeof(*value);
}

bool WriteQword(HKEY key, const wchar_t* name, ULONGLONG value) {
  return RegSetValueExW(key, name, 0, REG_QWORD,
                        reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS;
}

bool ReadString(HKEY key, const wchar_t* name, std::wstring* value) {
  DWORD type = 0, size = 0;
  if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &size) != ERROR_SUCCESS ||
      type != REG_SZ || size < sizeof(wchar_t) || size % sizeof(wchar_t) != 0 ||
      size > 1024 * 1024) return false;
  std::vector<wchar_t> buffer(size / sizeof(wchar_t));
  if (RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<BYTE*>(buffer.data()), &size) != ERROR_SUCCESS ||
      buffer.back() != L'\0') return false;
  *value = buffer.data();
  return true;
}

bool WriteString(HKEY key, const wchar_t* name, const std::wstring& value) {
  return RegSetValueExW(key, name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(value.c_str()),
                        static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

std::wstring EntryKeyName(size_t index) { return std::to_wstring(index); }

bool SaveJournal(const Journal& journal, std::wstring* error) {
  // Ready is written last. A crash while writing cannot leave an active journal
  // pointing at incomplete snapshots, and no WinINet mutation happens yet.
  LONG cleared = RegDeleteTreeW(HKEY_CURRENT_USER, kJournalPath);
  if (cleared != ERROR_SUCCESS && cleared != ERROR_FILE_NOT_FOUND) {
    *error = L"Cannot replace proxy ownership journal: " + std::to_wstring(cleared);
    return false;
  }
  RegKey key;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kJournalPath, 0, nullptr, 0,
                      KEY_ALL_ACCESS, nullptr, key.out(), nullptr) != ERROR_SUCCESS) {
    *error = L"Cannot create proxy ownership journal";
    return false;
  }
  if (!WriteDword(key.get(), L"OwnerPid", journal.owner_pid) ||
      !WriteQword(key.get(), L"OwnerCreated", journal.owner_created) ||
      !WriteDword(key.get(), L"Count", static_cast<DWORD>(journal.entries.size()))) {
    *error = L"Cannot write proxy ownership journal";
    return false;
  }
  for (size_t i = 0; i < journal.entries.size(); ++i) {
    RegKey child;
    const auto name = EntryKeyName(i);
    if (RegCreateKeyExW(key.get(), name.c_str(), 0, nullptr, 0,
                        KEY_ALL_ACCESS, nullptr, child.out(), nullptr) != ERROR_SUCCESS) {
      *error = L"Cannot write proxy connection journal";
      return false;
    }
    const auto& entry = journal.entries[i];
    if (!WriteString(child.get(), L"Name", entry.before.name) ||
        !WriteDword(child.get(), L"Flags", entry.before.flags) ||
        !WriteString(child.get(), L"Server", entry.before.server) ||
        !WriteString(child.get(), L"Bypass", entry.before.bypass) ||
        !WriteString(child.get(), L"AutoConfigUrl", entry.before.auto_config_url) ||
        !WriteDword(child.get(), L"AutoDiscoveryFlags", entry.before.auto_discovery_flags) ||
        !WriteString(child.get(), L"OwnedServer", entry.owned_server) ||
        !WriteString(child.get(), L"OwnedBypass", entry.owned_bypass)) {
      *error = L"Cannot write proxy connection values";
      return false;
    }
  }
  if (RegFlushKey(key.get()) != ERROR_SUCCESS ||
      !WriteDword(key.get(), L"Ready", 1) ||
      RegFlushKey(key.get()) != ERROR_SUCCESS) {
    *error = L"Cannot commit proxy ownership journal";
    return false;
  }
  return true;
}

bool LoadJournal(Journal* journal, bool* exists, std::wstring* error) {
  RegKey key;
  LONG status = RegOpenKeyExW(HKEY_CURRENT_USER, kJournalPath, 0,
                              KEY_READ, key.out());
  if (status == ERROR_FILE_NOT_FOUND) { *exists = false; return true; }
  if (status != ERROR_SUCCESS) { *error = L"Cannot open proxy ownership journal"; return false; }
  DWORD ready = 0;
  if (!ReadDword(key.get(), L"Ready", &ready) || ready != 1) {
    // An interrupted write cannot have modified WinINet, so it is safe to
    // replace this incomplete journal on a later StartProxy.
    *exists = false;
    return true;
  }
  DWORD count = 0;
  if (!ReadDword(key.get(), L"OwnerPid", &journal->owner_pid) ||
      !ReadQword(key.get(), L"OwnerCreated", &journal->owner_created) ||
      !ReadDword(key.get(), L"Count", &count) || count > 256) {
    *error = L"Invalid proxy ownership journal header";
    return false;
  }
  journal->entries.clear();
  for (DWORD i = 0; i < count; ++i) {
    RegKey child;
    const auto name = EntryKeyName(i);
    if (RegOpenKeyExW(key.get(), name.c_str(), 0, KEY_READ, child.out()) != ERROR_SUCCESS) {
      *error = L"Incomplete proxy ownership journal";
      return false;
    }
    Entry entry;
    if (!ReadString(child.get(), L"Name", &entry.before.name) ||
        !ReadDword(child.get(), L"Flags", &entry.before.flags) ||
        !ReadString(child.get(), L"Server", &entry.before.server) ||
        !ReadString(child.get(), L"Bypass", &entry.before.bypass) ||
        !ReadString(child.get(), L"AutoConfigUrl", &entry.before.auto_config_url) ||
        !ReadDword(child.get(), L"AutoDiscoveryFlags", &entry.before.auto_discovery_flags) ||
        !ReadString(child.get(), L"OwnedServer", &entry.owned_server) ||
        !ReadString(child.get(), L"OwnedBypass", &entry.owned_bypass)) {
      *error = L"Invalid proxy ownership journal entry";
      return false;
    }
    journal->entries.push_back(std::move(entry));
  }
  *exists = true;
  return true;
}

bool DeleteJournal(std::wstring* error) {
  LONG status = RegDeleteTreeW(HKEY_CURRENT_USER, kJournalPath);
  if (status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND) return true;
  *error = L"Cannot clear proxy ownership journal: " + std::to_wstring(status);
  return false;
}

enum class ProcessStatus { alive, dead, unknown };

ProcessStatus OwnerProcessStatus(const Journal& journal) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
                               FALSE, journal.owner_pid);
  if (!process) {
    return GetLastError() == ERROR_INVALID_PARAMETER
               ? ProcessStatus::dead : ProcessStatus::unknown;
  }
  FILETIME created{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) {
    CloseHandle(process);
    return ProcessStatus::unknown;
  }
  const auto creation = (static_cast<ULONGLONG>(created.dwHighDateTime) << 32) |
                        created.dwLowDateTime;
  const DWORD wait = WaitForSingleObject(process, 0);
  CloseHandle(process);
  if (creation != journal.owner_created || wait == WAIT_OBJECT_0)
    return ProcessStatus::dead;
  return wait == WAIT_TIMEOUT ? ProcessStatus::alive : ProcessStatus::unknown;
}

ULONGLONG CurrentProcessCreated() {
  FILETIME created{}, exited{}, kernel{}, user{};
  if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return 0;
  return (static_cast<ULONGLONG>(created.dwHighDateTime) << 32) |
          created.dwLowDateTime;
}

bool ListConnections(std::vector<std::wstring>* names, std::wstring* error) {
  names->assign(1, L"");  // LAN/default connection.
  std::vector<RASENTRYNAMEW> entries(1);
  entries[0].dwSize = sizeof(RASENTRYNAMEW);
  DWORD bytes = sizeof(RASENTRYNAMEW), count = 0;
  DWORD status = RasEnumEntriesW(nullptr, nullptr, entries.data(), &bytes, &count);
  if (status == ERROR_BUFFER_TOO_SMALL) {
    entries.resize(bytes / sizeof(RASENTRYNAMEW) + 1);
    entries[0].dwSize = sizeof(RASENTRYNAMEW);
    status = RasEnumEntriesW(nullptr, nullptr, entries.data(), &bytes, &count);
  }
  if (status != ERROR_SUCCESS) {
    *error = L"RasEnumEntriesW: " + std::to_wstring(status);
    return false;
  }
  for (DWORD i = 0; i < count; ++i) names->push_back(entries[i].szEntryName);
  return true;
}

bool QueryConnection(const std::wstring& name, ConnectionState* out,
                     std::wstring* error) {
  std::array<INTERNET_PER_CONN_OPTIONW, 5> options{};
  options[0].dwOption = INTERNET_PER_CONN_FLAGS_UI;
  options[1].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
  options[2].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
  options[3].dwOption = INTERNET_PER_CONN_AUTOCONFIG_URL;
  options[4].dwOption = INTERNET_PER_CONN_AUTODISCOVERY_FLAGS;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.pszConnection = name.empty() ? nullptr : const_cast<wchar_t*>(name.c_str());
  list.dwOptionCount = static_cast<DWORD>(options.size());
  list.pOptions = options.data();
  DWORD size = sizeof(list);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, &size)) {
    *error = WinError(L"InternetQueryOptionW");
    for (size_t i : {1, 2, 3}) if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
    return false;
  }
  out->name = name;
  out->flags = options[0].Value.dwValue;
  out->server = options[1].Value.pszValue ? options[1].Value.pszValue : L"";
  out->bypass = options[2].Value.pszValue ? options[2].Value.pszValue : L"";
  out->auto_config_url = options[3].Value.pszValue ? options[3].Value.pszValue : L"";
  out->auto_discovery_flags = options[4].Value.dwValue;
  for (size_t i : {1, 2, 3}) if (options[i].Value.pszValue) GlobalFree(options[i].Value.pszValue);
  return true;
}

bool SetConnection(const std::wstring& name, DWORD flags,
                   const std::wstring& server, const std::wstring& bypass,
                   bool set_flags, bool set_server, bool set_bypass,
                   std::wstring* error) {
  std::array<INTERNET_PER_CONN_OPTIONW, 3> options{};
  DWORD count = 0;
  if (set_server) {
    options[count].dwOption = INTERNET_PER_CONN_PROXY_SERVER;
    options[count++].Value.pszValue = const_cast<wchar_t*>(server.c_str());
  }
  if (set_bypass) {
    options[count].dwOption = INTERNET_PER_CONN_PROXY_BYPASS;
    options[count++].Value.pszValue = const_cast<wchar_t*>(bypass.c_str());
  }
  if (set_flags) {
    options[count].dwOption = INTERNET_PER_CONN_FLAGS;
    options[count++].Value.dwValue = flags;
  }
  if (count == 0) return true;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.pszConnection = name.empty() ? nullptr : const_cast<wchar_t*>(name.c_str());
  list.dwOptionCount = count;
  list.pOptions = options.data();
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                          &list, sizeof(list))) {
    *error = WinError(L"InternetSetOptionW");
    return false;
  }
  return true;
}

bool Notify(std::wstring* error) {
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) ||
      !InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0)) {
    *error = WinError(L"InternetSetOptionW(refresh)");
    return false;
  }
  return true;
}

bool OwnedStillCurrent(const Journal& journal, std::wstring* error) {
  for (const auto& entry : journal.entries) {
    ConnectionState current;
    if (!QueryConnection(entry.before.name, &current, error)) return false;
    if (current.flags != kOwnedFlags ||
        current.server != entry.owned_server ||
        current.bypass != entry.owned_bypass) {
      *error = L"System proxy was changed outside FlClashM";
      return false;
    }
  }
  return true;
}

bool Restore(const Journal& journal, std::wstring* error) {
  bool all_ok = true;
  bool changed = false;
  std::wstring first_error;
  std::vector<std::wstring> present;
  if (!ListConnections(&present, error)) return false;
  for (const auto& entry : journal.entries) {
    if (!entry.before.name.empty() &&
        std::find(present.begin(), present.end(), entry.before.name) == present.end())
      continue;
    ConnectionState current;
    std::wstring issue;
    if (!QueryConnection(entry.before.name, &current, &issue)) {
      if (first_error.empty()) first_error = issue;
      all_ok = false;
      continue;
    }
    // Restore only values that still have the values we wrote. If the user or
    // another program changed a value while FlClashM ran, preserve that edit.
    const DWORD flags = current.flags == kOwnedFlags ? entry.before.flags : current.flags;
    const std::wstring& server = current.server == entry.owned_server
                                     ? entry.before.server : current.server;
    const std::wstring& bypass = current.bypass == entry.owned_bypass
                                     ? entry.before.bypass : current.bypass;
    if (flags == current.flags && server == current.server && bypass == current.bypass)
      continue;
    if (!SetConnection(entry.before.name, flags, server, bypass,
                       flags != current.flags, server != current.server,
                       bypass != current.bypass, &issue)) {
      if (first_error.empty()) first_error = issue;
      all_ok = false;
    } else {
      changed = true;
    }
  }
  std::wstring notify_error;
  if (changed && !Notify(&notify_error)) {
    if (first_error.empty()) first_error = notify_error;
    all_ok = false;
  }
  if (!all_ok) *error = first_error;
  return all_ok;
}


}  // namespace

bool RecoverOwnedProxy(std::uint32_t owner_pid, std::uint64_t owner_created,
                       std::wstring* error) {
  MutexLock lock(error);
  if (!lock.ok()) return false;
  Journal journal;
  bool exists = false;
  if (!LoadJournal(&journal, &exists, error)) return false;
  if (!exists || journal.owner_pid != owner_pid ||
      journal.owner_created != owner_created) return true;
  // The watchdog opened this exact process before signalling readiness and
  // waited for its handle to terminate. A recycled PID cannot fool it.
  if (!Restore(journal, error)) return false;
  return DeleteJournal(error);
}

bool StopOwnedProxy(std::wstring* error) {
  MutexLock lock(error);
  if (!lock.ok()) return false;
  Journal journal;
  bool exists = false;
  if (!LoadJournal(&journal, &exists, error)) return false;
  if (!exists) return true;
  // A second GUI instance must never undo the first instance's proxy.
  if (journal.owner_pid != GetCurrentProcessId() ||
      journal.owner_created != CurrentProcessCreated()) {
    const auto status = OwnerProcessStatus(journal);
    if (status == ProcessStatus::alive) return true;
    if (status == ProcessStatus::unknown) {
      *error = L"Cannot establish whether proxy owner is still running";
      return false;
    }
  }
  if (!Restore(journal, error)) return false;
  return DeleteJournal(error);
}

bool StartOwnedProxy(int port, const std::vector<std::wstring>& bypass,
                     std::wstring* error) {
  if (port < 1 || port > 65535) { *error = L"Invalid proxy port"; return false; }
  MutexLock lock(error);
  if (!lock.ok()) return false;
  Journal old;
  bool exists = false;
  if (!LoadJournal(&old, &exists, error)) return false;
  if (exists) {
    if (old.owner_pid == GetCurrentProcessId() &&
        old.owner_created == CurrentProcessCreated()) {
      // A manual edit revokes ownership. Preserve that edit and refuse to
      // overwrite it when the app changes port or bypass rules.
      std::wstring ownership_error;
      if (!OwnedStillCurrent(old, &ownership_error)) {
        if (!Restore(old, error) || !DeleteJournal(error)) return false;
        *error = ownership_error;
        return false;
      }
      // Refreshing the port must retain the original pre-FlClashM snapshot.
      if (!Restore(old, error) || !DeleteJournal(error)) return false;
    } else {
      const auto status = OwnerProcessStatus(old);
      if (status != ProcessStatus::dead) {
        *error = status == ProcessStatus::alive
                     ? L"Another FlClashM instance owns the system proxy"
                     : L"Cannot establish whether proxy owner is still running";
        return false;
      }
      if (!Restore(old, error) || !DeleteJournal(error)) return false;
    }
  }
  std::vector<std::wstring> names;
  if (!ListConnections(&names, error)) return false;
  std::wstring bypass_string;
  for (const auto& domain : bypass) {
    if (domain.find(L'\0') != std::wstring::npos) {
      *error = L"Invalid bypass domain";
      return false;
    }
    if (!bypass_string.empty()) bypass_string += L";";
    bypass_string += domain;
  }
  Journal journal;
  journal.owner_pid = GetCurrentProcessId();
  journal.owner_created = CurrentProcessCreated();
  if (journal.owner_created == 0) { *error = WinError(L"GetProcessTimes"); return false; }
  const std::wstring server = L"127.0.0.1:" + std::to_wstring(port);
  for (const auto& name : names) {
    Entry entry;
    if (!QueryConnection(name, &entry.before, error)) return false;
    entry.owned_server = server;
    entry.owned_bypass = bypass_string;
    journal.entries.push_back(std::move(entry));
  }
  if (!SaveJournal(journal, error)) return false;
  for (const auto& entry : journal.entries) {
    if (!SetConnection(entry.before.name, kOwnedFlags, server, bypass_string,
                       true, true, true, error)) {
      std::wstring restore_error;
      if (Restore(journal, &restore_error)) DeleteJournal(&restore_error);
      return false;
    }
  }
  if (!Notify(error)) {
    std::wstring restore_error;
    if (Restore(journal, &restore_error)) DeleteJournal(&restore_error);
    return false;
  }
  return true;
}

}  // namespace proxy
