//go:build cgo

package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"encoding/json"
	"unsafe"
)

//export getTraffic
func getTraffic() *C.char {
	return C.CString(handleGetTraffic())
}

//export getTotalTraffic
func getTotalTraffic() *C.char {
	return C.CString(handleGetTotalTraffic())
}

//export freeCString
func freeCString(s *C.char) {
	C.free(unsafe.Pointer(s))
}

func (result ActionResult) send() {
	data, err := result.Json()
	if err != nil {
		return
	}
	invokeCallback(result.Callback, string(data))
}

//export invokeAction
func invokeAction(paramsChar *C.char, callback unsafe.Pointer) {
	params := C.GoString(paramsChar)
	var action = &Action{}
	err := json.Unmarshal([]byte(params), action)
	if err != nil {
		invokeCallback(callback, err.Error())
		return
	}
	result := ActionResult{
		Id:       action.Id,
		Method:   action.Method,
		Callback: callback,
	}
	go handleAction(action, result)
}

func sendMessage(message Message) {
	result := ActionResult{
		Method: messageMethod,
		Data:   message,
	}
	data, err := result.Json()
	if err != nil {
		return
	}
	emitEvent(string(data))
}

//export getConfig
func getConfig(s *C.char) *C.char {
	path := C.GoString(s)
	config, err := handleGetConfig(path)
	if err != nil {
		return C.CString("")
	}
	marshal, err := json.Marshal(config)
	if err != nil {
		return C.CString("")
	}
	return C.CString(string(marshal))
}

//export startListener
func startListener() {
	handleStartListener()
}

//export stopListener
func stopListener() {
	handleStopListener()
}
