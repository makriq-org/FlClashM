package profilecodec

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net/netip"
	"unicode/utf8"

	"github.com/klauspost/compress/zstd"
	cp "github.com/metacubex/mihomo/constant/provider"
	rp "github.com/metacubex/mihomo/rules/provider"
)

// MaxResourceBytes bounds both stored resources and their text representation.
const MaxResourceBytes = 16 << 20

var errResourceLimit = errors.New("resource exceeds 16 MiB limit")

// DumpRules returns UTF-8 input unchanged or exports a domain/IPCIDR MRS as text.
// It owns no files, engine state or network access. Unsupported binary is rejected.
func DumpRules(buf []byte) ([]byte, error) {
	if len(buf) > MaxResourceBytes {
		return nil, errResourceLimit
	}
	if bytes.HasPrefix(buf, zstdMagic) {
		_, text, err := dumpMrs(buf)
		return text, err
	}
	if !utf8.Valid(buf) {
		return nil, errors.New("binary resource cannot be exported as text")
	}
	return buf, nil
}

type ruleTextWriter struct {
	bytes.Buffer
	err error
}

func (w *ruleTextWriter) Write(p []byte) (int, error) {
	if w.err != nil {
		return 0, w.err
	}
	if len(p) > MaxResourceBytes-w.Len() {
		w.err = errResourceLimit
		return 0, w.err
	}
	return w.Buffer.Write(p)
}

func dumpMrs(buf []byte) (behavior cp.RuleBehavior, text []byte, err error) {
	// The engine decoder trusts on-disk lengths and trie indexes. Validate before
	// calling it, including decompressed size, allocation lengths and tree depth.
	// Keep a recovery boundary for malformed data rejected by the engine itself.
	defer func() {
		if recover() != nil {
			text = nil
			err = errRuleSetInvalid
		}
	}()
	if len(buf) > MaxResourceBytes {
		return behavior, nil, errResourceLimit
	}
	behavior, err = validateMrs(buf)
	if err != nil {
		return behavior, nil, err
	}
	writer := &ruleTextWriter{}
	err = rp.ConvertToMrs(buf, behavior, cp.MrsRule, writer)
	// ConvertToMrs currently swallows the writer error in its MRS dump branch.
	if writer.err != nil {
		return behavior, nil, writer.err
	}
	if err != nil {
		return behavior, nil, errRuleSetInvalid
	}
	if !utf8.Valid(writer.Bytes()) {
		return behavior, nil, errRuleSetInvalid
	}
	return behavior, writer.Bytes(), nil
}

func validateMrs(buf []byte) (cp.RuleBehavior, error) {
	decoder, err := zstd.NewReader(bytes.NewReader(buf), zstd.WithDecoderConcurrency(1), zstd.WithDecoderMaxMemory(32<<20), zstd.WithDecoderMaxWindow(MaxResourceBytes))
	if err != nil {
		return 0, errRuleSetInvalid
	}
	defer decoder.Close()
	raw, err := io.ReadAll(io.LimitReader(decoder, MaxResourceBytes+1))
	if err != nil {
		return 0, errRuleSetInvalid
	}
	if len(raw) > MaxResourceBytes {
		return 0, errResourceLimit
	}
	if len(raw) < 21 || !bytes.Equal(raw[:4], rp.MrsMagicBytes[:]) {
		return 0, errRuleSetInvalid
	}
	var behavior cp.RuleBehavior
	switch raw[4] {
	case cp.Domain.Byte():
		behavior = cp.Domain
	case cp.IPCIDR.Byte():
		behavior = cp.IPCIDR
	default:
		return 0, errRuleSetInvalid
	}
	count := binary.BigEndian.Uint64(raw[5:13])
	if count == 0 || count > MaxResourceBytes {
		return 0, errRuleSetInvalid
	}
	raw = raw[13:]
	take := func(width int) ([]byte, bool) {
		if len(raw) < 8 {
			return nil, false
		}
		n := binary.BigEndian.Uint64(raw[:8])
		raw = raw[8:]
		if n > uint64(len(raw)/width) {
			return nil, false
		}
		size := int(n) * width
		result := raw[:size]
		raw = raw[size:]
		return result, true
	}
	if _, ok := take(1); !ok {
		return 0, errRuleSetInvalid
	} // reserved metadata
	if len(raw) < 1 || raw[0] != 1 {
		return 0, errRuleSetInvalid
	}
	raw = raw[1:]
	if behavior == cp.IPCIDR {
		ranges, ok := take(32)
		if !ok || len(ranges) == 0 || len(raw) != 0 {
			return 0, errRuleSetInvalid
		}
		for offset := 0; offset < len(ranges); offset += 32 {
			from := netip.AddrFrom16([16]byte(ranges[offset : offset+16])).Unmap()
			to := netip.AddrFrom16([16]byte(ranges[offset+16 : offset+32])).Unmap()
			if from.BitLen() != to.BitLen() || from.Compare(to) > 0 {
				return 0, errRuleSetInvalid
			}
		}
		return behavior, nil
	}
	leaves, ok := take(8)
	if !ok || len(leaves) == 0 {
		return 0, errRuleSetInvalid
	}
	bitmap, ok := take(8)
	if !ok || len(bitmap) == 0 {
		return 0, errRuleSetInvalid
	}
	labels, ok := take(1)
	if !ok || len(labels) == 0 || len(raw) != 0 {
		return 0, errRuleSetInvalid
	}
	nodes := len(labels) + 1
	if len(leaves)/8 < (nodes+63)/64 || len(bitmap)/8 < (2*nodes-1+63)/64 {
		return 0, errRuleSetInvalid
	}
	bit := func(words []byte, index int) bool {
		return binary.BigEndian.Uint64(words[index/64*8:])&(uint64(1)<<uint(index%64)) != 0
	}
	// LOUDS encodes each node's children as zero bits followed by a one. Children
	// must refer to subsequent nodes; this also excludes cycles and deep recursion.
	depths := make([]uint16, nodes)
	next, position, total, entries := 1, 0, 0, 0
	for node := 0; node < nodes; node++ {
		if node >= next {
			return 0, errRuleSetInvalid
		}
		if bit(leaves, node) {
			total += int(depths[node]) + 1
			entries++
			if total > MaxResourceBytes {
				return 0, errResourceLimit
			}
		}
		for {
			if position >= 2*nodes-1 {
				return 0, errRuleSetInvalid
			}
			end := bit(bitmap, position)
			position++
			if end {
				break
			}
			if next >= nodes || depths[node] >= 4096 {
				return 0, errRuleSetInvalid
			}
			depths[next] = depths[node] + 1
			next++
		}
	}
	if next != nodes || entries == 0 {
		return 0, errRuleSetInvalid
	}
	return behavior, nil
}
