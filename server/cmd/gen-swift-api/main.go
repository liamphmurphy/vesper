// Command gen-swift-api generates the Mac app's Swift API types and request builders from
// api/openapi.yaml, the same contract the Go server and the TypeScript client are generated from.
//
// It writes two files into VesperCore (see macos/Sources/VesperCore/API/APIRuntime.swift for the
// hand-written runtime they build on):
//
//   - API+Schemas.gen.swift: one Codable struct per object schema, string enums as open
//     RawRepresentable structs (an unknown value from a newer server still decodes), aliases for the rest.
//   - API+Operations.gen.swift: one static builder per operation returning an APIRequest<Response>.
//
// The macOS package fetches no SwiftPM dependency (its VM has no network), so this replaces
// swift-openapi-generator. `make gen` runs it and `make gen-check` fails when its output is stale.
//
// Usage: go run ./cmd/gen-swift-api -spec ../api/openapi.yaml -out ../macos/Sources/VesperCore/API/Generated
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	spec := flag.String("spec", "../api/openapi.yaml", "OpenAPI document")
	out := flag.String("out", "../macos/Sources/VesperCore/API/Generated", "output directory")
	flag.Parse()

	files, err := Generate(*spec)
	if err != nil {
		fmt.Fprintln(os.Stderr, "gen-swift-api:", err)
		os.Exit(1)
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "gen-swift-api:", err)
		os.Exit(1)
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(*out, name), content, 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "gen-swift-api:", err)
			os.Exit(1)
		}
	}
}
