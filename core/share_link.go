package main

import "core/profilecodec"

func handleEncodeShareLinks(values []map[string]any) []string {
	return profilecodec.EncodeLinks(values)
}
func handleDecodeShareLinks(values []string) [][]map[string]any {
	return profilecodec.DecodeLinks(values)
}
