package main

import (
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// staticSPAHandler serves the web UI's static build (web/dist): a real file when the path names one,
// otherwise index.html, so a deep link such as /tickets/ABC-1 loads the app and its client router
// takes over. A missing file under /assets/ or /fonts/ is a plain 404 rather than the app, so a stale
// hashed asset can't be mistaken for a page. Vite fingerprints everything in /assets/, which is
// therefore cached for good; every other response (index.html included) must be revalidated.
func staticSPAHandler(dir string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		// Clean against "/" first so ".." can't climb out of dir.
		p := path.Clean("/" + r.URL.Path)
		file := filepath.Join(dir, filepath.FromSlash(p))
		if st, err := os.Stat(file); err == nil && st.Mode().IsRegular() {
			serveStaticFile(w, r, file, strings.HasPrefix(p, "/assets/"))
			return
		}
		if strings.HasPrefix(p, "/assets/") || strings.HasPrefix(p, "/fonts/") {
			http.NotFound(w, r)
			return
		}
		serveStaticFile(w, r, filepath.Join(dir, "index.html"), false)
	})
}

func serveStaticFile(w http.ResponseWriter, r *http.Request, file string, immutable bool) {
	f, err := os.Open(file)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.IsDir() {
		http.NotFound(w, r)
		return
	}
	if immutable {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	} else {
		w.Header().Set("Cache-Control", "no-cache")
	}
	// ServeContent sets Content-Type from the extension, answers Range and If-Modified-Since.
	http.ServeContent(w, r, filepath.Base(file), st.ModTime(), f)
}
