//go:build android && cmfa

package main

import (
	"context"
	"github.com/metacubex/mihomo/dns"
)

func (backendEngine) SystemDNS(ctx context.Context, addresses []string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	dns.UpdateSystemDNS(normalizeSystemDNSServersPortable(addresses))
	dns.FlushCacheWithDefaultResolver()
	return ctx.Err()
}
