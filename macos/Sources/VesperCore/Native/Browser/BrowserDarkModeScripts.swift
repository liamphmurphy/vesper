import Foundation

// MARK: - Auto Dark Mode WebKit Engine (Isolated `.defaultClient` World)

/// Builds the `.atDocumentStart` JavaScript runtime and live-update calls for Vesper's
/// Noir/Dark Reader-style Auto Dark Mode.
///
/// Design & Security:
/// - Runs exclusively in `WKContentWorld.defaultClient`, completely isolated from page scripts
///   (zero globals leaked onto the page's `window`, zero CSP conflicts).
/// - Injects the stylesheet synchronously at `.atDocumentStart` before first paint so light pages
///   never flash white during navigation.
/// - Detects sites that already implement a native dark theme (by measuring true unpainted/painted
///   root background luminance and `color-scheme`) and automatically backs off unless forced.
/// - Preserves photos, videos, canvases, iframes, SVG images, and CSS `background-image: url(...)`
///   banners via counter-inversion, with optional subtle dimming that restores on hover.
/// - Exposes a `.defaultClient`-only update hook so theme, slider, per-site, and macOS appearance
///   changes apply instantaneously across all open tabs with zero page reload.
public enum BrowserDarkModeScripts {
    public static let handlerName = "vesperDarkMode"

    private struct ScriptPayload: Encodable {
        let enabled: Bool
        let forceOverride: Bool
        let respectNativeDarkMode: Bool
        let dimImages: Bool
        let backgroundHex: String
        let rootFilter: String
        let mediaFilter: String
        let mediaHoverFilter: String
    }

    private static func makePayload(for state: BrowserDarkModeEffectiveState) -> ScriptPayload {
        let effBrightness = (state.theme.baseBrightness * state.brightness * 1000).rounded() / 1000
        let effContrast = (state.theme.baseContrast * state.contrast * 1000).rounded() / 1000
        let hueDeg = 180.0 + state.theme.hueOffsetDegrees
        var rootParts = [
            "invert(1)",
            String(format: "hue-rotate(%.0fdeg)", hueDeg),
            String(format: "brightness(%.3f)", effBrightness),
            String(format: "contrast(%.3f)", effContrast),
        ]
        if state.theme.sepiaAmount > 0 {
            rootParts.append(String(format: "sepia(%.2f)", state.theme.sepiaAmount))
        }
        let mediaInvertDeg = 180.0 - state.theme.hueOffsetDegrees
        let baseMedia = String(format: "invert(1) hue-rotate(%.0fdeg)", mediaInvertDeg)
        let mediaFilter = state.dimImages ? "\(baseMedia) brightness(0.88)" : baseMedia
        let mediaHoverFilter = baseMedia

        return ScriptPayload(
            enabled: state.enabled,
            forceOverride: state.forceOverride,
            respectNativeDarkMode: state.respectNativeDarkMode,
            dimImages: state.dimImages,
            backgroundHex: state.theme.backgroundHex,
            rootFilter: rootParts.joined(separator: " "),
            mediaFilter: mediaFilter,
            mediaHoverFilter: mediaHoverFilter
        )
    }

    private static func encodePayloadJSON(for state: BrowserDarkModeEffectiveState) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(makePayload(for: state)),
              let raw = String(data: data, encoding: .utf8)
        else { return "{}" }
        return raw.replacingOccurrences(of: "</", with: "<\\/")
    }

    /// Generates the `.atDocumentStart` runtime script for `WKContentWorld.defaultClient`.
    public static func makeUserScriptSource(for state: BrowserDarkModeEffectiveState) -> String {
        let payloadJSON = encodePayloadJSON(for: state)
        return """
        (function() {
          'use strict';
          var STYLE_ID = '__vesper_dark_mode_style__';
          var ATTR_ACTIVE = 'data-vesper-dark';
          var ATTR_BGIMG = 'data-vesper-dark-bgimg';
          var HANDLER = '\(handlerName)';
          var currentCfg = \(payloadJSON);
          var lastReportedStatus = null;
          var bgScanScheduled = false;
          var nativeCheckScheduled = false;
          var observerInstalled = false;

          function postStatus(status) {
            if (status === lastReportedStatus) return;
            lastReportedStatus = status;
            try {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[HANDLER]) {
                window.webkit.messageHandlers[HANDLER].postMessage({ status: status });
              }
            } catch (e) {}
          }

          function parseRGB(str) {
            if (!str || str === 'transparent') return null;
            var m = str.match(/rgba?\\(\\s*(\\d+(?:\\.\\d+)?)\\s*,\\s*(\\d+(?:\\.\\d+)?)\\s*,\\s*(\\d+(?:\\.\\d+)?)(?:\\s*,\\s*(\\d+(?:\\.\\d+)?))?\\s*\\)/i);
            if (!m) return null;
            var a = m[4] !== undefined ? parseFloat(m[4]) : 1;
            if (a < 0.08) return null;
            return { r: parseFloat(m[1]), g: parseFloat(m[2]), b: parseFloat(m[3]), a: a };
          }

          function relativeLuminance(rgb) {
            function chan(v) {
              var s = v / 255;
              return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
            }
            return 0.2126 * chan(rgb.r) + 0.7152 * chan(rgb.g) + 0.0722 * chan(rgb.b);
          }

          function detectNativeDarkMode() {
            var root = document.documentElement;
            if (!root) return false;

            // Temporarily clear our attribute synchronously within the same frame to sample
            // the page's authentic background color without visible flicker.
            var wasActive = root.getAttribute(ATTR_ACTIVE) === '1';
            if (wasActive) root.removeAttribute(ATTR_ACTIVE);
            var isNativeDark = false;
            try {
              var rootStyle = window.getComputedStyle(root);
              var bodyStyle = document.body ? window.getComputedStyle(document.body) : null;
              var bodyRGB = bodyStyle ? parseRGB(bodyStyle.backgroundColor) : null;
              var rootRGB = parseRGB(rootStyle.backgroundColor);
              var paintedRGB = bodyRGB || rootRGB;

              if (paintedRGB) {
                if (relativeLuminance(paintedRGB) < 0.28) {
                  isNativeDark = true;
                }
              } else {
                // Transparent canvas: check if the site declares dark color-scheme while WebKit is dark.
                var cs = ((bodyStyle && bodyStyle.colorScheme) || rootStyle.colorScheme || '').toLowerCase();
                var meta = document.querySelector('meta[name="color-scheme"]');
                var metaContent = meta ? (meta.getAttribute('content') || '').toLowerCase() : '';
                var prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
                if (prefersDark && ((cs.indexOf('dark') !== -1 && cs.indexOf('only light') === -1) || (metaContent.indexOf('dark') !== -1 && metaContent.indexOf('only light') === -1))) {
                  isNativeDark = true;
                }
              }

              // Also check primary text luminance when background is near-transparent on dark apps.
              if (!isNativeDark && bodyStyle && !paintedRGB) {
                var textRGB = parseRGB(bodyStyle.color);
                if (textRGB && relativeLuminance(textRGB) > 0.65) {
                  isNativeDark = true;
                }
              }
            } catch (e) {
              isNativeDark = false;
            }
            if (wasActive && !isNativeDark) {
              root.setAttribute(ATTR_ACTIVE, '1');
            }
            return isNativeDark;
          }

          function buildCSS(cfg) {
            return [
              'html[' + ATTR_ACTIVE + '="1"] {',
              '  background-color: ' + cfg.backgroundHex + ' !important;',
              '  color-scheme: dark !important;',
              '  filter: ' + cfg.rootFilter + ' !important;',
              '}',
              'html[' + ATTR_ACTIVE + '="1"] img,',
              'html[' + ATTR_ACTIVE + '="1"] video,',
              'html[' + ATTR_ACTIVE + '="1"] canvas,',
              'html[' + ATTR_ACTIVE + '="1"] iframe,',
              'html[' + ATTR_ACTIVE + '="1"] embed,',
              'html[' + ATTR_ACTIVE + '="1"] object,',
              'html[' + ATTR_ACTIVE + '="1"] svg image,',
              'html[' + ATTR_ACTIVE + '="1"] [' + ATTR_BGIMG + '="1"] {',
              '  filter: ' + cfg.mediaFilter + ' !important;',
              '}',
              cfg.dimImages ? [
                'html[' + ATTR_ACTIVE + '="1"] img:hover,',
                'html[' + ATTR_ACTIVE + '="1"] video:hover,',
                'html[' + ATTR_ACTIVE + '="1"] [' + ATTR_BGIMG + '="1"]:hover {',
                '  filter: ' + cfg.mediaHoverFilter + ' !important;',
                '}'
              ].join('\\n') : '',
              'html[' + ATTR_ACTIVE + '="1"] [' + ATTR_BGIMG + '="1"] img,',
              'html[' + ATTR_ACTIVE + '="1"] [' + ATTR_BGIMG + '="1"] video,',
              'html[' + ATTR_ACTIVE + '="1"] [' + ATTR_BGIMG + '="1"] canvas {',
              '  filter: none !important;',
              '}',
              'html[' + ATTR_ACTIVE + '="1"] #__vesper_reader_overlay__ {',
              '  filter: invert(1) hue-rotate(180deg) !important;',
              '}'
            ].join('\\n');
          }

          function ensureStyleElement(cfg) {
            var root = document.documentElement;
            if (!root) return;
            var style = document.getElementById(STYLE_ID);
            if (!style) {
              style = document.createElement('style');
              style.id = STYLE_ID;
              (document.head || root).appendChild(style);
            }
            var nextText = buildCSS(cfg);
            if (style.textContent !== nextText) {
              style.textContent = nextText;
            }
          }

          function removeDarkMode() {
            var root = document.documentElement;
            if (root) root.removeAttribute(ATTR_ACTIVE);
            var style = document.getElementById(STYLE_ID);
            if (style) style.remove();
          }

          function tagBackgroundImages(rootNode) {
            if (!rootNode || !document.documentElement || document.documentElement.getAttribute(ATTR_ACTIVE) !== '1') return;
            try {
              var nodes = rootNode.querySelectorAll ? rootNode.querySelectorAll('[style*="background"], div, section, header, figure, a, span') : [];
              var limit = Math.min(nodes.length, 400);
              for (var i = 0; i < limit; i++) {
                var el = nodes[i];
                if (!el || el.hasAttribute(ATTR_BGIMG)) continue;
                var bg = window.getComputedStyle(el).backgroundImage;
                if (bg && bg.indexOf('url(') !== -1 && bg.indexOf('data:image/svg+xml') === -1) {
                  var rect = el.getBoundingClientRect();
                  if (rect.width >= 36 && rect.height >= 36) {
                    el.setAttribute(ATTR_BGIMG, '1');
                  }
                }
              }
            } catch (e) {}
          }

          function scheduleBackgroundScan() {
            if (bgScanScheduled) return;
            bgScanScheduled = true;
            window.requestAnimationFrame(function() {
              bgScanScheduled = false;
              tagBackgroundImages(document.body || document.documentElement);
            });
          }

          function evaluateAndApply(cfg, allowNativeCheck) {
            currentCfg = cfg;
            if (!cfg || !cfg.enabled) {
              removeDarkMode();
              postStatus('inactive');
              return;
            }

            if (allowNativeCheck && cfg.respectNativeDarkMode && !cfg.forceOverride && document.body) {
              if (detectNativeDarkMode()) {
                removeDarkMode();
                postStatus('skipped_native');
                return;
              }
            }

            ensureStyleElement(cfg);
            if (document.documentElement) {
              document.documentElement.setAttribute(ATTR_ACTIVE, '1');
            }
            postStatus('applied');
            if (document.body) {
              scheduleBackgroundScan();
            }
          }

          function scheduleNativeRecheck() {
            if (nativeCheckScheduled || !currentCfg || !currentCfg.enabled) return;
            nativeCheckScheduled = true;
            window.requestAnimationFrame(function() {
              nativeCheckScheduled = false;
              evaluateAndApply(currentCfg, true);
            });
          }

          function installObservers() {
            if (observerInstalled || !document.documentElement) return;
            observerInstalled = true;
            try {
              var mo = new MutationObserver(function(mutations) {
                var themeAttrChanged = false;
                var nodesAdded = false;
                for (var i = 0; i < mutations.length; i++) {
                  var m = mutations[i];
                  if (m.type === 'attributes' && (m.target === document.documentElement || m.target === document.body)) {
                    themeAttrChanged = true;
                  } else if (m.type === 'childList' && m.addedNodes && m.addedNodes.length) {
                    nodesAdded = true;
                  }
                }
                if (themeAttrChanged) scheduleNativeRecheck();
                if (nodesAdded && currentCfg && currentCfg.enabled) scheduleBackgroundScan();
              });
              mo.observe(document.documentElement, {
                attributes: true,
                attributeFilter: ['class', 'style', 'data-theme', 'data-color-mode'],
                childList: true,
                subtree: true
              });
            } catch (e) {}
          }

          // Expose live update hook strictly inside WKContentWorld.defaultClient.
          window.__vesperDarkModeApply = function(nextCfg) {
            evaluateAndApply(nextCfg, Boolean(document.body));
          };

          // Immediate pre-paint application to eliminate white flash on light pages.
          evaluateAndApply(currentCfg, Boolean(document.body));

          document.addEventListener('DOMContentLoaded', function() {
            evaluateAndApply(currentCfg, true);
            installObservers();
          }, { once: true });

          window.addEventListener('load', function() {
            evaluateAndApply(currentCfg, true);
            scheduleBackgroundScan();
          }, { once: true });
        })();
        """
    }

    /// Generates an in-place JS evaluation snippet for `WKContentWorld.defaultClient`
    /// that updates an already-loaded page immediately without reloading.
    public static func makeLiveUpdateJS(for state: BrowserDarkModeEffectiveState) -> String {
        let payloadJSON = encodePayloadJSON(for: state)
        return """
        (function() {
          if (typeof window.__vesperDarkModeApply === 'function') {
            window.__vesperDarkModeApply(\(payloadJSON));
            return true;
          }
          return false;
        })();
        """
    }
}
