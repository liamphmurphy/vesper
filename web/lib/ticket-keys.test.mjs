import test from "node:test";
import assert from "node:assert/strict";
import { linkTicketKeys } from "./ticket-keys.ts";

test("bare ticket keys become [[links]], but not in code or existing links", () => {
  assert.equal(linkTicketKeys("PAY-1 and [[PAY-2]] and `PAY-3`"), "[[PAY-1]] and [[PAY-2]] and `PAY-3`");
  assert.equal(linkTicketKeys("```\nPAY-1\n```\nOPS-7"), "```\nPAY-1\n```\n[[OPS-7]]");
});
