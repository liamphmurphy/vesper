// Maps between the web command palette's OpenPaletteDetail and the native bridge's CommandPaletteRequest.
// Kept free of React and DOM imports so `node --test` covers it cleanly.

import { TYPE, type PageScope, type TypeKey } from "../command-palette.ts";
import type { CommandPaletteRequest, CommandPaletteScope } from "./protocol.ts";

export type OpenPaletteInput = {
  scope?: PageScope | "all" | "page";
  includeAgent?: boolean;
  query?: string;
};

const isInAppPath = (p: string | undefined): p is string => typeof p === "string" && p.startsWith("/") && !p.startsWith("//");

export function toPaletteRequest(
  detail: OpenPaletteInput | undefined,
  location: { pathname: string; search?: string },
): CommandPaletteRequest {
  const req: CommandPaletteRequest = {};
  if (isInAppPath(location.pathname)) req.path = location.pathname;
  if (location.search) req.search = location.search;
  if (detail?.scope === "all" || detail?.scope === "page") {
    req.scope = detail.scope;
  } else if (detail?.scope?.kind === "knowledge") {
    req.scope = "knowledge";
    req.scopeLabel = detail.scope.label;
  } else if (detail?.scope?.kind === "type") {
    req.scope = "type";
    req.scopeType = detail.scope.type;
    req.scopeLabel = detail.scope.label;
  }
  if (typeof detail?.includeAgent === "boolean") req.includeAgent = detail.includeAgent;
  if (typeof detail?.query === "string") req.query = detail.query;
  return req;
}

export function fromPaletteRequest(request: CommandPaletteRequest): {
  detail: OpenPaletteInput;
  pathname: string;
  search: string;
} {
  let scope: OpenPaletteInput["scope"];
  const kind: CommandPaletteScope | undefined = request.scope;
  if (kind === "knowledge") {
    scope = { kind: "knowledge", label: "Knowledge" };
  } else if (kind === "type" && request.scopeType && Object.prototype.hasOwnProperty.call(TYPE, request.scopeType)) {
    const typeKey = request.scopeType as TypeKey;
    scope = { kind: "type", type: typeKey, label: request.scopeLabel || TYPE[typeKey].label };
  } else if (kind === "all" || kind === "page") {
    scope = kind;
  }
  const detail: OpenPaletteInput = {};
  if (scope !== undefined) detail.scope = scope;
  if (typeof request.includeAgent === "boolean") detail.includeAgent = request.includeAgent;
  if (typeof request.query === "string") detail.query = request.query;
  return {
    detail,
    pathname: isInAppPath(request.path) ? request.path : "/",
    search: typeof request.search === "string" ? request.search : "",
  };
}
