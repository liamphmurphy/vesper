"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { useDevWorkspace, useDevWorkspaceAction } from "@/lib/api/dev-workspace-hooks";
import {
  devWorkspaceSocketUrl,
  devWorkspaceStatusLabel,
  devWorkspaceStatusTone,
  FULLSCREEN_LOCK_KEYS,
  fullscreenExitHint,
} from "@/lib/dev-workspace";
import { cx } from "@/lib/cx";
import { Button, ButtonLink } from "@/components/ui/button";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { SmallPill } from "@/components/domain/labels";

const GRUVBOX_THEME = {
  background: "#282828",
  foreground: "#ebdbb2",
  cursor: "#ebdbb2",
  cursorAccent: "#282828",
  selectionBackground: "#504945",
  black: "#282828",
  red: "#cc241d",
  green: "#98971a",
  yellow: "#d79921",
  blue: "#458588",
  magenta: "#b16286",
  cyan: "#689d6a",
  white: "#a89984",
  brightBlack: "#928374",
  brightRed: "#fb4934",
  brightGreen: "#b8bb26",
  brightYellow: "#fabd2f",
  brightBlue: "#83a598",
  brightMagenta: "#d3869b",
  brightCyan: "#8ec07c",
  brightWhite: "#ebdbb2",
};

type ConnState = "connecting" | "connected" | "disconnected";

type NavigatorWithKeyboardLock = Navigator & {
  keyboard?: {
    lock?: (keys?: readonly string[]) => Promise<void>;
    unlock?: () => void;
  };
};

export function DevTerminal() {
  const q = useDevWorkspace();
  const action = useDevWorkspaceAction();
  const [nativeFullscreen, setNativeFullscreen] = useState(false);
  const [fallbackFullscreen, setFallbackFullscreen] = useState(false);
  const [keyboardLocked, setKeyboardLocked] = useState(false);
  const [conn, setConn] = useState<ConnState>("disconnected");
  const [reconnectSeq, setReconnectSeq] = useState(0);
  const wrapperRef = useRef<HTMLDivElement | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const wsRef = useRef<WebSocket | null>(null);

  const wsData = q.data;
  const port = wsData?.state === "ready" ? wsData.port : null;
  const fullscreen = nativeFullscreen || fallbackFullscreen;

  const sendResize = useCallback((cols: number, rows: number) => {
    const sock = wsRef.current;
    if (sock && sock.readyState === WebSocket.OPEN) {
      sock.send(JSON.stringify({ type: "resize", cols, rows }));
    }
  }, []);

  useEffect(() => {
    if (!port || !containerRef.current) return;
    const host = containerRef.current;
    const term = new Terminal({
      cursorBlink: true,
      fontSize: 13,
      fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
      theme: GRUVBOX_THEME,
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(host);
    fit.fit();
    termRef.current = term;
    fitRef.current = fit;

    const url = devWorkspaceSocketUrl(window.location, port, term.cols, term.rows);
    setConn("connecting");
    const sock = new WebSocket(url);
    sock.binaryType = "arraybuffer";
    wsRef.current = sock;

    sock.onopen = () => {
      setConn("connected");
      fit.fit();
      sendResize(term.cols, term.rows);
      term.focus();
    };
    sock.onmessage = (ev) => {
      if (ev.data instanceof ArrayBuffer) {
        term.write(new Uint8Array(ev.data));
      } else if (typeof ev.data === "string") {
        term.write(ev.data);
      }
    };
    sock.onclose = () => {
      setConn("disconnected");
    };
    sock.onerror = () => {
      setConn("disconnected");
    };

    const dataSub = term.onData((data) => {
      if (sock.readyState === WebSocket.OPEN) {
        sock.send(data);
      }
    });
    const resizeSub = term.onResize(({ cols, rows }) => sendResize(cols, rows));
    const ro = new ResizeObserver(() => {
      fit.fit();
    });
    ro.observe(host);

    return () => {
      ro.disconnect();
      resizeSub.dispose();
      dataSub.dispose();
      sock.close();
      term.dispose();
      wsRef.current = null;
      termRef.current = null;
      fitRef.current = null;
      setConn("disconnected");
    };
  }, [port, reconnectSeq, sendResize]);

  useEffect(() => {
    const onFullscreenChange = () => {
      const active = !!wrapperRef.current && document.fullscreenElement === wrapperRef.current;
      setNativeFullscreen(active);
      if (!active) {
        setKeyboardLocked(false);
      }
    };
    document.addEventListener("fullscreenchange", onFullscreenChange);
    return () => document.removeEventListener("fullscreenchange", onFullscreenChange);
  }, []);

  useEffect(() => {
    let cancelled = false;
    const raf = requestAnimationFrame(() => {
      fitRef.current?.fit();
      termRef.current?.focus();
    });
    const kb = (navigator as NavigatorWithKeyboardLock).keyboard;
    if (nativeFullscreen && kb?.lock) {
      void kb
        .lock([...FULLSCREEN_LOCK_KEYS])
        .then(() => {
          if (!cancelled) setKeyboardLocked(true);
        })
        .catch(() => {
          if (!cancelled) setKeyboardLocked(false);
        });
    } else {
      kb?.unlock?.();
    }
    return () => {
      cancelled = true;
      cancelAnimationFrame(raf);
      kb?.unlock?.();
    };
  }, [nativeFullscreen, fallbackFullscreen]);

  const enterFullscreen = useCallback(async () => {
    const el = wrapperRef.current;
    if (!el || !el.requestFullscreen) {
      setFallbackFullscreen(true);
      return;
    }
    try {
      await el.requestFullscreen({ navigationUI: "hide" });
    } catch {
      try {
        await el.requestFullscreen();
      } catch {
        setFallbackFullscreen(true);
      }
    }
  }, []);

  const exitFullscreen = useCallback(async () => {
    setFallbackFullscreen(false);
    if (document.fullscreenElement) {
      try {
        await document.exitFullscreen();
      } catch {
        /* already exited */
      }
    }
  }, []);

  if (q.isPending) {
    return <Skeleton className="h-[calc(100dvh-5rem)] w-full" />;
  }
  if (q.isError) {
    return (
      <Banner tone="blocked" title="Couldn’t load dev workspace">
        {q.error.message}
      </Banner>
    );
  }
  if (!wsData?.enabled) {
    return (
      <EmptyState
        icon="terminal"
        title="Dev workspace is disabled"
        actions={<ButtonLink href="/settings#dev-workspace" variant="primary">Configure in Settings</ButtonLink>}
      >
        Enable the persistent Nix + LazyVim workspace in Settings to spin up the container and auto-clone your repositories.
      </EmptyState>
    );
  }

  return (
    <div
      ref={wrapperRef}
      className={cx(
        "relative flex flex-col overflow-hidden bg-[#1d2021]",
        fullscreen ? "fixed inset-0 z-50 h-dvh w-screen" : "h-[calc(100dvh-2rem)] rounded-lg border border-border",
      )}
    >
      {fullscreen ? (
        <div className="pointer-events-none absolute right-3 top-2 z-10 flex items-center gap-2 opacity-35 transition-opacity hover:opacity-100 focus-within:opacity-100">
          <div className="pointer-events-auto flex items-center gap-2 rounded-md border border-[#3c3836] bg-[#1d2021]/90 px-2.5 py-1 text-11 text-[#ebdbb2] backdrop-blur-sm">
            <span
              className={cx(
                "size-1.5 rounded-full",
                conn === "connected" ? "bg-[#b8bb26]" : conn === "connecting" ? "bg-[#fabd2f]" : "bg-[#fb4934]",
              )}
            />
            <span className="text-[#a89984]">{fullscreenExitHint(nativeFullscreen, keyboardLocked)}</span>
            {port && conn === "disconnected" && (
              <button
                type="button"
                onClick={() => setReconnectSeq((n) => n + 1)}
                className="rounded border border-[#504945] px-1.5 py-0.5 text-[#ebdbb2] hover:bg-[#3c3836]"
              >
                Reconnect
              </button>
            )}
            <button
              type="button"
              onClick={() => void exitFullscreen()}
              className="rounded bg-[#3c3836] px-2 py-0.5 font-medium text-[#ebdbb2] hover:bg-[#504945]"
            >
              Exit
            </button>
          </div>
        </div>
      ) : (
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border bg-surface px-3 py-2 text-13">
          <div className="flex flex-wrap items-center gap-2.5">
            <span className="font-semibold text-fg">Dev workspace</span>
            <code className="font-mono text-12 text-fg-tertiary">/workspace</code>
            <SmallPill tone={conn === "connected" ? "done" : devWorkspaceStatusTone(wsData.state)}>
              {conn === "connected" ? "Connected · tmux" : conn === "connecting" ? "Connecting…" : devWorkspaceStatusLabel(wsData)}
            </SmallPill>
            <span className="hidden text-12 text-fg-tertiary md:inline">
              Tip: Fullscreen locks Ctrl+W / Esc to Neovim (Chromium)
            </span>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <Button
              variant="outline"
              disabled={wsData.state === "starting" || action.isPending}
              onClick={() => action.mutate("sync")}
            >
              Sync repos
            </Button>
            {port && conn === "disconnected" && (
              <Button variant="outline" onClick={() => setReconnectSeq((n) => n + 1)}>
                Reconnect
              </Button>
            )}
            <Link
              href="/settings#dev-workspace"
              className="rounded-md border border-border bg-surface px-2.5 py-1 text-12 font-medium text-fg hover:bg-hover"
            >
              Settings
            </Link>
            <Button variant="primary" onClick={() => void enterFullscreen()}>
              Fullscreen
            </Button>
          </div>
        </div>
      )}

      {wsData.state === "error" && wsData.error && (
        <div className="border-b border-border bg-pill-blocked-bg px-4 py-2 text-12 text-pill-blocked-fg">
          {wsData.error}
        </div>
      )}

      {!port ? (
        <div className="grid flex-1 place-items-center p-6 text-center text-[#ebdbb2]">
          <div className="max-w-md space-y-3">
            <p className="text-15 font-medium">
              {wsData.state === "starting"
                ? wsData.step || "Preparing Nix + LazyVim container…"
                : "Dev workspace container is not ready yet."}
            </p>
            <p className="text-13 text-[#a89984]">
              First boot builds the Nix profile and clones configured repositories.
            </p>
            {wsData.state !== "starting" && (
              <Button variant="primary" onClick={() => action.mutate("start")}>
                Start container
              </Button>
            )}
          </div>
        </div>
      ) : (
        <div
          ref={containerRef}
          data-dev-terminal="true"
          onClick={() => termRef.current?.focus()}
          className="min-h-0 flex-1 overflow-hidden p-1"
        />
      )}
    </div>
  );
}
