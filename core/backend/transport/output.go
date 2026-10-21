package transport

import (
	"fmt"
	"strings"
	"sync"
)

const outputLineBytes = 4096
const outputQueueLines = 16
const outputTruncated = "…<truncated>"

// processOutput drains stdout/stderr even when the diagnostic sink is slow.
// Both unterminated lines and the delivery queue have fixed memory bounds.
type processOutput struct {
	mu        sync.Mutex
	partial   []byte
	truncated bool
	dropped   int
	lines     chan string
	done      chan struct{}
}

func newProcessOutput(kind string, log func(string, string)) *processOutput {
	o := &processOutput{}
	if log == nil {
		return o
	}
	o.lines = make(chan string, outputQueueLines)
	o.done = make(chan struct{})
	go func() {
		defer close(o.done)
		for line := range o.lines {
			log(kind, line)
		}
	}()
	return o
}

func (o *processOutput) Write(data []byte) (int, error) {
	if o.lines == nil {
		return len(data), nil
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	for _, b := range data {
		if b == '\n' || b == '\r' {
			o.flushLine()
		} else if len(o.partial) < outputLineBytes-len(outputTruncated) {
			o.partial = append(o.partial, b)
		} else {
			o.truncated = true
		}
	}
	return len(data), nil
}

func (o *processOutput) flushLine() {
	line := strings.TrimSpace(strings.ToValidUTF8(string(o.partial), ""))
	if o.truncated {
		line += outputTruncated
	}
	if line != "" {
		o.offer(line)
	}
	o.partial = o.partial[:0]
	o.truncated = false
}

// Retain recent output and the exit reason rather than blocking child pipes.
func (o *processOutput) offer(line string) {
	if len(line) > outputLineBytes {
		line = strings.ToValidUTF8(line[:outputLineBytes-len(outputTruncated)], "") + outputTruncated
	}
	select {
	case o.lines <- line:
		return
	default:
	}
	select {
	case <-o.lines:
		o.dropped++
	default:
	}
	o.lines <- line // Only this producer writes while holding mu; space is free.
}

// Called only after exec.Wait has joined the stdout/stderr copy goroutine.
func (o *processOutput) finish(err error) {
	if o.lines == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	o.flushLine()
	if o.dropped > 0 {
		o.offer(fmt.Sprintf("diagnostic queue dropped at least %d older transport lines", o.dropped))
	}
	line := "process exited successfully"
	if err != nil {
		line = "process exited: " + err.Error()
	}
	o.offer(line)
	close(o.lines)
}
