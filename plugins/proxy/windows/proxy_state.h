#ifndef FLCLASHM_PROXY_STATE_H_
#define FLCLASHM_PROXY_STATE_H_

#include <cstdint>
#include <string>
#include <vector>

namespace proxy {

// All operations use the current user's WinINet settings and a per-user
// ownership journal. Errors are returned to Dart rather than hidden.
bool StartOwnedProxy(int port, const std::vector<std::wstring>& bypass,
                     std::wstring* error);
bool StopOwnedProxy(std::wstring* error);
// Invoked by the same-user watchdog when its parent pipe closes.
bool RecoverOwnedProxy(std::uint32_t owner_pid, std::uint64_t owner_created,
                       std::wstring* error);

}  // namespace proxy

#endif  // FLCLASHM_PROXY_STATE_H_
