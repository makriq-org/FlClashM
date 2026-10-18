package transport

import (
	"errors"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestOutputRetainsBoundedUTF8LinesAndExitReason(t *testing.T) {
	var lines []string
	o := newProcessOutput("byedpi", func(kind, line string) {
		if kind != "byedpi" {
			t.Errorf("wrong diagnostic source: %s", kind)
		}
		lines = append(lines, line)
	})
	for _, fragment := range []string{"first\r", "\nsec", "ond\n", strings.Repeat("界", 4000), "\nlast"} {
		if n, err := o.Write([]byte(fragment)); err != nil || n != len(fragment) {
			t.Fatalf("write: %d %v", n, err)
		}
	}
	o.finish(errors.New("exit status 23"))
	<-o.done
	if len(lines) != 5 || lines[0] != "first" || lines[1] != "second" || lines[3] != "last" || lines[4] != "process exited: exit status 23" {
		t.Fatalf("missing output or exit reason: %q", lines)
	}
	if !strings.HasSuffix(lines[2], outputTruncated) {
		t.Fatal("overlong line was not marked truncated")
	}
	for _, line := range lines {
		if !utf8.ValidString(line) || len(line) > outputLineBytes || strings.ContainsRune(line, '\uFFFD') {
			t.Fatalf("unbounded or invalid UTF8 output: %q", line)
		}
	}
}

func TestSlowDiagnosticsDoNotBlockProcessOutputOrFinish(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	var lines []string
	o := newProcessOutput("byedpi", func(_, line string) {
		if lines == nil {
			close(entered)
			<-release
		}
		lines = append(lines, line)
	})
	_, _ = o.Write([]byte("first\n"))
	<-entered
	finished := make(chan struct{})
	go func() {
		_, _ = o.Write([]byte(strings.Repeat("noise\n", 10000)))
		o.finish(errors.New("exit status 7"))
		close(finished)
	}()
	select {
	case <-finished:
	case <-time.After(2 * time.Second):
		close(release)
		t.Fatal("slow sink blocked process lifecycle")
	}
	close(release)
	<-o.done
	if len(lines) > outputQueueLines+1 || lines[len(lines)-1] != "process exited: exit status 7" {
		t.Fatalf("queue failed to retain bounded recent output: %q", lines)
	}
	if !strings.Contains(strings.Join(lines, "\n"), "diagnostic queue dropped") {
		t.Fatal("dropped output was not reported")
	}
}
