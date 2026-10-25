package profilecodec

import (
	"bytes"
	"encoding/binary"
	"errors"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
	cp "github.com/metacubex/mihomo/constant/provider"
	rp "github.com/metacubex/mihomo/rules/provider"
)

func compressTestMrs(t *testing.T, raw []byte) []byte {
	t.Helper()
	encoder, err := zstd.NewWriter(nil, zstd.WithEncoderConcurrency(1))
	if err != nil {
		t.Fatal(err)
	}
	defer encoder.Close()
	return encoder.EncodeAll(raw, nil)
}

func TestDumpRulesTextAndMrsRoundTrip(t *testing.T) {
	original := []byte("# исходный текст\r\npayload: ['+.example.com']\r\n")
	text, err := DumpRules(original)
	if err != nil || !bytes.Equal(text, original) {
		t.Fatal("text changed", err)
	}
	for _, source := range []string{"+.example.com\nexact.test\n", "10.0.0.0/8\n2001:db8::/32\n"} {
		info, mrs, err := CompileRules([]byte(source), false)
		if err != nil {
			t.Fatal(err)
		}
		text, err := DumpRules(mrs)
		if err != nil {
			t.Fatal(err)
		}
		rebuilt, roundtrip, err := CompileRules(text, false)
		if err != nil || info.Behavior != rebuilt.Behavior || !bytes.Equal(roundtrip, mrs) {
			t.Fatalf("MRS round trip %s: %s %v", info.Behavior, text, err)
		}
	}
}

func TestDumpRulesRejectsInvalidAndMaliciousCompressedData(t *testing.T) {
	// All hostile lengths are checked against the bounded decompressed buffer
	// before the engine can allocate memory from them.
	header := func(behavior cp.RuleBehavior) []byte {
		raw := append([]byte(nil), rp.MrsMagicBytes[:]...)
		raw = append(raw, behavior.Byte())
		raw = binary.BigEndian.AppendUint64(raw, 1)
		return raw
	}
	hugeExtra := binary.BigEndian.AppendUint64(header(cp.Domain), ^uint64(0))
	hugeLeaves := binary.BigEndian.AppendUint64(header(cp.Domain), 0)
	hugeLeaves = append(hugeLeaves, 1)
	hugeLeaves = binary.BigEndian.AppendUint64(hugeLeaves, 1<<60)
	hugeRanges := binary.BigEndian.AppendUint64(header(cp.IPCIDR), 0)
	hugeRanges = append(hugeRanges, 1)
	hugeRanges = binary.BigEndian.AppendUint64(hugeRanges, 1<<60)
	for _, data := range [][]byte{
		{0xff, 0xfe}, append(append([]byte(nil), zstdMagic...), []byte("broken")...),
		compressTestMrs(t, []byte("not MRS")), compressTestMrs(t, hugeExtra),
		compressTestMrs(t, hugeLeaves), compressTestMrs(t, hugeRanges),
		compressTestMrs(t, bytes.Repeat([]byte{0}, MaxResourceBytes+1)),
		bytes.Repeat([]byte{'x'}, MaxResourceBytes+1),
	} {
		if text, err := DumpRules(data); err == nil || text != nil {
			t.Fatalf("accepted invalid resource: len=%d err=%v", len(data), err)
		}
		if bytes.HasPrefix(data, zstdMagic) {
			if _, _, err := CompileRules(data, false); err == nil {
				t.Fatal("compile accepted hostile MRS")
			}
		}
	}
	// A structurally corrupt succinct trie must return an error without panicking.
	_, mrs, err := CompileRules([]byte("example.com"), false)
	if err != nil {
		t.Fatal(err)
	}
	decoder, err := zstd.NewReader(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer decoder.Close()
	raw, err := decoder.DecodeAll(mrs, nil)
	if err != nil {
		t.Fatal(err)
	}
	leaves := int(binary.BigEndian.Uint64(raw[22:30]))
	bitmapLengthOffset := 30 + leaves*8
	bitmapLength := int(binary.BigEndian.Uint64(raw[bitmapLengthOffset:]))
	clear(raw[bitmapLengthOffset+8 : bitmapLengthOffset+8+bitmapLength*8])
	if _, err = DumpRules(compressTestMrs(t, raw)); err == nil {
		t.Fatal("accepted cyclic/corrupt trie")
	}
}

func TestDumpRulesBoundsExpandedTextAndWriter(t *testing.T) {
	// A compact range expands into many prefixes, exercising the writer limit
	// independently of the 16 MiB compressed/decompressed input limits.
	raw := append([]byte(nil), rp.MrsMagicBytes[:]...)
	raw = append(raw, cp.IPCIDR.Byte())
	raw = binary.BigEndian.AppendUint64(raw, 4000)
	raw = binary.BigEndian.AppendUint64(raw, 0)
	raw = append(raw, 1)
	raw = binary.BigEndian.AppendUint64(raw, 4000)
	for i := 0; i < 4000; i++ {
		from := make([]byte, 16)
		from[0] = 0x20
		from[15] = 1
		to := bytes.Repeat([]byte{0xff}, 16)
		to[0] = 0x20
		to[15] = 0xfe
		raw = append(raw, from...)
		raw = append(raw, to...)
	}
	if text, err := DumpRules(compressTestMrs(t, raw)); !errors.Is(err, errResourceLimit) || text != nil {
		t.Fatalf("unbounded expansion: %d %v", len(text), err)
	}
	w := &ruleTextWriter{}
	if _, err := w.Write([]byte(strings.Repeat("x", MaxResourceBytes))); err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte("\n")); !errors.Is(err, errResourceLimit) || w.Len() != MaxResourceBytes {
		t.Fatal("writer exceeded bound", err)
	}
}
