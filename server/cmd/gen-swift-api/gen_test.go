package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const generatedDir = "../../../macos/Sources/VesperCore/API/Generated"

// The checked-in Swift must match the spec, so a spec change without `make gen` fails here as well
// as in `make gen-check`.
func TestCheckedInSwiftIsCurrent(t *testing.T) {
	files, err := Generate("../../../api/openapi.yaml")
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(generatedDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if _, ok := files[e.Name()]; !ok {
			t.Errorf("%s is in %s but not generated: delete it", e.Name(), generatedDir)
		}
	}
	for name, want := range files {
		got, err := os.ReadFile(filepath.Join(generatedDir, name))
		if err != nil {
			t.Errorf("%s: %v (run make gen)", name, err)
			continue
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s is stale: run make gen and commit", name)
		}
	}
}

func TestNames(t *testing.T) {
	for in, want := range map[string]string{
		"due_date": "dueDate", "ticket_key": "ticketKey", "URL": "url", "in_progress": "inProgress",
		"needs-you": "needsYou", "createTicket": "createTicket", "2fa": "_2fa", "ID": "id", "canvasId": "canvasId",
	} {
		if got := camel(in); got != want {
			t.Errorf("camel(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{"createTicket": "CreateTicket", "run_state": "RunState", "Type": "Type"} {
		if got := pascal(in); got != want {
			t.Errorf("pascal(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{
		"[Swift.String]": "[]", "[Swift.String: JSONValue]": "[:]", "[[Swift.String: JSONValue]]": "[]",
		"[Swift.String: [Swift.Int]]": "[:]", "Swift.String": "",
	} {
		if got := emptyLiteral(in); got != want {
			t.Errorf("emptyLiteral(%q) = %q, want %q", in, got, want)
		}
	}
	if ident("default") != "`default`" || ident("title") != "title" {
		t.Error("ident should backtick keywords only")
	}
}

const smallSpec = `openapi: 3.0.3
info: { title: t, version: "1" }
paths:
  /things/{id}:
    parameters:
      - { name: id, in: path, required: true, schema: { type: string } }
    get:
      operationId: getThing
      parameters:
        - { name: tags, in: query, schema: { type: array, items: { type: string } } }
        - { name: mode, in: query, schema: { type: string, enum: [fast, slow] } }
      responses:
        "200":
          description: ok
          content: { application/json: { schema: { $ref: "#/components/schemas/Thing" } } }
    patch:
      operationId: updateThing
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                note: { type: string, nullable: true }
      responses:
        "204": { description: done }
components:
  schemas:
    Type:
      type: string
      enum: [a, default]
    Thing:
      type: object
      required: [id, items, owner]
      properties:
        id: { type: string }
        items: { type: array, items: { type: string } }
        owner:
          type: object
          required: [name]
          properties:
            name: { type: string }
        parent:
          nullable: true
          allOf: [{ $ref: "#/components/schemas/Thing" }]
        kind: { $ref: "#/components/schemas/Type" }
`

func TestGenerateShapes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "spec.yaml")
	if err := os.WriteFile(path, []byte(smallSpec), 0o644); err != nil {
		t.Fatal(err)
	}
	files, err := Generate(path)
	if err != nil {
		t.Fatal(err)
	}
	schemas := string(files["API+Schemas.gen.swift"])
	ops := string(files["API+Operations.gen.swift"])
	for _, want := range []string{
		// A schema named Type can't be a member type; it gets a suffix.
		"public struct TypeValue: APIStringEnum {",
		"public static let `default` = TypeValue(rawValue: \"default\")",
		"public var kind: TypeValue?",
		// Inline objects nest; nullable refs stay typed.
		"public struct Owner: Codable, Sendable, Equatable {",
		"public var owner: Owner\n",
		"public var parent: APINullable<Thing>?",
		// Required arrays tolerate Go's null.
		"self.items = try c.decodeIfPresent([Swift.String].self, forKey: .items) ?? []",
		"self.parent = try c.decodeNullable(Thing.self, forKey: .parent)",
		// Inline request bodies become top-level types named after the operation.
		"public struct UpdateThingBody: Codable, Sendable, Equatable {",
		"public var note: APINullable<Swift.String>?",
	} {
		if !strings.Contains(schemas, want) {
			t.Errorf("schemas missing %q", want)
		}
	}
	for _, want := range []string{
		"public static func getThing(id: Swift.String, tags: [Swift.String]? = nil, mode: GetThingMode? = nil) -> APIRequest<Thing> {",
		`path: "/api/v1/things/\(APIPath.escape(id))",`,
		`APIQuery.append(&_query, "tags", tags)`,
		"public static func updateThing(id: Swift.String, body: UpdateThingBody) -> APIRequest<APIEmpty> {",
		"body: APIRequestBody.json(body), decode: .empty",
	} {
		if !strings.Contains(ops, want) {
			t.Errorf("operations missing %q", want)
		}
	}
	if !strings.Contains(schemas, "public struct GetThingMode: APIStringEnum {") {
		t.Error("an inline query enum should become a top-level type named after its operation")
	}
}
