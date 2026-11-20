import test from "node:test";
import assert from "node:assert/strict";
import { appendChatMessage, ircUserColor, parseIrcLine, parseIrcTags } from "./twitch-irc.ts";

test("parseIrcTags decodes IRCv3 escape sequences", () => {
  const tags = parseIrcTags("@display-name=Jane\\sDoe;emotes=;badge-info=;msg-param=a\\:b\\\\c");
  assert.equal(tags["display-name"], "Jane Doe");
  assert.equal(tags["msg-param"], "a;b\\c");
});

test("parseIrcLine handles PING, PRIVMSG, ACTION, CLEARMSG, and CLEARCHAT", () => {
  assert.deepEqual(parseIrcLine("PING :tmi.twitch.tv"), { type: "ping", payload: "tmi.twitch.tv" });

  const msg = parseIrcLine(
    "@badges=broadcaster/1,subscriber/12;color=#9146FF;display-name=CohhCarnage;id=msg-1;tmi-sent-ts=1700000000000 :cohhcarnage!cohh@cohh.tmi.twitch.tv PRIVMSG #cohhcarnage :Hello\\schat!",
    1234,
  );
  assert.equal(msg?.type, "privmsg");
  if (msg?.type === "privmsg") {
    assert.equal(msg.channel, "cohhcarnage");
    assert.deepEqual(msg.message.badges, ["BROADCASTER", "SUB"]);
    assert.equal(msg.message.color, "#9146FF");
    assert.equal(msg.message.displayName, "CohhCarnage");
    assert.equal(msg.message.isAction, false);
    assert.equal(msg.message.text, "Hello\\schat!");
    assert.equal(msg.message.timestampMs, 1700000000000);
  }

  const action = parseIrcLine(
    "@badges=moderator/1,vip/1;display-name=ModUser :moduser!m@m.tmi.twitch.tv PRIVMSG #test :\x01ACTION waves hello\x01",
    5000,
  );
  assert.equal(action?.type, "privmsg");
  if (action?.type === "privmsg") {
    assert.equal(action.message.isAction, true);
    assert.equal(action.message.text, "waves hello");
    assert.deepEqual(action.message.badges, ["MOD", "VIP"]);
    assert.equal(action.message.color, ircUserColor("ModUser"));
  }

  assert.deepEqual(parseIrcLine("@target-msg-id=msg-1 :tmi.twitch.tv CLEARMSG #cohhcarnage :bad"), {
    type: "clearmsg",
    targetMsgId: "msg-1",
  });
  assert.deepEqual(parseIrcLine(":tmi.twitch.tv CLEARCHAT #cohhcarnage :Spammer"), {
    type: "clearchat",
    targetUser: "spammer",
  });
  assert.deepEqual(parseIrcLine(":tmi.twitch.tv CLEARCHAT #cohhcarnage"), {
    type: "clearchat",
    targetUser: undefined,
  });
});

test("appendChatMessage enforces max ring-buffer capacity", () => {
  let buf = [];
  for (let i = 0; i < 5; i++) {
    buf = appendChatMessage(
      buf,
      { id: String(i), user: "u", displayName: "U", color: "#fff", badges: [], text: String(i), isAction: false, timestampMs: i },
      3,
    );
  }
  assert.deepEqual(
    buf.map((m) => m.id),
    ["2", "3", "4"],
  );
});
