package httpclient

import "testing"

func TestParseCurl(t *testing.T) {
	cases := []struct {
		name, in, method, url, body string
		mode                        string
		headers                     []string // "Key: value"
	}{
		{"basic", `curl -X PATCH "https://a.io/v1/items/9" -H "X-Custom: abc" -d '{"active":true}'`, "PATCH", "https://a.io/v1/items/9", `{"active":true}`, BodyJSON, []string{"X-Custom: abc"}},
		{"glued method", `curl -XDELETE https://a.io/x`, "DELETE", "https://a.io/x", "", BodyNone, nil},
		{"data implies POST", `curl https://a.io/x -d a=1 -d b=2`, "POST", "https://a.io/x", "a=1&b=2", BodyRaw, nil},
		{"explicit GET with data stays GET", `curl -X GET https://a.io/x -d a=1`, "GET", "https://a.io/x", "a=1", BodyRaw, nil},
		{"--url and --opt=value", `curl --url=https://a.io/x --request=PUT --data-raw='{"a":1}'`, "PUT", "https://a.io/x", `{"a":1}`, BodyJSON, nil},
		{"head", `curl -I https://a.io/x`, "HEAD", "https://a.io/x", "", BodyNone, nil},
		{"json flag", `curl --json '{"a":1}' https://a.io/x`, "POST", "https://a.io/x", `{"a":1}`, BodyJSON, []string{"Content-Type: application/json", "Accept: application/json"}},
		{"cookie", `curl https://a.io/x -b 'sid=1; t=2'`, "GET", "https://a.io/x", "", BodyNone, []string{"Cookie: sid=1; t=2"}},
		{"ignored flags", `curl -sSL --compressed -k https://a.io/x`, "GET", "https://a.io/x", "", BodyNone, nil},
		{"line continuations", "curl https://a.io/x \\\n  -H 'A: 1' \\\n  -H 'B: 2'", "GET", "https://a.io/x", "", BodyNone, []string{"A: 1", "B: 2"}},
		{"browser $'' quoting", `curl 'https://a.io/x' -H 'content-type: application/json' --data-raw $'{"msg":"it\'s\nok"}'`, "POST", "https://a.io/x", "{\"msg\":\"it's\nok\"}", BodyJSON, []string{"content-type: application/json"}},
		{"variable url", `curl {{base_url}}/health`, "GET", "{{base_url}}/health", "", BodyNone, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseCurl(c.in)
			if err != nil {
				t.Fatal(err)
			}
			if got.Method != c.method || got.URL != c.url || got.Body != c.body || got.BodyMode != c.mode {
				t.Fatalf("got %s %s %q %s", got.Method, got.URL, got.Body, got.BodyMode)
			}
			if len(got.Headers) != len(c.headers) {
				t.Fatalf("headers = %+v, want %v", got.Headers, c.headers)
			}
			for i, h := range got.Headers {
				if h.Key+": "+h.Value != c.headers[i] || !h.Enabled {
					t.Fatalf("header %d = %+v, want %s", i, h, c.headers[i])
				}
			}
		})
	}
}

func TestParseCurlErrors(t *testing.T) {
	for _, in := range []string{"", "   ", "curl -X POST", "curl -H 'A: b'"} {
		if _, err := parseCurl(in); err == nil {
			t.Errorf("parseCurl(%q) succeeded, want error", in)
		}
	}
}
