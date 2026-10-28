package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestHostCertificatesSkipUnparseableAndroidIssuer(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	valid, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		t.Fatal(err)
	}
	invalid := bytes.Clone(valid)
	serial := bytes.Index(invalid, []byte{0x02, 0x01, 0x01})
	if serial < 0 {
		t.Fatal("serial not found")
	}
	invalid[serial+2] = 0x81
	if _, err := x509.ParseCertificate(invalid); err == nil {
		t.Fatal("expected invalid serial")
	}
	roots := x509.NewCertPool()
	encode := base64.StdEncoding.EncodeToString
	if err := addHostCertificates(roots, []string{encode(invalid), encode(valid)}); err != nil {
		t.Fatal(err)
	}
	if len(roots.Subjects()) != 1 {
		t.Fatalf("got %d trusted certificates", len(roots.Subjects()))
	}
	if err := addHostCertificates(roots, []string{"not base64!"}); err == nil {
		t.Fatal("expected malformed host data to fail")
	}
}

func TestCachesUseLegacyTimeZoneSavedByApplicationJournal(t *testing.T) {
	offset := func(location *time.Location) int {
		_, seconds := time.Date(2026, 10, 18, 12, 0, 0, 0, location).Zone()
		return seconds
	}
	directory := t.TempDir()
	// Before the first open the journal will save the current device zone.
	if got := offset(legacyTimeZone(directory, "Device/Unknown", 2*60*60)); got != 2*60*60 {
		t.Fatal("device zone was not used before the journal existed", got)
	}
	// After the device zone changes, legacy timestamps keep the saved zone.
	journal := `{"version":1,"legacyTimeZone":"Saved/Unknown","legacyUtcOffset":10800}`
	if err := os.WriteFile(filepath.Join(directory, "application-v1.json"), []byte(journal), 0600); err != nil {
		t.Fatal(err)
	}
	if got := offset(legacyTimeZone(directory, "UTC", 0)); got != 3*60*60 {
		t.Fatal("cache zone differs from the zone saved for subscriptions", got)
	}
	// A journal without the fields keeps the device values, like its decoder.
	if err := os.WriteFile(filepath.Join(directory, "application-v1.json"), []byte(`{"version":1}`), 0600); err != nil {
		t.Fatal(err)
	}
	if got := offset(legacyTimeZone(directory, "Device/Unknown", -5*60*60)); got != -5*60*60 {
		t.Fatal("missing journal fields replaced the device zone", got)
	}
}
