package customapps

import (
	"fmt"
	"path"
	"sort"
	"strings"

	"github.com/evanw/esbuild/pkg/api"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

func Bundle(entry string, files map[string]string) (jsOut string, cssOut string, err error) {
	entry = path.Clean(strings.TrimPrefix(entry, "/"))
	if _, ok := files[entry]; !ok {
		return "", "", apperr.Invalid("manifest", "entry file %q not found", entry)
	}

	var cssOrder []string
	if _, ok := files["styles.css"]; ok {
		cssOrder = append(cssOrder, "styles.css")
	}
	var otherCSS []string
	for name := range files {
		if name != "styles.css" && strings.ToLower(path.Ext(name)) == ".css" {
			otherCSS = append(otherCSS, name)
		}
	}
	sort.Strings(otherCSS)
	cssOrder = append(cssOrder, otherCSS...)
	var cssBuilder strings.Builder
	for i, name := range cssOrder {
		if i > 0 {
			cssBuilder.WriteByte('\n')
		}
		cssBuilder.WriteString(files[name])
	}

	entryWrapper := fmt.Sprintf(`import * as React from "react";
import { createRoot } from "react-dom/client";
import * as EntryMod from "./%s";
const rootEl = document.getElementById("root");
const RootComp = EntryMod.default || EntryMod.App;
if (rootEl && rootEl.childNodes.length === 0 && typeof RootComp === "function") {
  createRoot(rootEl).render(React.createElement(RootComp, null));
}
`, entry)

	plugin := api.Plugin{
		Name: "vesper-custom-app",
		Setup: func(build api.PluginBuild) {
			build.OnResolve(api.OnResolveOptions{Filter: `^__vesper_entry__$`}, func(args api.OnResolveArgs) (api.OnResolveResult, error) {
				return api.OnResolveResult{Path: "__vesper_entry__.tsx", Namespace: "vesper-entry"}, nil
			})
			build.OnLoad(api.OnLoadOptions{Filter: `.*`, Namespace: "vesper-entry"}, func(args api.OnLoadArgs) (api.OnLoadResult, error) {
				return api.OnLoadResult{Contents: &entryWrapper, Loader: api.LoaderTSX}, nil
			})

			build.OnResolve(api.OnResolveOptions{Filter: `^(react(/jsx-dev-runtime|/jsx-runtime)?|react-dom/client|@vesper/bridge)$`}, func(args api.OnResolveArgs) (api.OnResolveResult, error) {
				return api.OnResolveResult{Path: args.Path, Namespace: "vesper-runtime"}, nil
			})
			build.OnLoad(api.OnLoadOptions{Filter: `.*`, Namespace: "vesper-runtime"}, func(args api.OnLoadArgs) (api.OnLoadResult, error) {
				var src string
				switch args.Path {
				case "react":
					src = reactRuntimeJS
				case "react/jsx-runtime", "react/jsx-dev-runtime":
					src = `export { jsx, jsxs, jsxDEV, Fragment } from "react";`
				case "react-dom/client":
					src = `export { createRoot } from "react";`
				case "@vesper/bridge":
					src = bridgeRuntimeJS
				}
				return api.OnLoadResult{Contents: &src, Loader: api.LoaderJS}, nil
			})

			build.OnResolve(api.OnResolveOptions{Filter: `.*`}, func(args api.OnResolveArgs) (api.OnResolveResult, error) {
				if !strings.HasPrefix(args.Path, "./") && !strings.HasPrefix(args.Path, "../") && !strings.HasPrefix(args.Path, "/") {
					return api.OnResolveResult{
						Errors: []api.Message{{Text: fmt.Sprintf("external import %q is not allowed in sandboxed apps; use relative files, react, or @vesper/bridge", args.Path)}},
					}, nil
				}
				baseDir := ""
				if args.Importer != "" && args.Namespace == "vesper-app" {
					baseDir = path.Dir(args.Importer)
				}
				joined := path.Clean(path.Join(baseDir, strings.TrimPrefix(args.Path, "/")))
				candidates := []string{
					joined,
					joined + ".tsx",
					joined + ".ts",
					joined + ".jsx",
					joined + ".js",
					joined + ".json",
					path.Join(joined, "index.tsx"),
					path.Join(joined, "index.ts"),
					path.Join(joined, "index.jsx"),
					path.Join(joined, "index.js"),
				}
				for _, cand := range candidates {
					if _, ok := files[cand]; ok {
						return api.OnResolveResult{Path: cand, Namespace: "vesper-app"}, nil
					}
				}
				return api.OnResolveResult{}, fmt.Errorf("file %q not found", args.Path)
			})

			build.OnLoad(api.OnLoadOptions{Filter: `.*`, Namespace: "vesper-app"}, func(args api.OnLoadArgs) (api.OnLoadResult, error) {
				src, ok := files[args.Path]
				if !ok {
					return api.OnLoadResult{}, fmt.Errorf("missing file %q", args.Path)
				}
				ext := strings.ToLower(path.Ext(args.Path))
				switch ext {
				case ".tsx":
					return api.OnLoadResult{Contents: &src, Loader: api.LoaderTSX}, nil
				case ".ts":
					return api.OnLoadResult{Contents: &src, Loader: api.LoaderTS}, nil
				case ".jsx":
					return api.OnLoadResult{Contents: &src, Loader: api.LoaderJSX}, nil
				case ".js":
					return api.OnLoadResult{Contents: &src, Loader: api.LoaderJS}, nil
				case ".json":
					return api.OnLoadResult{Contents: &src, Loader: api.LoaderJSON}, nil
				case ".css":
					empty := ""
					return api.OnLoadResult{Contents: &empty, Loader: api.LoaderJS}, nil
				case ".sql":
					quoted := fmt.Sprintf("export default %q;", src)
					return api.OnLoadResult{Contents: &quoted, Loader: api.LoaderJS}, nil
				default:
					return api.OnLoadResult{}, fmt.Errorf("cannot import %q", args.Path)
				}
			})
		},
	}

	res := api.Build(api.BuildOptions{
		EntryPoints:     []string{"__vesper_entry__"},
		Bundle:          true,
		Write:           false,
		Format:          api.FormatIIFE,
		Target:          api.ES2022,
		JSX:             api.JSXAutomatic,
		JSXImportSource: "react",
		Plugins:         []api.Plugin{plugin},
	})
	if len(res.Errors) > 0 {
		var msgs []string
		for i, e := range res.Errors {
			if i >= 5 {
				msgs = append(msgs, fmt.Sprintf("...and %d more error(s)", len(res.Errors)-5))
				break
			}
			if e.Location != nil && e.Location.File != "" {
				msgs = append(msgs, fmt.Sprintf("%s:%d:%d: %s", e.Location.File, e.Location.Line, e.Location.Column+1, e.Text))
			} else {
				msgs = append(msgs, e.Text)
			}
		}
		return "", "", apperr.Invalid("files", "compile error: %s", strings.Join(msgs, "; "))
	}
	if len(res.OutputFiles) == 0 {
		return "", "", apperr.Invalid("files", "bundler produced no output")
	}
	return string(res.OutputFiles[0].Contents), cssBuilder.String(), nil
}

const reactRuntimeJS = `
export const Fragment = Symbol.for("vesper.fragment");

export function createElement(type, props, ...children) {
  const p = Object.assign({}, props || {});
  const key = p.key !== undefined ? p.key : null;
  if ("key" in p) delete p.key;
  if (children.length === 1) p.children = children[0];
  else if (children.length > 1) p.children = children;
  return { $$vesper: true, type, props: p, key };
}

export function jsx(type, props, key) {
  const p = Object.assign({}, props || {});
  if ("key" in p) delete p.key;
  return { $$vesper: true, type, props: p, key: key !== undefined ? String(key) : null };
}
export const jsxs = jsx;
export const jsxDEV = jsx;

function flatten(ch, out = []) {
  if (ch == null || typeof ch === "boolean") return out;
  if (Array.isArray(ch)) {
    for (let i = 0; i < ch.length; i++) flatten(ch[i], out);
    return out;
  }
  if (typeof ch === "object" && ch.$$vesper && ch.type === Fragment) {
    return flatten(ch.props ? ch.props.children : null, out);
  }
  if (typeof ch === "object" && ch.$$vesper) {
    out.push(ch);
    return out;
  }
  out.push(String(ch));
  return out;
}

const contextStack = new Map();
export function createContext(defaultValue) {
  const id = Symbol("context");
  function Provider(props) {
    const prev = contextStack.has(id) ? contextStack.get(id) : defaultValue;
    contextStack.set(id, props.value);
    try {
      return createElement(Fragment, null, props.children);
    } finally {
      contextStack.set(id, prev);
    }
  }
  return { id, defaultValue, Provider };
}
export function useContext(ctx) {
  return contextStack.has(ctx.id) ? contextStack.get(ctx.id) : ctx.defaultValue;
}

let activeRoot = null;
let activeInst = null;
let scheduledRoots = new Set();

function scheduleRender(root) {
  if (!scheduledRoots.has(root)) {
    scheduledRoots.add(root);
    queueMicrotask(() => {
      scheduledRoots.delete(root);
      flushRoot(root);
    });
  }
}

function depsChanged(prev, next) {
  if (!prev || !next || prev.length !== next.length) return true;
  for (let i = 0; i < prev.length; i++) {
    if (!Object.is(prev[i], next[i])) return true;
  }
  return false;
}

function ensureHook() {
  if (!activeInst) throw new Error("Hooks can only be called inside a component render");
  const idx = activeInst.idx++;
  if (idx >= activeInst.hooks.length) activeInst.hooks.push(undefined);
  return idx;
}

export function useState(init) {
  const inst = activeInst;
  const root = activeRoot;
  const idx = ensureHook();
  if (inst.hooks[idx] === undefined) {
    const initial = typeof init === "function" ? init() : init;
    const cell = {
      value: initial,
      set(next) {
        const computed = typeof next === "function" ? next(cell.value) : next;
        if (!Object.is(cell.value, computed)) {
          cell.value = computed;
          scheduleRender(root);
        }
      },
    };
    inst.hooks[idx] = cell;
  }
  return [inst.hooks[idx].value, inst.hooks[idx].set];
}

export function useReducer(reducer, init, initFn) {
  const inst = activeInst;
  const root = activeRoot;
  const idx = ensureHook();
  if (inst.hooks[idx] === undefined) {
    const initial = initFn ? initFn(init) : init;
    const cell = {
      value: initial,
      dispatch(action) {
        const next = reducer(cell.value, action);
        if (!Object.is(cell.value, next)) {
          cell.value = next;
          scheduleRender(root);
        }
      },
    };
    inst.hooks[idx] = cell;
  }
  return [inst.hooks[idx].value, inst.hooks[idx].dispatch];
}

export function useRef(init) {
  const inst = activeInst;
  const idx = ensureHook();
  if (inst.hooks[idx] === undefined) inst.hooks[idx] = { current: init };
  return inst.hooks[idx];
}

export function useMemo(factory, deps) {
  const inst = activeInst;
  const idx = ensureHook();
  const prev = inst.hooks[idx];
  if (!prev || depsChanged(prev.deps, deps)) {
    inst.hooks[idx] = { deps, value: factory() };
  }
  return inst.hooks[idx].value;
}

export function useCallback(fn, deps) {
  return useMemo(() => fn, deps);
}

export function useEffect(fn, deps) {
  const inst = activeInst;
  const root = activeRoot;
  const idx = ensureHook();
  const prev = inst.hooks[idx];
  if (!prev || deps === undefined || depsChanged(prev.deps, deps)) {
    const entry = { deps, cleanup: prev ? prev.cleanup : null, fn };
    inst.hooks[idx] = entry;
    root.pendingEffects.push(() => {
      if (typeof entry.cleanup === "function") {
        try { entry.cleanup(); } catch {}
      }
      entry.cleanup = fn() || null;
    });
  }
}
export const useLayoutEffect = useEffect;

const SVG_NS = "http://www.w3.org/2000/svg";
const BOOL_ATTRS = new Set(["disabled", "checked", "selected", "readOnly", "multiple", "required", "hidden", "open"]);

function eventName(prop, el) {
  if (prop === "onChange" && el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA")) {
    const t = (el.getAttribute("type") || "").toLowerCase();
    if (t !== "checkbox" && t !== "radio" && t !== "file") return "input";
  }
  if (prop === "onDoubleClick") return "dblclick";
  return prop.slice(2).toLowerCase();
}

function setProp(el, key, val, prev, isSvg) {
  if (key === "children" || key === "key") return;
  if (key === "ref") {
    if (typeof val === "function") val(el);
    else if (val && typeof val === "object") val.current = el;
    return;
  }
  if (key.startsWith("on") && key.length > 2 && key[2] === key[2].toUpperCase()) {
    const ev = eventName(key, el);
    el._h = el._h || {};
    if (!el._h[ev] && typeof val === "function") {
      el._h[ev] = { fn: val, wrapped: (e) => el._h[ev].fn && el._h[ev].fn(e) };
      el.addEventListener(ev, el._h[ev].wrapped);
    } else if (el._h[ev]) {
      el._h[ev].fn = typeof val === "function" ? val : null;
    }
    return;
  }
  if (key === "style" && val && typeof val === "object") {
    const prevObj = prev && typeof prev === "object" ? prev : {};
    for (const k of Object.keys(prevObj)) {
      if (!(k in val)) el.style[k] = "";
    }
    for (const [k, v] of Object.entries(val)) {
      el.style[k] = v == null ? "" : String(v);
    }
    return;
  }
  if (key === "dangerouslySetInnerHTML" && val && typeof val === "object") {
    el.innerHTML = val.__html || "";
    return;
  }
  const attr = key === "className" ? "class" : key === "htmlFor" ? "for" : key;
  if (key === "value" && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT")) {
    const s = val == null ? "" : String(val);
    if (el.value !== s) el.value = s;
    return;
  }
  if (key === "checked" && el.tagName === "INPUT") {
    const b = !!val;
    if (el.checked !== b) el.checked = b;
    return;
  }
  if (BOOL_ATTRS.has(key)) {
    if (val) el.setAttribute(attr, "");
    else el.removeAttribute(attr);
    return;
  }
  if (val == null || val === false) {
    el.removeAttribute(attr);
    return;
  }
  el.setAttribute(attr, val === true ? "" : String(val));
}

function expandVNode(vnode, path, root, visited) {
  if (vnode == null || typeof vnode === "boolean") return [];
  if (typeof vnode !== "object" || !vnode.$$vesper) return [String(vnode)];
  if (vnode.type === Fragment) {
    const parts = flatten(vnode.props ? vnode.props.children : null);
    const out = [];
    for (let i = 0; i < parts.length; i++) {
      const k = typeof parts[i] === "object" && parts[i].key != null ? parts[i].key : i;
      out.push(...expandVNode(parts[i], path + "." + k, root, visited));
    }
    return out;
  }
  if (typeof vnode.type === "function") {
    let inst = root.instances.get(path);
    if (!inst || inst.fn !== vnode.type) {
      if (inst) cleanupInst(inst);
      inst = { fn: vnode.type, hooks: [], idx: 0 };
      root.instances.set(path, inst);
    }
    inst.idx = 0;
    visited.add(path);
    const prevInst = activeInst;
    const prevRoot = activeRoot;
    activeInst = inst;
    activeRoot = root;
    let rendered;
    try {
      rendered = vnode.type(vnode.props || {});
    } finally {
      activeInst = prevInst;
      activeRoot = prevRoot;
    }
    return expandVNode(rendered, path + ">0", root, visited);
  }
  return [{ ...vnode, _path: path }];
}

function cleanupInst(inst) {
  for (let i = 0; i < inst.hooks.length; i++) {
    const h = inst.hooks[i];
    if (h && typeof h.cleanup === "function") {
      try { h.cleanup(); } catch {}
    }
  }
}

function vnodeKey(v, idx) {
  if (typeof v === "object" && v !== null && v.key != null) return "k:" + v.key;
  return "i:" + idx;
}

function vnodeTag(v) {
  return typeof v === "string" ? "#text" : v.type;
}

function renderDomNode(v, isSvg) {
  if (typeof v === "string") return document.createTextNode(v);
  const childSvg = isSvg || v.type === "svg";
  const el = childSvg ? document.createElementNS(SVG_NS, v.type) : document.createElement(v.type);
  el._vnode = v;
  el._vchildNodes = [];
  for (const [k, val] of Object.entries(v.props || {})) {
    setProp(el, k, val, undefined, childSvg);
  }
  return el;
}

function reconcileChildren(parent, prevList, nextItems, parentPath, root, visited, isSvg) {
  const byKey = new Map();
  for (let i = 0; i < prevList.length; i++) {
    const entry = prevList[i];
    byKey.set(entry.k, entry);
  }
  const nextList = [];
  const used = new Set();
  for (let i = 0; i < nextItems.length; i++) {
    const v = nextItems[i];
    const k = vnodeKey(v, i);
    const match = byKey.get(k);
    let dom;
    if (match && !used.has(match.dom) && match.tag === vnodeTag(v)) {
      dom = match.dom;
      used.add(dom);
      if (typeof v === "string") {
        if (dom.nodeValue !== v) dom.nodeValue = v;
      } else {
        const childSvg = isSvg || v.type === "svg";
        const oldProps = dom._vnode ? dom._vnode.props || {} : {};
        const newProps = v.props || {};
        for (const pk of Object.keys(oldProps)) {
          if (!(pk in newProps) && !pk.startsWith("on") && pk !== "children" && pk !== "key" && pk !== "ref") {
            setProp(dom, pk, null, oldProps[pk], childSvg);
          }
        }
        for (const [pk, pv] of Object.entries(newProps)) {
          if (!Object.is(oldProps[pk], pv) || pk === "value" || pk === "checked") {
            setProp(dom, pk, pv, oldProps[pk], childSvg);
          }
        }
        dom._vnode = v;
        const expanded = [];
        const rawKids = flatten(newProps.children);
        for (let ci = 0; ci < rawKids.length; ci++) {
          const ck = typeof rawKids[ci] === "object" && rawKids[ci].key != null ? rawKids[ci].key : ci;
          expanded.push(...expandVNode(rawKids[ci], (v._path || parentPath) + "." + ck, root, visited));
        }
        reconcileChildren(dom, dom._vchildNodes || [], expanded, (v._path || parentPath), root, visited, childSvg);
      }
    } else {
      dom = renderDomNode(v, isSvg);
      if (typeof v !== "string") {
        const childSvg = isSvg || v.type === "svg";
        const expanded = [];
        const rawKids = flatten(v.props ? v.props.children : null);
        for (let ci = 0; ci < rawKids.length; ci++) {
          const ck = typeof rawKids[ci] === "object" && rawKids[ci].key != null ? rawKids[ci].key : ci;
          expanded.push(...expandVNode(rawKids[ci], (v._path || parentPath) + "." + ck, root, visited));
        }
        reconcileChildren(dom, [], expanded, (v._path || parentPath), root, visited, childSvg);
      }
    }
    const refNode = parent.childNodes[i] || null;
    if (dom !== refNode) parent.insertBefore(dom, refNode);
    nextList.push({ k, tag: vnodeTag(v), dom });
  }
  for (let i = 0; i < prevList.length; i++) {
    if (!used.has(prevList[i].dom) && prevList[i].dom.parentNode === parent) {
      parent.removeChild(prevList[i].dom);
    }
  }
  parent._vchildNodes = nextList;
}

function flushRoot(root) {
  if (!root.element) return;
  const visited = new Set();
  root.pendingEffects = [];
  const items = expandVNode(root.vnode, "r", root, visited);
  reconcileChildren(root.element, root.element._vchildNodes || [], items, "r", root, visited, false);
  for (const [p, inst] of root.instances.entries()) {
    if (!visited.has(p)) {
      cleanupInst(inst);
      root.instances.delete(p);
    }
  }
  const fx = root.pendingEffects.slice();
  root.pendingEffects = [];
  for (let i = 0; i < fx.length; i++) {
    try { fx[i](); } catch (err) { console.error(err); }
  }
}

export function createRoot(container) {
  const root = { element: container, vnode: null, instances: new Map(), pendingEffects: [] };
  return {
    render(vnode) {
      root.vnode = vnode;
      flushRoot(root);
    },
    unmount() {
      for (const inst of root.instances.values()) cleanupInst(inst);
      root.instances.clear();
      if (root.element) {
        root.element._vchildNodes = [];
        root.element.textContent = "";
      }
    },
  };
}
`

const bridgeRuntimeJS = `
import { useState, useEffect, useCallback } from "react";

let seq = 0;
const pending = new Map();
const navListeners = new Set();
const eventListeners = new Set();

window.addEventListener("message", (event) => {
  const msg = event && event.data;
  if (!msg || typeof msg !== "object") return;
  if (msg.type === "vesper:response" && msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    if (msg.ok) resolve(msg.data);
    else reject(new Error(msg.error || "Request failed"));
    return;
  }
  if (msg.type === "vesper:nav-select") {
    for (const fn of navListeners) {
      try { fn(msg.id); } catch {}
    }
    return;
  }
  if (msg.type === "vesper:sse") {
    for (const fn of eventListeners) {
      try { fn(msg.event); } catch {}
    }
  }
});

function callHost(type, payload) {
  return new Promise((resolve, reject) => {
    const id = "req_" + (++seq);
    pending.set(id, { resolve, reject });
    window.parent.postMessage({ channel: "vesper:custom-app", id, type, payload }, "*");
  });
}

export function sql(query, params = []) {
  return callHost("sql", { query, params });
}

export function api(method, path, body) {
  return callHost("api", { method, path, body });
}

export function mcp(connector, tool, args = {}) {
  return callHost("mcp", { connector, tool, arguments: args });
}

export function setNav(items, activeId) {
  window.parent.postMessage({ channel: "vesper:custom-app", type: "set-nav", payload: { items, activeId } }, "*");
}

export function onNavSelect(handler) {
  navListeners.add(handler);
  return () => navListeners.delete(handler);
}

export function askDock(prompt) {
  window.parent.postMessage({ channel: "vesper:custom-app", type: "ask-dock", payload: { prompt } }, "*");
}

export function onEvent(handler) {
  eventListeners.add(handler);
  return () => eventListeners.delete(handler);
}

export function useBridgeQuery(fn, deps = []) {
  const [data, setData] = useState(undefined);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [tick, setTick] = useState(0);
  const refetch = useCallback(() => setTick((t) => t + 1), []);
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    Promise.resolve().then(() => fn()).then(
      (res) => { if (!cancelled) { setData(res); setLoading(false); } },
      (err) => { if (!cancelled) { setError(err instanceof Error ? err.message : String(err)); setLoading(false); } },
    );
    return () => { cancelled = true; };
  }, [...deps, tick]);
  return { data, loading, error, refetch };
}
`
