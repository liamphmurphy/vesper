import Foundation

// MARK: - Phase B: Page-World Scriptlet, YouTube Ad Shield & Extended CSS Runtime

/// Builds the `.atDocumentStart` JavaScript runtime injected into `WKContentWorld.page` for:
/// 1. uBO/AdGuard scriptlets (`set-constant`, `abort-on-property-read/write`, `abort-current-inline-script`,
///    `json-prune`, `json-prune-fetch-response`, `json-prune-xhr-response`, `no-setTimeout-if`,
///    `no-setInterval-if`, `no-fetch-if`, `no-xhr-if`, `prevent-addEventListener`, `nowoif`,
///    `remove-attr`, `remove-class`, `click-element`).
/// 2. Dedicated YouTube Ad Shield (strips `adPlacements`/`playerAds`/`adSlots` from
///    `ytInitialPlayerResponse` and `/youtubei/v1/player`, dismisses enforcement overlays,
///    and fast-forwards/skips any residual ad segments across SPA transitions).
/// 3. Procedural / Extended CSS (`:has-text()`, `:-abp-contains()`, `:upward()`, `:matches-css()`,
///    `:matches-path()`, `:remove()`) and `:style(...)` injection.
///
/// Security boundary:
/// - Receives zero Vesper credentials or `webkit.messageHandlers` access.
/// - Runs inside a closed IIFE leaving zero globals on `window`.
/// - Only emits anonymous integer intervention counts via a `CustomEvent` caught by the isolated
///   `WKContentWorld.defaultClient` bridge (`metricsBridgeScriptSource`).
public enum BrowserAdBlockScripts {
    public static let metricsHandlerName = "vesperAdBlockMetrics"
    private static let metricsEventName = "__vesper_ab_hit__"

    /// Lightweight bridge injected into `WKContentWorld.defaultClient` (invisible to page scripts)
    /// that forwards page-world intervention ticks to Swift for the Shield popover telemetry.
    public static let metricsBridgeScriptSource: String = """
    (function() {
      'use strict';
      var eventName = '\(metricsEventName)';
      document.addEventListener(eventName, function() {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(metricsHandlerName)) {
            window.webkit.messageHandlers.\(metricsHandlerName).postMessage({ hit: 1 });
          }
        } catch (e) {}
      }, true);
    })();
    """

    /// Generates the complete `.atDocumentStart` page-world runtime for a compiled advanced bundle.
    /// Returns `nil` when there are no active scriptlets, extended CSS rules, styles, or YouTube shield.
    public static func makePageRuntimeSource(for bundle: BrowserAdvancedBlockingBundle) -> String? {
        guard !bundle.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(bundle),
              let payloadJSON = String(data: data, encoding: .utf8)
        else { return nil }
        // Escape `</script` defensively in case a rule literal ever contains it.
        let safeJSON = payloadJSON.replacingOccurrences(of: "</", with: "<\\/")

        return """
        (function() {
          'use strict';
          if (window.__vesperAdBlockBooted__) return;
          try {
            Object.defineProperty(window, '__vesperAdBlockBooted__', { value: true, enumerable: false, configurable: false });
          } catch (e) {}

          var BUNDLE = \(safeJSON);
          var METRIC_EVENT = '\(metricsEventName)';
          var host = (location && location.hostname || '').toLowerCase();
          if (!host) return;

          function reportHit(n) {
            var count = Math.max(1, n || 1);
            try {
              for (var i = 0; i < Math.min(count, 10); i++) {
                document.dispatchEvent(new Event(METRIC_EVENT));
              }
            } catch (e) {}
          }

          function hostCoveredBy(hostname, domain) {
            if (!domain) return false;
            var d = domain.toLowerCase();
            return hostname === d || (hostname.length > d.length && hostname.endsWith('.' + d));
          }

          function matchesDomains(includeDomains, excludeDomains) {
            if (excludeDomains && excludeDomains.length) {
              for (var i = 0; i < excludeDomains.length; i++) {
                if (hostCoveredBy(host, excludeDomains[i])) return false;
              }
            }
            if (!includeDomains || !includeDomains.length) return true;
            for (var j = 0; j < includeDomains.length; j++) {
              if (hostCoveredBy(host, includeDomains[j])) return true;
            }
            return false;
          }

          // Respect document/elemhide exception rules from filter lists.
          if (BUNDLE.cosmeticExceptionDomains && BUNDLE.cosmeticExceptionDomains.length) {
            for (var e = 0; e < BUNDLE.cosmeticExceptionDomains.length; e++) {
              if (hostCoveredBy(host, BUNDLE.cosmeticExceptionDomains[e])) return;
            }
          }

          function compileMatcher(raw) {
            if (!raw) return null;
            var s = String(raw).trim();
            if (!s) return null;
            if (s.length >= 2 && s[0] === '/') {
              var lastSlash = s.lastIndexOf('/');
              if (lastSlash > 0) {
                try {
                  return new RegExp(s.slice(1, lastSlash), s.slice(lastSlash + 1));
                } catch (err) {}
              }
            }
            try {
              return new RegExp(s.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'));
            } catch (err) {
              return null;
            }
          }

          // --- Abort Sentinel Guard (keeps console clean for aopr/aopw/acis) ---
          var ABORT_TOKEN = 'vesper_ab_abort_' + Math.random().toString(36).slice(2, 10);
          window.addEventListener('error', function(ev) {
            if (ev && ev.message && String(ev.message).indexOf(ABORT_TOKEN) !== -1) {
              ev.preventDefault();
              ev.stopImmediatePropagation();
            }
          }, true);

          function throwAbort() {
            throw new ReferenceError(ABORT_TOKEN);
          }

          // --- Value Resolver for `set-constant` ---
          function resolveConstant(raw) {
            switch (raw) {
              case 'undefined': return undefined;
              case 'null': return null;
              case 'true': return true;
              case 'false': return false;
              case 'noopFunc': return function() {};
              case 'trueFunc': return function() { return true; };
              case 'falseFunc': return function() { return false; };
              case 'emptyObj': return {};
              case 'emptyArr': return [];
              case 'emptyStr': case "''": case '""': return '';
              case 'noopPromiseResolve': return function() { return Promise.resolve(); };
              case 'noopPromiseReject': return function() { return Promise.reject(); };
              default:
                if (/^-?\\d+(\\.\\d+)?$/.test(raw)) return Number(raw);
                return raw;
            }
          }

          // --- Property Chain Helpers ---
          function setConstantChain(chain, rawValue) {
            if (!chain) return;
            var parts = chain.split('.').filter(Boolean);
            if (!parts.length) return;
            var val = resolveConstant(rawValue);

            function trap(owner, idx) {
              if (!owner || (typeof owner !== 'object' && typeof owner !== 'function')) return;
              var prop = parts[idx];
              if (idx === parts.length - 1) {
                try {
                  Object.defineProperty(owner, prop, {
                    configurable: true,
                    get: function() { return val; },
                    set: function() {}
                  });
                } catch (e) {}
                return;
              }
              var current = owner[prop];
              if (current && typeof current === 'object') {
                trap(current, idx + 1);
                return;
              }
              var backing = current;
              try {
                Object.defineProperty(owner, prop, {
                  configurable: true,
                  get: function() { return backing; },
                  set: function(next) {
                    backing = next;
                    if (next && typeof next === 'object') {
                      trap(next, idx + 1);
                    }
                  }
                });
              } catch (e) {}
            }
            trap(window, 0);
          }

          function abortOnProperty(chain, onWrite) {
            if (!chain) return;
            var parts = chain.split('.').filter(Boolean);
            if (!parts.length) return;
            function trap(owner, idx) {
              if (!owner || (typeof owner !== 'object' && typeof owner !== 'function')) return;
              var prop = parts[idx];
              if (idx === parts.length - 1) {
                var value = owner[prop];
                try {
                  Object.defineProperty(owner, prop, {
                    configurable: true,
                    get: function() {
                      if (!onWrite) { reportHit(1); throwAbort(); }
                      return value;
                    },
                    set: function(next) {
                      if (onWrite) { reportHit(1); throwAbort(); }
                      value = next;
                    }
                  });
                } catch (e) {}
                return;
              }
              var cur = owner[prop];
              if (cur && typeof cur === 'object') {
                trap(cur, idx + 1);
              } else {
                var backing = cur;
                try {
                  Object.defineProperty(owner, prop, {
                    configurable: true,
                    get: function() { return backing; },
                    set: function(next) {
                      backing = next;
                      if (next && typeof next === 'object') trap(next, idx + 1);
                    }
                  });
                } catch (e) {}
              }
            }
            trap(window, 0);
          }

          function abortCurrentInlineScript(chain, searchRaw) {
            if (!chain) return;
            var matcher = compileMatcher(searchRaw);
            var parts = chain.split('.').filter(Boolean);
            if (!parts.length) return;
            var prop = parts[parts.length - 1];
            var owner = window;
            for (var i = 0; i < parts.length - 1; i++) {
              if (!owner[parts[i]]) return;
              owner = owner[parts[i]];
            }
            var val = owner[prop];
            try {
              Object.defineProperty(owner, prop, {
                configurable: true,
                get: function() {
                  var cs = document.currentScript;
                  if (cs && (!matcher || matcher.test(cs.textContent || ''))) {
                    reportHit(1);
                    throwAbort();
                  }
                  return val;
                },
                set: function(next) { val = next; }
              });
            } catch (e) {}
          }

          // --- JSON Pruning Core (shared by json-prune & YouTube Ad Shield) ---
          var jsonPruneSpecs = [];
          var fetchPruneSpecs = [];
          var xhrPruneSpecs = [];

          function deletePath(obj, pathParts, idx) {
            if (!obj || typeof obj !== 'object') return false;
            var key = pathParts[idx];
            var removed = false;
            if (key === '*' || key === '[]') {
              var keys = Array.isArray(obj) ? obj.map(function(_, i) { return i; }) : Object.keys(obj);
              for (var k = 0; k < keys.length; k++) {
                if (idx === pathParts.length - 1) {
                  delete obj[keys[k]];
                  removed = true;
                } else if (deletePath(obj[keys[k]], pathParts, idx + 1)) {
                  removed = true;
                }
              }
              return removed;
            }
            if (!(key in obj)) return false;
            if (idx === pathParts.length - 1) {
              delete obj[key];
              return true;
            }
            return deletePath(obj[key], pathParts, idx + 1);
          }

          function hasPath(obj, pathParts) {
            var cur = obj;
            for (var i = 0; i < pathParts.length; i++) {
              if (!cur || typeof cur !== 'object' || !(pathParts[i] in cur)) return false;
              cur = cur[pathParts[i]];
            }
            return true;
          }

          function pruneJSONObject(root, specs) {
            if (!root || typeof root !== 'object' || !specs.length) return root;
            var totalPruned = 0;
            for (var s = 0; s < specs.length; s++) {
              var spec = specs[s];
              if (spec.requiredPaths.length) {
                var allPresent = true;
                for (var r = 0; r < spec.requiredPaths.length; r++) {
                  if (!hasPath(root, spec.requiredPaths[r])) { allPresent = false; break; }
                }
                if (!allPresent) continue;
              }
              for (var p = 0; p < spec.removePaths.length; p++) {
                if (deletePath(root, spec.removePaths[p], 0)) {
                  totalPruned++;
                }
              }
            }
            if (totalPruned > 0) reportHit(1);
            return root;
          }

          function parsePrunePaths(raw) {
            if (!raw) return [];
            return String(raw).trim().split(/\\s+/).filter(Boolean).map(function(p) { return p.split('.'); });
          }

          function installJSONPruneHooks() {
            if (jsonPruneSpecs.length) {
              var origParse = JSON.parse;
              JSON.parse = function() {
                var parsed = origParse.apply(this, arguments);
                return pruneJSONObject(parsed, jsonPruneSpecs);
              };
              if (typeof Response !== 'undefined' && Response.prototype && Response.prototype.json) {
                var origRespJson = Response.prototype.json;
                Response.prototype.json = function() {
                  return origRespJson.apply(this, arguments).then(function(data) {
                    return pruneJSONObject(data, jsonPruneSpecs);
                  });
                };
              }
            }

            if (fetchPruneSpecs.length && typeof window.fetch === 'function') {
              var origFetch = window.fetch;
              window.fetch = function(input, init) {
                var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
                var matched = fetchPruneSpecs.filter(function(sp) {
                  return !sp.urlMatcher || sp.urlMatcher.test(url);
                });
                var promise = origFetch.apply(this, arguments);
                if (!matched.length) return promise;
                return promise.then(function(response) {
                  try {
                    var cloned = response.clone();
                    return cloned.text().then(function(bodyText) {
                      try {
                        var obj = JSON.parse(bodyText);
                        pruneJSONObject(obj, matched);
                        var headers = new Headers(response.headers);
                        headers.delete('content-length');
                        return new Response(JSON.stringify(obj), {
                          status: response.status,
                          statusText: response.statusText,
                          headers: headers
                        });
                      } catch (e) {
                        return response;
                      }
                    }).catch(function() { return response; });
                  } catch (e) {
                    return response;
                  }
                });
              };
            }

            if (xhrPruneSpecs.length && typeof XMLHttpRequest !== 'undefined') {
              var origOpen = XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open = function(method, url) {
                this.__vesperUrl = String(url || '');
                return origOpen.apply(this, arguments);
              };
              var descText = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'responseText');
              if (descText && descText.get) {
                Object.defineProperty(XMLHttpRequest.prototype, 'responseText', {
                  configurable: true,
                  get: function() {
                    var raw = descText.get.call(this);
                    var url = this.__vesperUrl || '';
                    var matched = xhrPruneSpecs.filter(function(sp) {
                      return !sp.urlMatcher || sp.urlMatcher.test(url);
                    });
                    if (!matched.length || !raw) return raw;
                    try {
                      var obj = JSON.parse(raw);
                      pruneJSONObject(obj, matched);
                      return JSON.stringify(obj);
                    } catch (e) {
                      return raw;
                    }
                  }
                });
              }
            }
          }

          // --- Timer / Fetch / XHR / EventListener / Window.open Defusers ---
          var blockedTimeoutRules = [];
          var blockedIntervalRules = [];
          var blockedFetchMatchers = [];
          var blockedXHRMatchers = [];
          var blockedEventRules = [];
          var blockedPopupMatchers = [];
          var removeAttrRules = [];
          var removeClassRules = [];
          var clickSelectors = [];

          // --- Execute Matching Scriptlets ---
          var scriptlets = BUNDLE.scriptlets || [];
          for (var i = 0; i < scriptlets.length; i++) {
            var sc = scriptlets[i];
            if (!matchesDomains(sc.includeDomains, sc.excludeDomains)) continue;
            var args = sc.args || [];
            switch (sc.name) {
              case 'set-constant':
                setConstantChain(args[0], args[1]);
                break;
              case 'abort-on-property-read':
                abortOnProperty(args[0], false);
                break;
              case 'abort-on-property-write':
                abortOnProperty(args[0], true);
                break;
              case 'abort-current-inline-script':
                abortCurrentInlineScript(args[0], args[1]);
                break;
              case 'json-prune':
                jsonPruneSpecs.push({
                  removePaths: parsePrunePaths(args[0]),
                  requiredPaths: parsePrunePaths(args[1])
                });
                break;
              case 'json-prune-fetch-response':
                fetchPruneSpecs.push({
                  removePaths: parsePrunePaths(args[0]),
                  requiredPaths: parsePrunePaths(args[1]),
                  urlMatcher: compileMatcher(args[3] || args[2])
                });
                break;
              case 'json-prune-xhr-response':
                xhrPruneSpecs.push({
                  removePaths: parsePrunePaths(args[0]),
                  requiredPaths: parsePrunePaths(args[1]),
                  urlMatcher: compileMatcher(args[3] || args[2])
                });
                break;
              case 'no-setTimeout-if':
                blockedTimeoutRules.push({ matcher: compileMatcher(args[0]), delay: args[1] ? Number(args[1]) : null });
                break;
              case 'no-setInterval-if':
                blockedIntervalRules.push({ matcher: compileMatcher(args[0]), delay: args[1] ? Number(args[1]) : null });
                break;
              case 'no-fetch-if':
                if (args[0]) { var fm = compileMatcher(args[0]); if (fm) blockedFetchMatchers.push(fm); }
                break;
              case 'no-xhr-if':
                if (args[0]) { var xm = compileMatcher(args[0]); if (xm) blockedXHRMatchers.push(xm); }
                break;
              case 'prevent-addEventListener':
                blockedEventRules.push({ type: compileMatcher(args[0]), handler: compileMatcher(args[1]) });
                break;
              case 'nowoif':
                blockedPopupMatchers.push(compileMatcher(args[0]));
                break;
              case 'remove-attr':
                if (args[0]) removeAttrRules.push({ attr: args[0], selector: args[1] || '*' });
                break;
              case 'remove-class':
                if (args[0]) removeClassRules.push({ cls: args[0], selector: args[1] || '*' });
                break;
              case 'click-element':
                if (args[0]) clickSelectors.push(args[0]);
                break;
              default:
                break;
            }
          }

          // --- Dedicated YouTube Ad Shield ---
          var isYouTube = hostCoveredBy(host, 'youtube.com') || hostCoveredBy(host, 'youtu.be');
          if (BUNDLE.youtubeAdShieldEnabled && isYouTube) {
            var ytAdKeys = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];
            var ytPruneSpec = {
              removePaths: ytAdKeys.map(function(k) { return [k]; }),
              requiredPaths: []
            };
            jsonPruneSpecs.push(ytPruneSpec);
            fetchPruneSpecs.push({
              removePaths: ytPruneSpec.removePaths,
              requiredPaths: [],
              urlMatcher: /\\/youtubei\\/v1\\/(player|next)/
            });

            // Trap `window.ytInitialPlayerResponse` before YouTube's player script reads it.
            var ytBacking = window.ytInitialPlayerResponse;
            if (ytBacking && typeof ytBacking === 'object') {
              pruneJSONObject(ytBacking, [ytPruneSpec]);
            }
            try {
              Object.defineProperty(window, 'ytInitialPlayerResponse', {
                configurable: true,
                get: function() { return ytBacking; },
                set: function(next) {
                  if (next && typeof next === 'object') {
                    pruneJSONObject(next, [ytPruneSpec]);
                  }
                  ytBacking = next;
                }
              });
            } catch (e) {}

            function sweepYouTubeAds() {
              try {
                // Dismiss anti-adblock enforcement dialogs and resume playback.
                var enforcements = document.querySelectorAll('ytd-enforcement-message-view-model');
                if (enforcements.length) {
                  enforcements.forEach(function(el) {
                    var dialog = el.closest('tp-yt-paper-dialog') || el;
                    dialog.remove();
                  });
                  var backdrop = document.querySelector('tp-yt-iron-overlay-backdrop');
                  if (backdrop) backdrop.remove();
                  var mainVideo = document.querySelector('video.html5-main-video');
                  if (mainVideo && mainVideo.paused) {
                    mainVideo.play().catch(function() {});
                  }
                  reportHit(1);
                }

                // Fast-forward and skip any residual ad segment inside `#movie_player`.
                var player = document.getElementById('movie_player');
                if (player && (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'))) {
                  var vid = player.querySelector('video');
                  if (vid) {
                    vid.muted = true;
                    if (isFinite(vid.duration) && vid.duration > 0 && vid.currentTime < vid.duration - 0.1) {
                      vid.currentTime = vid.duration;
                    }
                  }
                  var skipBtn = player.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button');
                  if (skipBtn && typeof skipBtn.click === 'function') {
                    skipBtn.click();
                  }
                  reportHit(1);
                }
              } catch (e) {}
            }

            window.addEventListener('yt-navigate-finish', sweepYouTubeAds, true);
            document.addEventListener('DOMContentLoaded', function() {
              sweepYouTubeAds();
              setInterval(sweepYouTubeAds, 600);
            }, { once: true });
          }

          installJSONPruneHooks();

          if (blockedTimeoutRules.length) {
            var origSetTimeout = window.setTimeout;
            window.setTimeout = function(fn, delay) {
              var src = typeof fn === 'function' ? Function.prototype.toString.call(fn) : String(fn || '');
              for (var t = 0; t < blockedTimeoutRules.length; t++) {
                var rule = blockedTimeoutRules[t];
                if (rule.matcher && rule.matcher.test(src) && (rule.delay === null || Number(delay) === rule.delay)) {
                  reportHit(1);
                  return 0;
                }
              }
              return origSetTimeout.apply(this, arguments);
            };
          }

          if (blockedIntervalRules.length) {
            var origSetInterval = window.setInterval;
            window.setInterval = function(fn, delay) {
              var src = typeof fn === 'function' ? Function.prototype.toString.call(fn) : String(fn || '');
              for (var t = 0; t < blockedIntervalRules.length; t++) {
                var rule = blockedIntervalRules[t];
                if (rule.matcher && rule.matcher.test(src) && (rule.delay === null || Number(delay) === rule.delay)) {
                  reportHit(1);
                  return 0;
                }
              }
              return origSetInterval.apply(this, arguments);
            };
          }

          if (blockedFetchMatchers.length && typeof window.fetch === 'function') {
            var prevFetch = window.fetch;
            window.fetch = function(input) {
              var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
              for (var f = 0; f < blockedFetchMatchers.length; f++) {
                if (blockedFetchMatchers[f].test(url)) {
                  reportHit(1);
                  return Promise.resolve(new Response('', { status: 200 }));
                }
              }
              return prevFetch.apply(this, arguments);
            };
          }

          if (blockedXHRMatchers.length && typeof XMLHttpRequest !== 'undefined') {
            var prevOpen = XMLHttpRequest.prototype.open;
            var prevSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
              var u = String(url || '');
              this.__vesperBlockedXHR = blockedXHRMatchers.some(function(m) { return m.test(u); });
              return prevOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
              if (this.__vesperBlockedXHR) {
                reportHit(1);
                return;
              }
              return prevSend.apply(this, arguments);
            };
          }

          if (blockedEventRules.length) {
            var origAdd = EventTarget.prototype.addEventListener;
            EventTarget.prototype.addEventListener = function(type, listener) {
              var fnStr = typeof listener === 'function' ? Function.prototype.toString.call(listener) : '';
              for (var r = 0; r < blockedEventRules.length; r++) {
                var er = blockedEventRules[r];
                var typeOK = !er.type || er.type.test(String(type || ''));
                var fnOK = !er.handler || er.handler.test(fnStr);
                if (typeOK && fnOK) {
                  reportHit(1);
                  return;
                }
              }
              return origAdd.apply(this, arguments);
            };
          }

          if (blockedPopupMatchers.length) {
            var origWindowOpen = window.open;
            window.open = function(url) {
              var u = String(url || '');
              for (var p = 0; p < blockedPopupMatchers.length; p++) {
                if (!blockedPopupMatchers[p] || blockedPopupMatchers[p].test(u)) {
                  reportHit(1);
                  return null;
                }
              }
              return origWindowOpen.apply(this, arguments);
            };
          }

          // --- Style Injection (`:style(...)`) ---
          var activeStyles = (BUNDLE.injectedStyles || []).filter(function(st) {
            return matchesDomains(st.includeDomains, st.excludeDomains);
          });

          function injectStyleSheet() {
            if (!activeStyles.length) return;
            if (document.querySelector('style[data-vesper-adblock="1"]')) return;
            var cssText = activeStyles.map(function(st) {
              return st.selector + ' { ' + st.cssBody + ' }';
            }).join('\\n');
            var el = document.createElement('style');
            el.setAttribute('data-vesper-adblock', '1');
            el.textContent = cssText;
            (document.head || document.documentElement).appendChild(el);
          }

          // --- Procedural / Extended CSS Engine ---
          var activeExtended = (BUNDLE.extendedCSS || []).filter(function(rule) {
            return matchesDomains(rule.includeDomains, rule.excludeDomains);
          });

          function parseProceduralChain(raw) {
            // Splits `baseSelector:has-text(...):upward(2):matches-css(...)` into base + ordered operators.
            var ops = [];
            var known = [':has-text(', ':-abp-contains(', ':upward(', ':matches-css(', ':matches-path('];
            var firstIdx = -1;
            for (var k = 0; k < known.length; k++) {
              var pos = raw.indexOf(known[k]);
              if (pos !== -1 && (firstIdx === -1 || pos < firstIdx)) firstIdx = pos;
            }
            if (firstIdx === -1) return { base: raw.trim(), ops: [] };
            var base = raw.slice(0, firstIdx).trim() || '*';
            var rest = raw.slice(firstIdx);

            while (rest.length) {
              var matchedOp = null;
              for (var m = 0; m < known.length; m++) {
                if (rest.startsWith(known[m])) { matchedOp = known[m]; break; }
              }
              if (!matchedOp) break;
              var depth = 0;
              var endIdx = -1;
              for (var c = matchedOp.length - 1; c < rest.length; c++) {
                if (rest[c] === '(') depth++;
                else if (rest[c] === ')') {
                  depth--;
                  if (depth === 0) { endIdx = c; break; }
                }
              }
              if (endIdx === -1) break;
              var arg = rest.slice(matchedOp.length, endIdx);
              ops.push({ name: matchedOp.slice(1, -1), arg: arg });
              rest = rest.slice(endIdx + 1).trim();
            }
            return { base: base, ops: ops };
          }

          var compiledProcedural = activeExtended.map(function(rule) {
            var parsed = parseProceduralChain(rule.selector);
            return {
              base: parsed.base,
              ops: parsed.ops.map(function(op) {
                if (op.name === 'has-text' || op.name === '-abp-contains' || op.name === 'matches-path') {
                  return { name: op.name, matcher: compileMatcher(op.arg), raw: op.arg };
                }
                return { name: op.name, raw: op.arg };
              }),
              removeNode: !!rule.removeNode
            };
          });

          var clickedOnce = new WeakSet();

          function applyDOMRules() {
            injectStyleSheet();

            // remove-attr / remove-class
            for (var a = 0; a < removeAttrRules.length; a++) {
              try {
                var nodes = document.querySelectorAll(removeAttrRules[a].selector);
                for (var n = 0; n < nodes.length; n++) {
                  if (nodes[n].hasAttribute(removeAttrRules[a].attr)) {
                    nodes[n].removeAttribute(removeAttrRules[a].attr);
                    reportHit(1);
                  }
                }
              } catch (e) {}
            }
            for (var c = 0; c < removeClassRules.length; c++) {
              try {
                var cnodes = document.querySelectorAll(removeClassRules[c].selector);
                for (var cn = 0; cn < cnodes.length; cn++) {
                  if (cnodes[cn].classList && cnodes[cn].classList.contains(removeClassRules[c].cls)) {
                    cnodes[cn].classList.remove(removeClassRules[c].cls);
                    reportHit(1);
                  }
                }
              } catch (e) {}
            }

            // click-element (once per matched button)
            for (var cl = 0; cl < clickSelectors.length; cl++) {
              try {
                var btn = document.querySelector(clickSelectors[cl]);
                if (btn && !clickedOnce.has(btn) && typeof btn.click === 'function') {
                  clickedOnce.add(btn);
                  btn.click();
                  reportHit(1);
                }
              } catch (e) {}
            }

            // Extended / Procedural CSS
            if (!compiledProcedural.length) return;
            var currentPath = (location.pathname || '') + (location.search || '');
            for (var p = 0; p < compiledProcedural.length; p++) {
              var rule = compiledProcedural[p];
              var candidates;
              try {
                candidates = document.querySelectorAll(rule.base);
              } catch (e) {
                continue;
              }
              for (var idx = 0; idx < candidates.length; idx++) {
                var target = candidates[idx];
                if (!target || target.nodeType !== 1) continue;
                if (target.getAttribute('data-vesper-ab-hidden') === '1') continue;

                var matched = true;
                for (var o = 0; o < rule.ops.length; o++) {
                  var op = rule.ops[o];
                  if (op.name === 'matches-path') {
                    if (op.matcher && !op.matcher.test(currentPath)) { matched = false; break; }
                  } else if (op.name === 'has-text' || op.name === '-abp-contains') {
                    var txt = (target.textContent || '').trim();
                    if (!op.matcher || !op.matcher.test(txt)) { matched = false; break; }
                  } else if (op.name === 'matches-css') {
                    var colon = op.raw.indexOf(':');
                    if (colon === -1) { matched = false; break; }
                    var prop = op.raw.slice(0, colon).trim();
                    var expected = op.raw.slice(colon + 1).trim();
                    var actual = window.getComputedStyle(target).getPropertyValue(prop).trim();
                    var cssMatcher = compileMatcher(expected);
                    if (!cssMatcher || !cssMatcher.test(actual)) { matched = false; break; }
                  } else if (op.name === 'upward') {
                    var steps = Number(op.raw);
                    if (!isNaN(steps) && steps > 0) {
                      var cur = target;
                      for (var st = 0; st < steps && cur; st++) cur = cur.parentElement;
                      if (!cur) { matched = false; break; }
                      target = cur;
                    } else if (op.raw) {
                      var ancestor = target.closest(op.raw);
                      if (!ancestor) { matched = false; break; }
                      target = ancestor;
                    }
                  }
                }

                if (!matched || !target || target.getAttribute('data-vesper-ab-hidden') === '1') continue;
                if (rule.removeNode) {
                  target.remove();
                } else {
                  target.setAttribute('data-vesper-ab-hidden', '1');
                  target.style.setProperty('display', 'none', 'important');
                }
                reportHit(1);
              }
            }
          }

          var needsDOMLoop = activeStyles.length || compiledProcedural.length || removeAttrRules.length || removeClassRules.length || clickSelectors.length;
          if (needsDOMLoop) {
            var pendingTimer = null;
            function scheduleDOMApply() {
              if (pendingTimer) return;
              pendingTimer = setTimeout(function() {
                pendingTimer = null;
                applyDOMRules();
              }, 120);
            }

            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', function() {
                applyDOMRules();
                if (document.documentElement && typeof MutationObserver !== 'undefined') {
                  var obs = new MutationObserver(scheduleDOMApply);
                  obs.observe(document.documentElement, { childList: true, subtree: true });
                }
              }, { once: true });
            } else {
              applyDOMRules();
              if (document.documentElement && typeof MutationObserver !== 'undefined') {
                var obs = new MutationObserver(scheduleDOMApply);
                obs.observe(document.documentElement, { childList: true, subtree: true });
              }
            }
            window.addEventListener('popstate', scheduleDOMApply, true);
            window.addEventListener('yt-navigate-finish', scheduleDOMApply, true);
          }
        })();
        """
    }
}
