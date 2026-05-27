//go:build !android && cgo

package main

import "unsafe"

func nextHandle(action *Action, result ActionResult) bool {
	return false
}

// Non-Android cgo builds have no JNI/binder plumbing. The callback and
// event pipelines are Android-only; stub them out so the shared build
// still links.
func invokeCallback(callback unsafe.Pointer, data string) {}

func emitEvent(data string) {}
