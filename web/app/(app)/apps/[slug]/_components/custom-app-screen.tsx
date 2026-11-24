"use client";

import { useQueryClient } from "@tanstack/react-query";
import { useSearchParams } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { PersonaAvatar, personaLook, useDockPersona } from "@/app/(app)/chat/_components/persona";
import { DockChatSwitcher, type DockChatSection } from "@/components/domain/dock-chat-switcher";
import { DockContext, dockContextChip } from "@/components/domain/dock-context";
import { buildCustomAppActions, buildCustomAppNav, parseViewId } from "@/lib/native-shell/models/custom-app";
import { buildCustomAppCapabilities, buildCustomAppInspectorSections } from "@/lib/native-shell/models/custom-app-inspector";
import { EditorLayout, type DockTab, type NativeEditorHeader } from "@/components/shell/editor-layout";
import { isTyping } from "@/components/shell/shortcuts";
import { isNativeShell, post as postToShell } from "@/lib/native-shell/bridge";
import { Content, TopBar } from "@/components/shell/topbar";
import { CustomAppPlayerStage, type StageVideo } from "./custom-app-player";
import { Button, ButtonLink, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton, TextArea, TextInput } from "@/components/ui/primitives";
import { api, ApiError, unwrap, type Schemas } from "@/lib/api/client";
import { useConnectors } from "@/lib/api/connector-hooks";
import { useApiSecrets } from "@/lib/api/secret-hooks";
import {
  customAppKeys,
  getCustomAppHlsStream,
  invokeCustomApp,
  stopCustomAppHlsStream,
  useCustomApp,
  useUpdateCustomApp,
  type CustomAppCapabilityMode,
  type CustomAppDetail,
  type CustomAppInvokeRequest,
} from "@/lib/api/custom-app-hooks";
import { useAddDockChat, useDockChats, type DockScope } from "@/lib/api/dock-hooks";
import { chatKeys, useChat, useCreateChat } from "@/lib/api/hooks";
import { useSpaceChats } from "@/lib/api/space-hooks";
import {
  buildCustomAppSrcDoc,
  callNativeOSBridge,
  formatOSApprovalSummary,
  hasCustomAppOSBridge,
  hlsRelayStreamId,
  isOSBridgeMessage,
  osCapabilityForMessage,
  parseBridgeMessage,
  readThemeVarsFrom,
  resolveAppIcon,
  localMediaEmbed,
  parseLocalMediaUrl,
  resolveVideoEmbed,
  withCustomAppContext,
  type CustomAppNavSpec,
  type CustomAppOSCapability,
  type OSBridgeMessage,
} from "@/lib/custom-app-bridge";
import { cx } from "@/lib/cx";
import type { DockState } from "@/lib/editor-layout";
import { shortAgo } from "@/lib/format";
import { makePanelSpec } from "@/lib/native-shell/panel-events";
import { toast } from "@/lib/toast";

const ALLOWED_FILE_EXTS = [".tsx", ".ts", ".jsx", ".js", ".css", ".sql", ".json"];

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

function formatBytes(bytes: number): string {
  if (!bytes || bytes <= 0) return "0 B";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1).replace(/\.0$/, "")} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function readThemeVars(): Record<string, string> {
  if (typeof window === "undefined") return {};
  const styles = getComputedStyle(document.documentElement);
  return readThemeVarsFrom((name) => styles.getPropertyValue(name));
}

type PendingApproval =
  | {
      seq: number;
      reload: number;
      reqId: string;
      kind: "invoke";
      body: CustomAppInvokeRequest;
      capability: string;
      summary: string;
    }
  | {
      seq: number;
      reload: number;
      reqId: string;
      kind: "image";
      capability: "app.http:outbound";
      summary: string;
    }
  | {
      seq: number;
      reload: number;
      reqId: string;
      kind: "ws";
      capability: "app.ws:outbound";
      summary: string;
    }
  | {
      seq: number;
      reload: number;
      reqId: string;
      kind: "os";
      msg: OSBridgeMessage;
      capability: CustomAppOSCapability;
      summary: string;
    };

export function CustomAppScreen({ slug }: { slug: string }) {
  const searchParams = useSearchParams();
  const standalone = searchParams.get("standalone") === "1";
  const query = useCustomApp(slug);

  if (query.error instanceof ApiError && query.error.status === 404) {
    return (
      <>
        {!standalone && <TopBar crumbs={[{ label: "Custom Apps", href: "/apps" }, { label: slug, mono: true }]} />}
        <Content>
          <EmptyState
            icon="dashboard"
            title="Custom app not found"
            actions={
              standalone ? (
                <Button
                  variant="primary"
                  onClick={() => {
                    if (isNativeShell()) {
                      postToShell({ v: 1, type: "openInMain", path: "/apps" });
                    } else {
                      window.location.assign("/apps");
                    }
                  }}
                >
                  Open Vesper Custom Apps
                </Button>
              ) : (
                <ButtonLink variant="primary" href="/apps">
                  Back to Custom Apps
                </ButtonLink>
              )
            }
          >
            No custom app exists at <span className="font-mono">/apps/{slug}</span>. Create it from Custom Apps or ask a persona to build it.
          </EmptyState>
        </Content>
      </>
    );
  }

  if (query.isError) {
    return (
      <>
        {!standalone && <TopBar crumbs={[{ label: "Custom Apps", href: "/apps" }, { label: slug, mono: true }]} />}
        <Content>
          <Banner tone="blocked" title="Couldn’t load custom app">
            {errorText(query.error)}
          </Banner>
        </Content>
      </>
    );
  }

  if (!query.data) {
    return (
      <>
        {!standalone && <TopBar crumbs={[{ label: "Custom Apps", href: "/apps" }, { label: slug, mono: true }]} />}
        <Content>
          <Skeleton className="h-[60vh] w-full rounded-xl" />
        </Content>
      </>
    );
  }

  if (standalone) {
    return <StandaloneCustomAppScreen key={query.data.id} app={query.data} />;
  }

  return <CustomAppWorkbench key={query.data.id} app={query.data} />;
}

function useCustomAppRuntime({
  app,
  standalone,
  askDockRef,
}: {
  app: CustomAppDetail;
  standalone: boolean;
  askDockRef: React.RefObject<(prompt: string) => void | Promise<void>>;
}) {
  const qc = useQueryClient();
  const frameRef = useRef<HTMLIFrameElement>(null);
  const [initialThemeVars] = useState<Record<string, string>>(() => readThemeVars());

  const [reloadKey, setReloadKey] = useState(0);
  const [runtimeErrorState, setRuntimeErrorState] = useState<{ seq: number; reload: number; message: string } | null>(null);
  const [dynamicNavState, setDynamicNavState] = useState<{ seq: number; items: CustomAppNavSpec[] } | null>(null);
  const [activeNav, setActiveNav] = useState<string>();
  const [pendingApprovals, setPendingApprovals] = useState<PendingApproval[]>([]);
  const [decidingApproval, setDecidingApproval] = useState(false);
  const [activeVideo, setActiveVideo] = useState<StageVideo | null>(null);
  const [theater, setTheater] = useState(false);
  const [sidePanelEnabled, setSidePanelEnabled] = useState(false);
  const [sidePanelOpen, setSidePanelOpen] = useState(true);
  const capabilitiesRef = useRef(app.capabilities);
  useEffect(() => {
    capabilitiesRef.current = app.capabilities;
  }, [app.capabilities]);
  const pendingImageQueueRef = useRef<Map<string, Array<{ id: string; url: string }>>>(new Map());

  const postToFrame = useCallback((msg: unknown, transfer?: Transferable[]) => {
    frameRef.current?.contentWindow?.postMessage(msg, "*", transfer);
  }, []);

  const closeVideo = useCallback(() => {
    setActiveVideo(null);
    setSidePanelEnabled(false);
  }, []);
  const hlsRequestSeqRef = useRef(0);

  // Stop any active LAN HLS relay stream when switching videos, closing the player, or leaving the page.
  const activeHlsStreamId = activeVideo?.provider === "hls" ? activeVideo.streamId : undefined;
  useEffect(() => {
    if (!activeHlsStreamId) return;
    let stopped = false;
    const stop = () => {
      if (stopped) return;
      stopped = true;
      stopCustomAppHlsStream(app.slug, activeHlsStreamId);
    };
    window.addEventListener("pagehide", stop);
    return () => {
      window.removeEventListener("pagehide", stop);
      stop();
    };
  }, [app.slug, activeHlsStreamId]);

  // Tell the app what its player is doing, so it can save progress or move on to the next video.
  const playerUrl = activeVideo?.embedUrl ?? null;
  const sidePanelLayout = playerUrl !== null && theater && sidePanelEnabled;
  useEffect(() => {
    postToFrame({ type: "vesper:player", open: playerUrl !== null, theater, sidePanel: sidePanelLayout && sidePanelOpen });
  }, [playerUrl, theater, sidePanelLayout, sidePanelOpen, postToFrame]);

  // Theater wants the whole window: fold the native sidebar while it lasts (a no-op in a browser or standalone window).
  const wantsWholeWindow = !standalone && playerUrl !== null && theater;
  useEffect(() => {
    if (!wantsWholeWindow) return;
    postToShell({ v: 1, type: "sidebarHidden", hidden: true });
    return () => postToShell({ v: 1, type: "sidebarHidden", hidden: false });
  }, [wantsWholeWindow]);

  const wsConnsRef = useRef<Map<string, WebSocket>>(new Map());
  const pendingWSQueueRef = useRef<Map<string, Array<{ connId: string; url: string; protocols?: string[] }>>>(new Map());

  useEffect(() => {
    const conns = wsConnsRef.current;
    return () => {
      for (const ws of conns.values()) {
        try {
          ws.close(1001, "app reload");
        } catch {}
      }
      conns.clear();
    };
  }, [app.slug, app.current_seq, reloadKey]);

  const openProxyWS = useCallback(
    (connId: string, wsUrl: string, protocols: string[] | undefined, approved: boolean) => {
      const conns = wsConnsRef.current;
      if (conns.size >= 8 && !conns.has(connId)) {
        postToFrame({ type: "vesper:ws", connId, event: "error", message: "Too many open WebSocket connections (max 8)" });
        postToFrame({ type: "vesper:ws", connId, event: "close", code: 1008, reason: "limit exceeded", wasClean: false });
        return;
      }
      const existing = conns.get(connId);
      if (existing) {
        try {
          existing.close(1000, "replaced");
        } catch {}
        conns.delete(connId);
      }
      const params = new URLSearchParams({ url: wsUrl });
      if (approved) params.set("approved", "true");
      if (protocols && protocols.length) params.set("protocols", protocols.join(","));
      const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
      const proxyUrl = `${proto}//${window.location.host}/api/v1/custom-apps/${encodeURIComponent(app.slug)}/ws?${params.toString()}`;
      try {
        const ws = protocols && protocols.length ? new WebSocket(proxyUrl, protocols) : new WebSocket(proxyUrl);
        conns.set(connId, ws);
        ws.addEventListener("open", () => {
          postToFrame({ type: "vesper:ws", connId, event: "open", protocol: ws.protocol || "" });
        });
        ws.addEventListener("message", (ev) => {
          if (typeof ev.data === "string") {
            postToFrame({ type: "vesper:ws", connId, event: "message", data: ev.data });
          } else if (ev.data instanceof Blob) {
            void ev.data.text().then((text) => {
              postToFrame({ type: "vesper:ws", connId, event: "message", data: text });
            });
          }
        });
        ws.addEventListener("error", () => {
          postToFrame({ type: "vesper:ws", connId, event: "error", message: "WebSocket connection failed" });
        });
        ws.addEventListener("close", (ev) => {
          if (conns.get(connId) === ws) conns.delete(connId);
          postToFrame({
            type: "vesper:ws",
            connId,
            event: "close",
            code: ev.code || 1000,
            reason: ev.reason || "",
            wasClean: ev.wasClean,
          });
        });
      } catch (err) {
        postToFrame({ type: "vesper:ws", connId, event: "error", message: errorText(err) });
        postToFrame({ type: "vesper:ws", connId, event: "close", code: 1006, reason: errorText(err), wasClean: false });
      }
    },
    [app.slug, postToFrame],
  );

  const serveProxyImage = useCallback(
    async (reqId: string, imageUrl: string, approved: boolean) => {
      try {
        const params = new URLSearchParams({ url: imageUrl });
        if (approved) params.set("approved", "true");
        const res = await fetch(`/api/v1/custom-apps/${encodeURIComponent(app.slug)}/image?${params.toString()}`, {
          credentials: "same-origin",
        });
        if (!res.ok) {
          let msg = `Image request failed (HTTP ${res.status})`;
          try {
            const errJson = (await res.json()) as { message?: string };
            if (errJson?.message) msg = errJson.message;
          } catch {}
          postToFrame({ type: "vesper:response", id: reqId, ok: false, error: msg });
          return;
        }
        const mime = res.headers.get("content-type")?.split(";")[0]?.trim() || "image/png";
        const bytes = await res.arrayBuffer();
        postToFrame({ type: "vesper:response", id: reqId, ok: true, data: { bytes, mime } }, [bytes]);
      } catch (err) {
        postToFrame({ type: "vesper:response", id: reqId, ok: false, error: errorText(err) });
      }
    },
    [app.slug, postToFrame],
  );

  // Theme sync whenever root attributes change (dark/light/palette switch).
  useEffect(() => {
    const observer = new MutationObserver(() => {
      postToFrame({ type: "vesper:theme", vars: readThemeVars() });
    });
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class", "style", "data-theme"],
    });
    return () => observer.disconnect();
  }, [postToFrame]);

  // Forward shell SSE events to the sandboxed app.
  useEffect(() => {
    const onSSE = (e: Event) => {
      postToFrame({ type: "vesper:sse", event: (e as CustomEvent).detail });
    };
    window.addEventListener("vesper:sse", onSSE);
    return () => window.removeEventListener("vesper:sse", onSSE);
  }, [postToFrame]);

  const runtimeError =
    runtimeErrorState?.seq === app.current_seq && runtimeErrorState?.reload === reloadKey
      ? runtimeErrorState.message
      : null;

  const dynamicNav = dynamicNavState?.seq === app.current_seq ? dynamicNavState.items : null;
  const navItems = dynamicNav ?? app.manifest.nav ?? [];
  const currentNav = navItems.some((n) => n.id === activeNav) ? activeNav : navItems[0]?.id;

  const visibleApprovals = pendingApprovals.filter(
    (a) => a.seq === app.current_seq && a.reload === reloadKey,
  );
  const headApproval = visibleApprovals[0];

  const executeOSBridge = useCallback(
    async (msg: OSBridgeMessage, approved: boolean) => {
      const capability = osCapabilityForMessage(msg);
      if (!hasCustomAppOSBridge()) {
        postToFrame({
          type: "vesper:response",
          id: msg.id,
          ok: false,
          error: `macOS capability ${capability} requires the Vesper Mac app`,
        });
        return;
      }
      try {
        const res = await callNativeOSBridge({ slug: app.slug, msg, approved });
        if (res.approvalRequired) {
          void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
          setPendingApprovals((prev) => [
            ...prev,
            {
              seq: app.current_seq,
              reload: reloadKey,
              reqId: msg.id,
              kind: "os",
              msg,
              capability: res.capability ?? capability,
              summary: res.summary ?? formatOSApprovalSummary(msg),
            },
          ]);
          return;
        }
        if (!res.ok) {
          postToFrame({
            type: "vesper:response",
            id: msg.id,
            ok: false,
            error: res.error || `Capability ${capability} request failed`,
          });
          return;
        }
        postToFrame({ type: "vesper:response", id: msg.id, ok: true, data: res.data ?? null });
      } catch (err) {
        postToFrame({ type: "vesper:response", id: msg.id, ok: false, error: errorText(err) });
      }
    },
    [app.slug, app.current_seq, reloadKey, postToFrame, qc],
  );

  // Listen to bridge postMessages from the sandboxed iframe.
  useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      if (!frameRef.current || e.source !== frameRef.current.contentWindow) return;
      const msg = parseBridgeMessage(e.data);
      if (!msg) return;

      if (msg.type === "set-nav") {
        setDynamicNavState({ seq: app.current_seq, items: msg.payload.items });
        if (msg.payload.activeId !== undefined) setActiveNav(msg.payload.activeId);
        return;
      }
      if (msg.type === "ask-dock") {
        void askDockRef.current(msg.payload.prompt);
        return;
      }
      if (msg.type === "open-url") {
        window.open(msg.payload.url, "_blank", "noopener,noreferrer");
        return;
      }
      if (msg.type === "play-video") {
        const streamId = hlsRelayStreamId(msg.payload.url);
        if (streamId) {
          const reqSeq = ++hlsRequestSeqRef.current;
          const title = msg.payload.title || "Live stream";
          const externalUrl = msg.payload.externalUrl ?? "";
          const requestedTheater = msg.payload.theater;
          const wantsSide = msg.payload.sidePanel === true;
          void getCustomAppHlsStream(app.slug, streamId)
            .then((stream) => {
              if (hlsRequestSeqRef.current !== reqSeq) {
                stopCustomAppHlsStream(app.slug, streamId);
                return;
              }
              setActiveVideo({
                provider: "hls",
                embedUrl: stream.lan_url || stream.loopback_url,
                externalUrl,
                titleFallback: "Live stream",
                streamId: stream.id,
                title,
              });
              if (requestedTheater !== undefined) setTheater(requestedTheater);
              setSidePanelEnabled(wantsSide);
              if (wantsSide) setSidePanelOpen(true);
            })
            .catch(() => {
              // Stream expired or was stopped before playback began.
            });
          return;
        }
        hlsRequestSeqRef.current++;
        const embed =
          localMediaEmbed(msg.payload.url, app.slug) ??
          resolveVideoEmbed(msg.payload.url, typeof window !== "undefined" ? window.location.hostname : undefined);
        if (embed) {
          setActiveVideo({
            ...embed,
            ...(msg.payload.externalUrl ? { externalUrl: msg.payload.externalUrl } : {}),
            title: msg.payload.title || embed.titleFallback,
          });
          if (msg.payload.theater !== undefined) setTheater(msg.payload.theater);
          const wantsSide = msg.payload.sidePanel === true;
          setSidePanelEnabled(wantsSide);
          if (wantsSide) setSidePanelOpen(true);
        } else if (!parseLocalMediaUrl(msg.payload.url)) {
          window.open(msg.payload.url, "_blank", "noopener,noreferrer");
        }
        return;
      }
      if (msg.type === "app-error") {
        setRuntimeErrorState({ seq: app.current_seq, reload: reloadKey, message: msg.payload.message });
        return;
      }
      if (msg.type === "ws-send") {
        const ws = wsConnsRef.current.get(msg.payload.connId);
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(msg.payload.data);
        }
        return;
      }
      if (msg.type === "ws-close") {
        const ws = wsConnsRef.current.get(msg.payload.connId);
        if (ws) {
          wsConnsRef.current.delete(msg.payload.connId);
          try {
            ws.close(msg.payload.code ?? 1000, msg.payload.reason ?? "");
          } catch {}
        }
        return;
      }
      if (msg.type === "ws-open") {
        const mode = capabilitiesRef.current["app.ws:outbound"] ?? "denied";
        if (mode === "allowed") {
          openProxyWS(msg.payload.connId, msg.payload.url, msg.payload.protocols, false);
          return;
        }
        if (mode === "denied") {
          const errMsg = `capability app.ws:outbound is denied for custom app "${app.slug}"`;
          postToFrame({ type: "vesper:ws", connId: msg.payload.connId, event: "error", message: errMsg });
          postToFrame({ type: "vesper:ws", connId: msg.payload.connId, event: "close", code: 1008, reason: errMsg, wasClean: false });
          return;
        }
        const queueKey = `${app.current_seq}:${reloadKey}`;
        const existing = pendingWSQueueRef.current.get(queueKey) ?? [];
        existing.push({ connId: msg.payload.connId, url: msg.payload.url, protocols: msg.payload.protocols });
        pendingWSQueueRef.current.set(queueKey, existing);
        setPendingApprovals((prev) => {
          if (prev.some((a) => a.kind === "ws" && a.seq === app.current_seq && a.reload === reloadKey)) {
            return prev;
          }
          return [
            ...prev,
            {
              seq: app.current_seq,
              reload: reloadKey,
              reqId: `ws:${queueKey}`,
              kind: "ws",
              capability: "app.ws:outbound",
              summary: "Open outbound WebSocket connection via proxy",
            },
          ];
        });
        return;
      }
      if (msg.type === "image") {
        const mode = capabilitiesRef.current["app.http:outbound"] ?? "denied";
        if (mode === "allowed") {
          void serveProxyImage(msg.id, msg.payload.url, false);
          return;
        }
        if (mode === "denied") {
          postToFrame({
            type: "vesper:response",
            id: msg.id,
            ok: false,
            error: `capability app.http:outbound is denied for custom app "${app.slug}"`,
          });
          return;
        }
        const queueKey = `${app.current_seq}:${reloadKey}`;
        const existing = pendingImageQueueRef.current.get(queueKey) ?? [];
        existing.push({ id: msg.id, url: msg.payload.url });
        pendingImageQueueRef.current.set(queueKey, existing);
        setPendingApprovals((prev) => {
          if (prev.some((a) => a.kind === "image" && a.seq === app.current_seq && a.reload === reloadKey)) {
            return prev;
          }
          return [
            ...prev,
            {
              seq: app.current_seq,
              reload: reloadKey,
              reqId: `img:${queueKey}`,
              kind: "image",
              capability: "app.http:outbound",
              summary: "Load remote images via HTTPS proxy",
            },
          ];
        });
        return;
      }

      if (isOSBridgeMessage(msg)) {
        const capability = osCapabilityForMessage(msg);
        const mode = capabilitiesRef.current[capability] ?? "denied";
        if (mode === "denied") {
          postToFrame({
            type: "vesper:response",
            id: msg.id,
            ok: false,
            error: `capability ${capability} is denied for custom app "${app.slug}"`,
          });
          return;
        }
        if (!hasCustomAppOSBridge()) {
          postToFrame({
            type: "vesper:response",
            id: msg.id,
            ok: false,
            error: `macOS capability ${capability} requires the Vesper Mac app`,
          });
          return;
        }
        if (mode === "requires_approval") {
          setPendingApprovals((prev) => [
            ...prev,
            {
              seq: app.current_seq,
              reload: reloadKey,
              reqId: msg.id,
              kind: "os",
              msg,
              capability,
              summary: formatOSApprovalSummary(msg),
            },
          ]);
          return;
        }
        void executeOSBridge(msg, false);
        return;
      }

      const reqBody: CustomAppInvokeRequest =
        msg.type === "sql"
          ? { kind: "sql", query: msg.payload.query, params: msg.payload.params }
          : msg.type === "api"
            ? { kind: "api", method: msg.payload.method, path: msg.payload.path, body: msg.payload.body }
            : { kind: "mcp", connector: msg.payload.connector, tool: msg.payload.tool, arguments: msg.payload.arguments };

      void invokeCustomApp(app.slug, reqBody)
        .then((res) => {
          if (res.status === "approval_required") {
            setPendingApprovals((prev) => [
              ...prev,
              {
                seq: app.current_seq,
                reload: reloadKey,
                reqId: msg.id,
                kind: "invoke",
                body: reqBody,
                capability: res.capability,
                summary: res.summary ?? `Allow ${res.capability}`,
              },
            ]);
            return;
          }
          if (msg.type === "sql" && /\b(create|alter|drop)\b/i.test(msg.payload.query)) {
            void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
          }
          postToFrame({ type: "vesper:response", id: msg.id, ok: true, data: res.result });
        })
        .catch((err) => {
          postToFrame({ type: "vesper:response", id: msg.id, ok: false, error: errorText(err) });
        });
    };

    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [app.slug, app.current_seq, reloadKey, postToFrame, serveProxyImage, openProxyWS, executeOSBridge, askDockRef, qc]);

  const decideApproval = useCallback(
    async (decision: "once" | "always" | "decline") => {
      if (!headApproval || decidingApproval) return;
      if (headApproval.kind === "os") {
        if (decision === "decline") {
          setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
          postToFrame({ type: "vesper:response", id: headApproval.reqId, ok: false, error: "Capability request declined" });
          return;
        }
        setDecidingApproval(true);
        try {
          if (decision === "always") {
            const updated = await unwrap(
              api.PATCH("/custom-apps/{slug}", {
                params: { path: { slug: app.slug } },
                body: { capabilities: { ...capabilitiesRef.current, [headApproval.capability]: "allowed" } },
              }),
            );
            capabilitiesRef.current = updated.capabilities;
            void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
            void qc.invalidateQueries({ queryKey: customAppKeys.list });
          }
          await executeOSBridge(headApproval.msg, decision === "once");
        } catch (err) {
          postToFrame({ type: "vesper:response", id: headApproval.reqId, ok: false, error: errorText(err) });
        } finally {
          setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
          setDecidingApproval(false);
        }
        return;
      }
      if (headApproval.kind === "ws") {
        const queueKey = `${headApproval.seq}:${headApproval.reload}`;
        if (decision === "decline") {
          const queued = pendingWSQueueRef.current.get(queueKey) ?? [];
          pendingWSQueueRef.current.delete(queueKey);
          setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
          for (const item of queued) {
            postToFrame({ type: "vesper:ws", connId: item.connId, event: "error", message: "Capability request declined" });
            postToFrame({ type: "vesper:ws", connId: item.connId, event: "close", code: 1008, reason: "Capability request declined", wasClean: false });
          }
          return;
        }
        setDecidingApproval(true);
        try {
          if (decision === "always") {
            const updated = await unwrap(
              api.PATCH("/custom-apps/{slug}", {
                params: { path: { slug: app.slug } },
                body: { capabilities: { ...capabilitiesRef.current, "app.ws:outbound": "allowed" } },
              }),
            );
            capabilitiesRef.current = updated.capabilities;
            void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
            void qc.invalidateQueries({ queryKey: customAppKeys.list });
          }
          const queued = pendingWSQueueRef.current.get(queueKey) ?? [];
          pendingWSQueueRef.current.delete(queueKey);
          for (const item of queued) {
            openProxyWS(item.connId, item.url, item.protocols, decision === "once");
          }
        } catch (err) {
          const queued = pendingWSQueueRef.current.get(queueKey) ?? [];
          pendingWSQueueRef.current.delete(queueKey);
          const message = errorText(err);
          for (const item of queued) {
            postToFrame({ type: "vesper:ws", connId: item.connId, event: "error", message });
            postToFrame({ type: "vesper:ws", connId: item.connId, event: "close", code: 1006, reason: message, wasClean: false });
          }
        } finally {
          setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
          setDecidingApproval(false);
        }
        return;
      }
      if (headApproval.kind === "image") {
        const queueKey = `${headApproval.seq}:${headApproval.reload}`;
        if (decision === "decline") {
          const queued = pendingImageQueueRef.current.get(queueKey) ?? [];
          pendingImageQueueRef.current.delete(queueKey);
          setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
          for (const item of queued) {
            postToFrame({ type: "vesper:response", id: item.id, ok: false, error: "Capability request declined" });
          }
          return;
        }
        setDecidingApproval(true);
        try {
          if (decision === "always") {
            const updated = await unwrap(
              api.PATCH("/custom-apps/{slug}", {
                params: { path: { slug: app.slug } },
                body: { capabilities: { ...capabilitiesRef.current, "app.http:outbound": "allowed" } },
              }),
            );
            capabilitiesRef.current = updated.capabilities;
            void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
            void qc.invalidateQueries({ queryKey: customAppKeys.list });
          }
          const queued = pendingImageQueueRef.current.get(queueKey) ?? [];
          pendingImageQueueRef.current.delete(queueKey);
          await Promise.all(queued.map((item) => serveProxyImage(item.id, item.url, decision === "once")));
        } catch (err) {
          const queued = pendingImageQueueRef.current.get(queueKey) ?? [];
          pendingImageQueueRef.current.delete(queueKey);
          const message = errorText(err);
          for (const item of queued) {
            postToFrame({ type: "vesper:response", id: item.id, ok: false, error: message });
          }
        } finally {
          setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
          setDecidingApproval(false);
        }
        return;
      }

      if (decision === "decline") {
        setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
        postToFrame({ type: "vesper:response", id: headApproval.reqId, ok: false, error: "Capability request declined" });
        return;
      }
      setDecidingApproval(true);
      try {
        const res = await invokeCustomApp(app.slug, {
          ...headApproval.body,
          approved: true,
          ...(decision === "always" ? { always_allow: true } : {}),
        });
        if (decision === "always") {
          void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
          void qc.invalidateQueries({ queryKey: customAppKeys.list });
        }
        if (headApproval.body.kind === "sql" && typeof headApproval.body.query === "string" && /\b(create|alter|drop)\b/i.test(headApproval.body.query)) {
          void qc.invalidateQueries({ queryKey: customAppKeys.detail(app.slug) });
        }
        postToFrame({ type: "vesper:response", id: headApproval.reqId, ok: true, data: res.result });
      } catch (err) {
        postToFrame({ type: "vesper:response", id: headApproval.reqId, ok: false, error: errorText(err) });
      } finally {
        setPendingApprovals((prev) => prev.filter((x) => x.reqId !== headApproval.reqId));
        setDecidingApproval(false);
      }
    },
    [headApproval, decidingApproval, app.slug, postToFrame, serveProxyImage, openProxyWS, executeOSBridge, qc],
  );

  const decideRef = useRef(decideApproval);
  useEffect(() => {
    decideRef.current = decideApproval;
  }, [decideApproval]);

  // ⌥A approves once, ⌥D declines when a capability prompt is active.
  useEffect(() => {
    if (!headApproval) return;
    const onKeyDown = (e: KeyboardEvent) => {
      if (!e.altKey || e.metaKey || e.ctrlKey || isTyping(e.target) || document.querySelector('[role="dialog"]')) return;
      const key = e.key.toLowerCase();
      if (e.code === "KeyA" || key === "a") {
        e.preventDefault();
        void decideRef.current("once");
      } else if (e.code === "KeyD" || key === "d") {
        e.preventDefault();
        void decideRef.current("decline");
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [headApproval]);

  const { slug: appSlug, current } = app;
  const { seq: currentSeq, bundle_js: bundleJs, bundle_css: bundleCss } = current;
  const srcDoc = useMemo(
    () =>
      buildCustomAppSrcDoc({
        slug: appSlug,
        seq: currentSeq,
        bundleJs,
        bundleCss,
        themeVars: initialThemeVars,
      }),
    [appSlug, currentSeq, bundleJs, bundleCss, initialThemeVars],
  );

  const reload = useCallback(() => {
    setRuntimeErrorState(null);
    setPendingApprovals([]);
    setReloadKey((k) => k + 1);
  }, []);
  const selectNav = useCallback(
    (id: string) => {
      setActiveNav(id);
      postToFrame({ type: "vesper:nav-select", id });
    },
    [postToFrame],
  );
  useEffect(() => {
    const queue = pendingImageQueueRef.current;
    return () => {
      queue.clear();
    };
  }, [app.current_seq, reloadKey]);

  const main = (
    <div className="flex min-h-0 flex-1 flex-col">
      {standalone && navItems.length > 1 && (
        <nav
          aria-label={`${app.name} views`}
          className="flex flex-none items-center gap-1 overflow-x-auto border-b border-border-subtle bg-surface px-2.5 py-1.5"
        >
          {navItems.map((item) => {
            const active = item.id === currentNav;
            return (
              <button
                key={item.id}
                type="button"
                onClick={() => selectNav(item.id)}
                className={cx(
                  "inline-flex h-7 flex-none items-center gap-1.5 rounded-md px-2.5 text-12 transition-colors",
                  active ? "bg-selected font-medium text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
                )}
              >
                {item.icon ? <Icon name={resolveAppIcon(item.icon)} size={13} /> : null}
                <span>{item.label}</span>
              </button>
            );
          })}
        </nav>
      )}
      {(headApproval || runtimeError) && (
        <div className="flex flex-col gap-2 border-b border-border-subtle bg-surface p-3">
          {headApproval && (
            <Banner
              tone="human"
              title={`Permission needed · ${headApproval.capability}`}
              actions={
                <>
                  <Button
                    variant="approve"
                    hint="⌥A"
                    disabled={decidingApproval}
                    onClick={() => void decideApproval("once")}
                  >
                    Approve once
                  </Button>
                  <Button
                    variant="approve-outline"
                    disabled={decidingApproval}
                    onClick={() => void decideApproval("always")}
                  >
                    Always allow
                  </Button>
                  <Button
                    variant="outline"
                    hint="⌥D"
                    disabled={decidingApproval}
                    onClick={() => void decideApproval("decline")}
                  >
                    Decline
                  </Button>
                </>
              }
            >
              {headApproval.summary}
            </Banner>
          )}
          {runtimeError && (
            <Banner
              tone="blocked"
              title="Runtime error in sandbox"
              actions={
                <>
                  <Button
                    variant="secondary"
                    icon="msg"
                    onClick={() =>
                      void askDockRef.current(
                        `Please fix this runtime error in custom app "${app.name}" (/apps/${app.slug}):\n\n${runtimeError}`,
                      )
                    }
                  >
                    {standalone ? "Open in Vesper to fix" : "Ask persona to fix"}
                  </Button>
                  <Button variant="ghost" onClick={() => setRuntimeErrorState(null)}>
                    Dismiss
                  </Button>
                </>
              }
            >
              {runtimeError}
            </Banner>
          )}
        </div>
      )}
      <div className={cx("flex min-h-0 flex-1", sidePanelLayout ? "flex-row" : "flex-col")}>
        {activeVideo && (
          <CustomAppPlayerStage
            video={activeVideo}
            theater={theater}
            sidePanelAvailable={sidePanelEnabled}
            sidePanelLayout={sidePanelLayout}
            sidePanelOpen={sidePanelOpen}
            onSidePanelChange={setSidePanelOpen}
            onTheaterChange={setTheater}
            onClose={closeVideo}
          />
        )}
        <iframe
          ref={frameRef}
          key={`${app.current.seq}:${reloadKey}`}
          sandbox="allow-scripts"
          // An app may play video it builds itself (media-src blob:) and take it fullscreen.
          allow="fullscreen"
          referrerPolicy="no-referrer"
          srcDoc={srcDoc}
          title={app.name}
          data-testid="custom-app-frame"
          onLoad={() => postToFrame({ type: "vesper:theme", vars: readThemeVars() })}
          className={cx(
            "border-0 bg-bg",
            sidePanelLayout
              ? sidePanelOpen
                ? "h-full w-[340px] flex-none border-l border-border-subtle"
                : "hidden"
              : standalone
                ? "h-full w-full flex-1"
                : "h-full min-h-[420px] w-full flex-1",
          )}
        />
      </div>
    </div>
  );

  return { reload, navItems, currentNav, selectNav, runtimeError, main };
}

function StandaloneCustomAppScreen({ app }: { app: CustomAppDetail }) {
  const openInWorkbench = useCallback(() => {
    const target = `/apps/${app.slug}`;
    if (isNativeShell()) {
      postToShell({ v: 1, type: "openInMain", path: target });
    } else {
      window.location.assign(target);
    }
  }, [app.slug]);
  const askDockRef = useRef<(prompt: string) => void>(openInWorkbench);
  useEffect(() => {
    askDockRef.current = openInWorkbench;
  }, [openInWorkbench]);

  useEffect(() => {
    document.title = app.name;
    postToShell({ v: 1, type: "title", title: app.name });
  }, [app.name]);

  const runtime = useCustomAppRuntime({ app, standalone: true, askDockRef });

  return (
    <div data-standalone-app={app.slug} className="flex h-dvh min-h-0 min-w-0 flex-1 flex-col bg-bg">
      {runtime.main}
    </div>
  );
}

function CustomAppWorkbench({ app }: { app: CustomAppDetail }) {
  const qc = useQueryClient();
  const [show, setShow] = useState({ tab: "chat", n: 0 });
  const openDockTab = useCallback((tab: string) => {
    setShow((s) => ({ tab, n: s.n + 1 }));
  }, []);
  const [dock, setDock] = useState<DockState>();
  const askDockRef = useRef<(prompt: string) => void | Promise<void>>(() => {});

  const runtime = useCustomAppRuntime({ app, standalone: false, askDockRef });
  const { reload, navItems, currentNav, selectNav, runtimeError, main } = runtime;

  // ---- Dock chat wiring (`app:custom:<slug>` + app's space)
  const dockChat = useCustomAppDockChat({
    app,
    currentNav,
    runtimeError,
  });
  const {
    chatId,
    chat,
    running,
    startingPersona,
    createChat,
    selectChat,
  } = dockChat;

  const chatShowing = !dock || (dock.open && !dock.hidden && dock.tab === "chat");
  const lastReply = chat?.last_message_at;
  const [seenReply, setSeenReply] = useState<{ chat?: string; at?: string }>({});
  if (lastReply && (seenReply.chat !== chatId || ((chatShowing || seenReply.at === undefined) && seenReply.at !== lastReply))) {
    setSeenReply({ chat: chatId, at: lastReply });
  }
  const unread = !chatShowing && !!lastReply && seenReply.chat === chatId && !!seenReply.at && seenReply.at !== lastReply && !running;

  const handleAskDock = useCallback(
    async (prompt: string) => {
      openDockTab("chat");
      const formatted = withCustomAppContext(prompt, {
        slug: app.slug,
        name: app.name,
        seq: app.current_seq,
        activeNav: currentNav,
        error: runtimeError ?? undefined,
      });
      try {
        if (chatId) {
          if (running) {
            await unwrap(api.POST("/chats/{id}/followups", { params: { path: { id: chatId } }, body: { body: formatted } }));
          } else {
            await unwrap(api.POST("/chats/{id}/messages", { params: { path: { id: chatId } }, body: { body: formatted } }));
          }
          await qc.invalidateQueries({ queryKey: chatKeys.all });
          return;
        }
        const created = await createChat.mutateAsync({
          title: app.name,
          hidden: true,
          ...(app.space_id ? { space_id: app.space_id } : {}),
          ...(startingPersona.id ? { persona_id: startingPersona.id } : {}),
          message: { body: formatted },
        });
        selectChat(created.id);
        await qc.invalidateQueries({ queryKey: chatKeys.all });
      } catch (err) {
        toast({ id: `ask-${app.slug}`, tone: "error", title: "Couldn’t send to chat", description: errorText(err) });
      }
    },
    [app.slug, app.name, app.current_seq, app.space_id, currentNav, runtimeError, chatId, running, qc, createChat, startingPersona.id, selectChat, openDockTab],
  );
  useEffect(() => {
    askDockRef.current = handleAskDock;
  }, [handleAskDock]);

  const header: NativeEditorHeader = {
    title: app.name,
    subtitle: `v${app.current_seq}`,
    actions: buildCustomAppActions({
      reload,
      permissions: () => openDockTab("permissions"),
      openStandalone: () => {
        if (isNativeShell()) {
          postToShell({ v: 1, type: "openCustomAppWindow", slug: app.slug });
        } else {
          window.open(`/apps/${app.slug}?standalone=1`, `vesper-app-${app.slug}`, "noopener,noreferrer,width=960,height=700");
        }
      },
    }),
  };
  const nativeLeft =
    navItems.length > 0
      ? {
          model: buildCustomAppNav({ title: app.name, items: navItems.map((n) => ({ id: n.id, label: n.label, icon: n.icon ? resolveAppIcon(n.icon) : undefined })), currentId: currentNav }),
          onCommand: (cmd: { type: string; itemId?: string }) => {
            const id = cmd.type === "nav.activate" && cmd.itemId ? parseViewId(cmd.itemId) : null;
            if (!id) return;
            selectNav(id);
          },
        }
      : undefined;

  const personaLookForTab = chat ? personaLook(chat.speaker ?? chat.persona) : startingPersona.look;
  const perms = useCustomAppPermissions(app);
  const permSections = buildCustomAppInspectorSections({
    hasMcpServer: app.has_mcp_server,
    mcpEntry: app.manifest.mcp_entry || "server.ts",
    mcpToolCount: (app.mcp_tools ?? []).length,
    mcpTools: (app.mcp_tools ?? []).map((t) => ({ name: t.name, description: t.description })),
    dbSizeLabel: formatBytes(app.db_size_bytes),
    schemaCount: app.schema.length,
    schemaObjects: app.schema.map((o) => ({ type: o.type, name: o.name })),
    capabilities: perms.capabilities,
    mounts: app.mounts,
    requestedMounts: app.manifest.requested_mounts,
    toolScope: app.manifest.tool_scope === "app_only" ? "app_only" : "chats",
    versions: perms.versions.map((v) => ({
      seq: v.seq,
      authorLabel: v.author_type === "persona" ? "Persona" : "You",
      age: shortAgo(v.created_at),
      note: v.note,
      current: v.seq === app.current_seq,
    })),
    updating: perms.updating,
  });

  const dockTabs: DockTab[] = [
    {
      id: "chat",
      label: "Chat",
      icon: "msg",
      avatar: <PersonaAvatar persona={personaLookForTab} size={16} />,
      busy: running,
      unread,
      native: {
        kind: "panel",
        panel: makePanelSpec("customApp.chat", `customApp.chat:${app.slug}`, {
          tabId: "chat",
          slug: app.slug,
          activeNav: currentNav,
          runtimeError,
          chatId,
        }),
        onEvent: (event, payloadJson) => {
          if (event !== "selectChat" || !payloadJson) return;
          try {
            const payload = JSON.parse(payloadJson) as { chatId?: string };
            if (typeof payload.chatId === "string" && payload.chatId) {
              selectChat(payload.chatId);
            }
          } catch {
            // Ignore malformed panel event payloads.
          }
        },
      },
    },
    {
      id: "code",
      label: "Code",
      icon: "code",
      wide: true,
      native: {
        kind: "panel",
        width: "wide",
        panel: makePanelSpec("customApp.code", `customApp.code:${app.slug}`, {
          tabId: "code",
          slug: app.slug,
        }),
      },
    },
    {
      id: "permissions",
      label: "Permissions",
      icon: "shield",
      native: {
        kind: "native",
        sections: permSections,
        onChange: (fieldId, value) => {
          if (fieldId === "tool_scope") {
            const nextScope = value === "app_only" ? "app_only" : "chats";
            perms.setToolScope(nextScope);
          } else if (fieldId.startsWith("cap:")) {
            const capKey = fieldId.slice("cap:".length);
            perms.setCapabilityMode(capKey, value as CustomAppCapabilityMode);
          } else if (fieldId === "nix_add") {
            perms.addNixPackages(value);
          } else if (fieldId === "mount_add") {
            perms.addMount(value);
          } else if (fieldId.startsWith("mount:")) {
            const mountName = fieldId.slice("mount:".length);
            perms.setMount(mountName, value);
          }
        },
        onAction: (actionId, itemId) => {
          if (actionId === "restore_version" && itemId) {
            const seq = Number(itemId);
            if (Number.isFinite(seq) && seq > 0 && seq !== app.current_seq) {
              perms.restoreVersion(seq);
            }
          }
        },
      },
    },
  ];

  return (
    <EditorLayout
      app={`custom-app:${app.slug}`}
      back={{ href: "/apps", label: "Custom Apps" }}
      header={header}
      nativeLeft={nativeLeft}
      main={main}
      dock={dockTabs}
      show={show}
      onDockChange={setDock}
    />
  );
}

function CodeInspectorTab({ app }: { app: CustomAppDetail }) {
  const update = useUpdateCustomApp(app.slug);
  const [draftFiles, setDraftFiles] = useState<Record<string, string>>(() => ({ ...app.current.files }));
  const fileNames = useMemo(() => Object.keys(draftFiles).sort(), [draftFiles]);
  const [selectedFile, setSelectedFile] = useState<string>(() =>
    app.current.files[app.manifest.entry] !== undefined ? app.manifest.entry : Object.keys(app.current.files).sort()[0] ?? app.manifest.entry,
  );
  const [note, setNote] = useState("");
  const [addingFile, setAddingFile] = useState(false);
  const [newPath, setNewPath] = useState("");
  const [newPathError, setNewPathError] = useState<string | null>(null);

  const baseFiles = app.current.files;
  const dirty = useMemo(() => {
    const dk = Object.keys(draftFiles);
    const bk = Object.keys(baseFiles);
    if (dk.length !== bk.length) return true;
    return dk.some((k) => draftFiles[k] !== baseFiles[k]);
  }, [draftFiles, baseFiles]);

  const handleAddFile = () => {
    const cleaned = newPath.trim().replace(/^\/+/, "");
    if (!cleaned || cleaned.includes("..")) {
      setNewPathError("Enter a relative file path (for example components/Table.tsx).");
      return;
    }
    if (!ALLOWED_FILE_EXTS.some((ext) => cleaned.toLowerCase().endsWith(ext))) {
      setNewPathError(`Allowed extensions: ${ALLOWED_FILE_EXTS.join(", ")}`);
      return;
    }
    if (draftFiles[cleaned] !== undefined) {
      setNewPathError("File already exists.");
      return;
    }
    setDraftFiles((prev) => ({ ...prev, [cleaned]: "" }));
    setSelectedFile(cleaned);
    setNewPath("");
    setNewPathError(null);
    setAddingFile(false);
  };

  const handleDeleteFile = (path: string) => {
    if (path === app.manifest.entry) return;
    setDraftFiles((prev) => {
      const next = { ...prev };
      delete next[path];
      return next;
    });
    if (selectedFile === path) {
      setSelectedFile(app.manifest.entry);
    }
  };

  const handleSave = () => {
    update.mutate(
      {
        files: draftFiles,
        replace_files: true,
        note: note.trim() || "Edited in Code inspector",
      },
      {
        onSuccess: (updated) => {
          toast({ id: `save-${app.slug}`, tone: "success", title: `Saved ${app.name} v${updated.current_seq}` });
        },
      },
    );
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex flex-wrap items-center gap-1 border-b border-border-subtle px-2.5 py-2">
        {fileNames.map((name) => {
          const active = name === selectedFile;
          return (
            <button
              key={name}
              type="button"
              onClick={() => setSelectedFile(name)}
              className={cx(
                "inline-flex h-6 items-center gap-1 rounded px-2 font-mono text-11 transition-colors",
                active ? "bg-selected font-semibold text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
              )}
            >
              {name}
            </button>
          );
        })}
        <button
          type="button"
          onClick={() => {
            setAddingFile((v) => !v);
            setNewPathError(null);
          }}
          className="inline-flex h-6 items-center gap-1 rounded border border-dashed border-border-strong px-2 text-11 text-fg-secondary hover:bg-hover hover:text-fg"
        >
          <Icon name="plus" size={11} />
          File
        </button>
        {selectedFile !== app.manifest.entry && fileNames.includes(selectedFile) && (
          <IconButton
            icon="trash"
            size={24}
            label={`Delete ${selectedFile}`}
            onClick={() => handleDeleteFile(selectedFile)}
            className="ml-auto text-fg-tertiary hover:text-pill-blocked-fg"
          />
        )}
      </div>

      {addingFile && (
        <div className="flex flex-col gap-1.5 border-b border-border-subtle bg-surface-sunken px-3 py-2">
          <div className="flex items-center gap-2">
            <TextInput
              mono
              value={newPath}
              placeholder="components/Summary.tsx"
              onChange={(e) => {
                setNewPath(e.target.value);
                setNewPathError(null);
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  handleAddFile();
                }
              }}
              className="flex-1"
            />
            <Button variant="secondary" onClick={handleAddFile}>
              Add
            </Button>
          </div>
          {newPathError && <p className="text-11 text-pill-blocked-fg">{newPathError}</p>}
        </div>
      )}

      {update.isError && (
        <div className="border-b border-border-subtle p-2.5">
          <Banner tone="blocked" title="Compile error">
            {errorText(update.error)}
          </Banner>
        </div>
      )}

      <div className="flex min-h-0 flex-1 flex-col p-2.5">
        <TextArea
          mono
          aria-label={`Source code for ${selectedFile}`}
          value={draftFiles[selectedFile] ?? ""}
          onChange={(e) => setDraftFiles((prev) => ({ ...prev, [selectedFile]: e.target.value }))}
          spellCheck={false}
          className="min-h-[320px] flex-1 resize-none text-12"
        />
      </div>

      <div className="flex items-center gap-2 border-t border-border-subtle px-3 py-2.5">
        <TextInput
          value={note}
          placeholder="Version note (optional)"
          onChange={(e) => setNote(e.target.value)}
          className="flex-1"
        />
        <Button variant="primary" disabled={!dirty || update.isPending} onClick={handleSave}>
          {update.isPending ? "Compiling…" : "Save & compile"}
        </Button>
      </div>
    </div>
  );
}

function useCustomAppPermissions(app: CustomAppDetail) {
  const update = useUpdateCustomApp(app.slug);
  const connectors = useConnectors();
  const apiSecrets = useApiSecrets();

  const capabilities = useMemo(
    () =>
      buildCustomAppCapabilities({
        connectors: (connectors.data?.connectors ?? []).map((c) => ({
          slug: c.slug,
          name: c.name,
          toolCount: c.tools.length,
          status: c.status,
        })),
        secrets: (apiSecrets.data?.secrets ?? []).map((s) => ({
          handle: s.handle,
          name: s.name,
          allowedHosts: s.allowed_hosts,
        })),
        requestedCapabilities: app.manifest.requested_capabilities,
        grantedCapabilities: app.capabilities,
      }),
    [connectors.data?.connectors, apiSecrets.data?.secrets, app.manifest.requested_capabilities, app.capabilities],
  );

  const versions = useMemo(() => [...app.versions].sort((a, b) => b.seq - a.seq), [app.versions]);

  const NIX_PKG_RE = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/;
  const MOUNT_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,47}$/;

  const setCapabilityMode = (capKey: string, mode: CustomAppCapabilityMode) => {
    update.mutate(
      { capabilities: { ...app.capabilities, [capKey]: mode } },
      {
        onError: (e) => toast({ id: `cap-${app.slug}`, tone: "error", title: "Couldn’t update capability", description: errorText(e) }),
      },
    );
  };

  const addNixPackages = (raw: string) => {
    const names = raw
      .split(/[\s,]+/)
      .map((s) => s.trim())
      .filter(Boolean);
    if (names.length === 0) return;
    for (const pkg of names) {
      if (pkg === "." || pkg === ".." || !NIX_PKG_RE.test(pkg)) {
        toast({
          id: `nix-${app.slug}`,
          tone: "error",
          title: "Invalid Nix package name",
          description: `“${pkg}” must be a nixpkgs attribute name like yt-dlp or ffmpeg.`,
        });
        return;
      }
    }
    const nextCaps = { ...app.capabilities };
    for (const pkg of names) {
      nextCaps[`nix:${pkg}`] = "allowed";
    }
    update.mutate(
      { capabilities: nextCaps },
      {
        onError: (e) => toast({ id: `nix-${app.slug}`, tone: "error", title: "Couldn’t add Nix package", description: errorText(e) }),
      },
    );
  };

  const setMount = (name: string, rawPath: string) => {
    const trimmed = rawPath.trim();
    if (trimmed && !trimmed.startsWith("/") && !(trimmed.startsWith("~/") && trimmed.length > 2)) {
      toast({
        id: `mount-${app.slug}`,
        tone: "error",
        title: "Invalid host mount path",
        description: "Enter an absolute path (/...) or ~/... path.",
      });
      return;
    }
    const nextMounts = { ...(app.mounts ?? {}) };
    if (trimmed === "") {
      delete nextMounts[name];
    } else {
      nextMounts[name] = trimmed;
    }
    update.mutate(
      { mounts: nextMounts },
      {
        onError: (e) => toast({ id: `mount-${app.slug}`, tone: "error", title: "Couldn’t update mount", description: errorText(e) }),
      },
    );
  };

  const addMount = (raw: string) => {
    const trimmed = raw.trim();
    if (!trimmed) return;
    const eq = trimmed.indexOf("=");
    if (eq <= 0) {
      toast({
        id: `mount-${app.slug}`,
        tone: "error",
        title: "Invalid mount format",
        description: "Enter name=/path/to/file or name=~/...",
      });
      return;
    }
    const name = trimmed.slice(0, eq).trim();
    const hostPath = trimmed.slice(eq + 1).trim();
    if (!MOUNT_NAME_RE.test(name)) {
      toast({
        id: `mount-${app.slug}`,
        tone: "error",
        title: "Invalid mount name",
        description: "Use 1–48 lowercase letters, digits, hyphens, or underscores.",
      });
      return;
    }
    if (!hostPath) {
      toast({
        id: `mount-${app.slug}`,
        tone: "error",
        title: "Mount path required",
        description: "Enter name=/path/to/file or name=~/...",
      });
      return;
    }
    setMount(name, hostPath);
  };

  const setToolScope = (nextScope: "chats" | "app_only") => {
    update.mutate({
      manifest: { ...app.manifest, tool_scope: nextScope },
      note: `Set SQL tool scope to ${nextScope}`,
    });
  };

  const restoreVersion = (seq: number) => {
    update.mutate({ restore_seq: seq, note: `Restored v${seq}` });
  };

  return { capabilities, versions, setCapabilityMode, addNixPackages, setMount, addMount, setToolScope, restoreVersion, updating: update.isPending };
}

function useCustomAppDockChat({
  app,
  currentNav,
  runtimeError,
  controlledChatId,
  onSelectChat,
}: {
  app: CustomAppDetail;
  currentNav?: string;
  runtimeError?: string | null;
  controlledChatId?: string;
  onSelectChat?: (chatId: string) => void;
}) {
  const qc = useQueryClient();
  const dockScope: DockScope = `app:custom:${app.slug}`;
  const dockChats = useDockChats(dockScope);
  const spaceChats = useSpaceChats(app.space_id ?? undefined);
  const createChat = useCreateChat();
  const addDockChat = useAddDockChat();
  const startingPersona = useDockPersona(dockScope);

  const knownChats = useMemo(() => {
    const byId = new Map<string, Schemas["ChatSession"]>();
    for (const c of dockChats.data?.chats ?? []) byId.set(c.id, c);
    for (const c of spaceChats.data?.chats ?? []) byId.set(c.id, c);
    return [...byId.values()].sort((a, b) =>
      (b.last_message_at ?? b.created_at).localeCompare(a.last_message_at ?? a.created_at),
    );
  }, [dockChats.data?.chats, spaceChats.data?.chats]);

  const [selectedChatId, setSelectedChatId] = useState<string | undefined>(controlledChatId);
  const [prevControlled, setPrevControlled] = useState(controlledChatId);
  if (controlledChatId !== prevControlled) {
    setPrevControlled(controlledChatId);
    setSelectedChatId(controlledChatId);
  }
  const candidateChatId = selectedChatId ?? knownChats[0]?.id;
  const chatQuery = useChat(candidateChatId);
  const gone = chatQuery.error instanceof ApiError && chatQuery.error.status === 404;
  const chatId = gone ? undefined : candidateChatId;
  const chat = gone ? undefined : chatQuery.data;
  const running = chat?.state === "running";

  const rememberPersona = startingPersona.remember;
  const openPersonaId = chat?.persona?.id;
  useEffect(() => {
    rememberPersona(openPersonaId);
  }, [rememberPersona, openPersonaId]);

  const wasRunning = useRef(running);
  useEffect(() => {
    if (wasRunning.current && !running) {
      void qc.invalidateQueries({ queryKey: customAppKeys.all });
    }
    wasRunning.current = running;
  }, [running, qc]);

  const selectChat = useCallback(
    (nextId: string) => {
      setSelectedChatId(nextId);
      addDockChat.mutate({ scope: dockScope, chatId: nextId });
      onSelectChat?.(nextId);
    },
    [addDockChat, dockScope, onSelectChat],
  );

  const startChat = useCallback(() => {
    if (createChat.isPending) return;
    createChat.mutate(
      {
        title: app.name,
        hidden: true,
        ...(app.space_id ? { space_id: app.space_id } : {}),
        ...(startingPersona.id ? { persona_id: startingPersona.id } : {}),
      },
      {
        onSuccess: (created) => selectChat(created.id),
      },
    );
  }, [app.name, app.space_id, createChat, selectChat, startingPersona.id]);

  const personaName = chat ? personaLook(chat.speaker ?? chat.persona).name : startingPersona.look.name;
  const sections: DockChatSection[] = [{ label: app.name, chats: knownChats }];

  const switcher = (
    <DockChatSwitcher
      current={knownChats.find((c) => c.id === chatId)}
      sections={sections}
      newLabel="New chat for this app"
      onSelect={(next) => {
        if (next !== chatId) selectChat(next);
      }}
      onNew={startChat}
      creating={createChat.isPending}
      inline={!!chatId}
    />
  );

  const renderContext = (className?: string) => (
    <DockContext persona={personaName} label="Custom app context" className={className}>
      <span className={dockContextChip} title={`/apps/${app.slug}`}>
        <Icon name={resolveAppIcon(app.icon)} size={12} className="flex-none text-fg-tertiary" />
        <span className="min-w-0 truncate">Viewing: {app.name} · v{app.current_seq}</span>
      </span>
    </DockContext>
  );

  return {
    knownChats,
    chatId,
    chat,
    running,
    startingPersona,
    createChat,
    selectChat,
    startChat,
    switcher,
    renderContext,
  };
}

export function CustomAppCodePanel({ slug }: { slug: string }) {
  const query = useCustomApp(slug);
  if (query.isError) {
    return (
      <div className="p-4">
        <Banner tone="blocked" title="Couldn’t load custom app">
          {errorText(query.error)}
        </Banner>
      </div>
    );
  }
  if (!query.data) return <Skeleton className="m-3 h-40" />;
  return <CodeInspectorTab key={query.data.current.seq} app={query.data} />;
}
