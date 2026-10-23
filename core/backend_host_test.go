package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

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
