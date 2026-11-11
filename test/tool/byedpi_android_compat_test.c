// Exercise the API-21 code path on the host, with and without API-24 libc symbols.
#include <assert.h>
#include <dlfcn.h>
#include <string.h>
#include "params.h"

static int missing_symbol;
void *byedpi_test_dlsym(void *handle, const char *name)
{
    if ((missing_symbol == 1 && !strcmp(name, "getifaddrs")) ||
        (missing_symbol == 2 && !strcmp(name, "freeifaddrs"))) {
        return 0;
    }
    return dlsym(handle, name);
}

int get_addr(const char *str, union sockaddr_u *addr);

int main(void)
{
    for (missing_symbol = 0; missing_symbol < 3; missing_symbol++) {
        union sockaddr_u addr = {0};
        assert(get_addr("127.0.0.1", &addr) == 0);
        assert(addr.sa.sa_family == AF_INET);
        memset(&addr, 0, sizeof(addr));
        assert((get_addr("127.0.0.1%lo", &addr) == 0) == (missing_symbol == 0));
    }
    return 0;
}
