//go:build !cgo

package main

import (
	"fmt"
	"io"
	"os"
)

func main() {
	args := os.Args
	if len(args) <= 1 {
		fmt.Println("Arguments error")
		os.Exit(1)
	}
	if serviceHome() != "" {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			handleShutdown()
			os.Exit(0)
		}()
	}
	startServer(args[1])
}
