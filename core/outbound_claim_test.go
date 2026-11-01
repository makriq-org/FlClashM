package main

import (
	"context"
	"testing"
)

func TestOutboundClaimsCancelOnlyOlderEpochs(t *testing.T) {
	first, cancelFirst := context.WithCancel(context.Background())
	defer cancelFirst()
	releaseFirst := claimOutboundIp(100, cancelFirst)
	defer releaseFirst()
	same, cancelSame := context.WithCancel(context.Background())
	defer cancelSame()
	releaseSame := claimOutboundIp(100, cancelSame)
	defer releaseSame()
	if first.Err() != nil || same.Err() != nil {
		t.Fatal("same-epoch lookups cancelled each other")
	}
	next, cancelNext := context.WithCancel(context.Background())
	defer cancelNext()
	releaseNext := claimOutboundIp(101, cancelNext)
	defer releaseNext()
	if first.Err() == nil || same.Err() == nil || next.Err() != nil {
		t.Fatal("epoch change did not cancel exactly the older lookups")
	}
}
