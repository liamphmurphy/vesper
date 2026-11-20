export interface TwitchChatMessage {
  id: string;
  user: string;
  displayName: string;
  color: string;
  badges: string[];
  text: string;
  isAction: boolean;
  timestampMs: number;
}

export type ParsedIrcEvent =
  | { type: "ping"; payload: string }
  | { type: "privmsg"; channel: string; message: TwitchChatMessage }
  | { type: "clearmsg"; targetMsgId: string }
  | { type: "clearchat"; targetUser?: string };

const IRC_PALETTE = [
  "#ff5c5c",
  "#3ea6ff",
  "#4fd18b",
  "#d28cff",
  "#ffb347",
  "#26d0ce",
  "#ff7aa2",
  "#a3e635",
  "#ffa07a",
  "#60a5fa",
];

/** Deterministic IRC username color when Twitch's color tag is unset. */
export function ircUserColor(name: string): string {
  const s = name.toLowerCase();
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (h * 31 + s.charCodeAt(i)) | 0;
  }
  return IRC_PALETTE[Math.abs(h) % IRC_PALETTE.length];
}

function unescapeTagValue(raw: string): string {
  return raw.replace(/\\(:|s|\\|r|n)/g, (_, ch: string) => {
    switch (ch) {
      case ":":
        return ";";
      case "s":
        return " ";
      case "\\":
        return "\\";
      case "r":
        return "\r";
      case "n":
        return "\n";
      default:
        return ch;
    }
  });
}

/** Parses IRCv3 `@k=v;k2=v2` tag prefixes according to the IRCv3 escaping spec. */
export function parseIrcTags(raw: string): Record<string, string> {
  const tags: Record<string, string> = {};
  const trimmed = raw.startsWith("@") ? raw.slice(1) : raw;
  if (!trimmed) return tags;
  for (const part of trimmed.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const key = part.slice(0, eq);
    const val = part.slice(eq + 1);
    if (key) tags[key] = unescapeTagValue(val);
  }
  return tags;
}

function parseBadges(raw: string | undefined): string[] {
  if (!raw) return [];
  const out: string[] = [];
  for (const item of raw.split(",")) {
    const name = item.split("/")[0]?.trim();
    if (!name) continue;
    if (name === "broadcaster") out.push("BROADCASTER");
    else if (name === "moderator") out.push("MOD");
    else if (name === "vip") out.push("VIP");
    else if (name === "subscriber" || name === "founder") out.push("SUB");
  }
  return out;
}

/** Parses a single IRCv3 line from Twitch's WebSocket IRC edge. */
export function parseIrcLine(rawLine: string, nowMs = Date.now()): ParsedIrcEvent | null {
  const line = rawLine.replace(/\r?\n$/, "");
  if (!line) return null;

  let rest = line;
  let tags: Record<string, string> = {};
  if (rest.startsWith("@")) {
    const sp = rest.indexOf(" ");
    if (sp < 0) return null;
    tags = parseIrcTags(rest.slice(1, sp));
    rest = rest.slice(sp + 1).trimStart();
  }

  let prefix = "";
  if (rest.startsWith(":")) {
    const sp = rest.indexOf(" ");
    if (sp < 0) return null;
    prefix = rest.slice(1, sp);
    rest = rest.slice(sp + 1).trimStart();
  }

  const trailingIdx = rest.indexOf(" :");
  const head = trailingIdx >= 0 ? rest.slice(0, trailingIdx) : rest;
  const trailing = trailingIdx >= 0 ? rest.slice(trailingIdx + 2) : "";
  const parts = head.trim().split(/\s+/);
  const command = (parts[0] ?? "").toUpperCase();

  if (command === "PING") {
    return { type: "ping", payload: trailing || parts[1] || "tmi.twitch.tv" };
  }

  if (command === "PRIVMSG") {
    const channel = (parts[1] ?? "").replace(/^#/, "").toLowerCase();
    const bang = prefix.indexOf("!");
    const user = (bang >= 0 ? prefix.slice(0, bang) : prefix).toLowerCase() || "viewer";
    const displayName = tags["display-name"]?.trim() || user;
    const rawColor = tags.color?.trim() || "";
    const color = /^#[0-9a-fA-F]{6}$/.test(rawColor) ? rawColor : ircUserColor(displayName);
    const id = tags.id || `${nowMs}-${user}-${Math.random().toString(36).slice(2, 8)}`;
    const tmiTs = tags["tmi-sent-ts"] ? Number(tags["tmi-sent-ts"]) : nowMs;
    const isAction = trailing.startsWith("\x01ACTION ") && trailing.endsWith("\x01");
    const text = isAction ? trailing.slice(8, -1) : trailing;

    return {
      type: "privmsg",
      channel,
      message: {
        id,
        user,
        displayName,
        color,
        badges: parseBadges(tags.badges),
        text,
        isAction,
        timestampMs: Number.isFinite(tmiTs) && tmiTs > 0 ? tmiTs : nowMs,
      },
    };
  }

  if (command === "CLEARMSG") {
    const targetMsgId = tags["target-msg-id"] ?? "";
    if (!targetMsgId) return null;
    return { type: "clearmsg", targetMsgId };
  }

  if (command === "CLEARCHAT") {
    const targetUser = trailing.trim().toLowerCase() || undefined;
    return { type: "clearchat", targetUser };
  }

  return null;
}

/** Appends a message to a bounded chat ring buffer (newest at end). */
export function appendChatMessage(
  list: readonly TwitchChatMessage[],
  msg: TwitchChatMessage,
  maxMessages = 200,
): TwitchChatMessage[] {
  const next = [...list, msg];
  if (next.length > maxMessages) {
    return next.slice(next.length - maxMessages);
  }
  return next;
}
