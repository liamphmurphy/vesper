import assert from "node:assert/strict";
import test from "node:test";
import { findVesperLinkInArgv, hrefToVesperLink, parseVesperLink } from "../dist/deeplink.js";

const RUN = "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b";

test("parseVesperLink maps each supported target to its in-app path", () => {
  const cases = [
    [`vesper://run/${RUN}`, `/runs/${RUN}`],
    ["vesper://ticket/LAZYAGENTS-244", "/tickets/LAZYAGENTS-244"],
    [`vesper://epic/${RUN}`, `/epics/${RUN}`],
    [`vesper://page/${RUN}`, `/knowledge/${RUN}`],
    [`vesper://chat/${RUN}`, `/chat/${RUN}`],
    ["vesper://inbox", "/inbox"],
    ["vesper://inbox/", "/inbox"],
    ["VESPER://ticket/PAY-1", "/tickets/PAY-1"],
  ];
  for (const [link, path] of cases) {
    const r = parseVesperLink(link);
    assert.deepEqual(r, { ok: true, target: { kind: "navigate", path } }, link);
  }
  assert.deepEqual(parseVesperLink("vesper://capture"), { ok: true, target: { kind: "capture" } });
});

test("parseVesperLink rejects hostile and malformed input without producing a path", () => {
  const hostile = [
    "",
    "vesper:",
    "vesper://",
    "https://example.com/runs/x",
    "javascript:alert(1)",
    "vesper://run/not-a-uuid",
    `vesper://run/${RUN}/extra`,
    `vesper://run/${RUN}?next=https://evil.example`,
    `vesper://run/${RUN}#frag`,
    "vesper://ticket/lowercase-1",
    "vesper://ticket/PAY-0",
    "vesper://ticket/PAY-1%2F..%2F..%2Fsettings",
    "vesper://ticket/..%2F..%2Fsettings",
    "vesper://settings",
    "vesper://user:pass@run/" + RUN,
    "vesper://run:8080/" + RUN,
    `vesper://run/${RUN}%00`,
    "vesper://ticket/PAY-1 ",
    "vesper://ticket/PAY-1\nX",
    "vesper://run\\" + RUN,
    `vesper://chat/${"a".repeat(300)}`,
    "vesper://inbox/extra",
    "vesper://capture/now",
    "vesper:////evil.example/runs",
    42,
    null,
  ];
  for (const link of hostile) {
    const r = parseVesperLink(link);
    assert.equal(r.ok, false, `should reject ${JSON.stringify(link)}`);
    assert.equal(typeof r.reason, "string");
  }
});

test("hrefToVesperLink round-trips inbox hrefs and refuses anything else", () => {
  assert.equal(hrefToVesperLink(`/runs/${RUN}`), `vesper://run/${RUN}`);
  assert.equal(hrefToVesperLink("/tickets/PAY-214?tab=runs"), "vesper://ticket/PAY-214");
  assert.equal(hrefToVesperLink("/inbox"), "vesper://inbox");
  assert.equal(hrefToVesperLink(`/chat/${RUN}#m-3`), `vesper://chat/${RUN}`);
  assert.equal(hrefToVesperLink("/wiki/Some/Page"), null);
  assert.equal(hrefToVesperLink("https://github.com/x/y/pull/1"), null);
  assert.equal(hrefToVesperLink("//evil.example/runs/" + RUN), null);
  for (const href of [`/runs/${RUN}`, "/tickets/PAY-214", "/inbox", `/knowledge/${RUN}`]) {
    const link = hrefToVesperLink(href);
    assert.ok(link);
    assert.equal(parseVesperLink(link).target.path, href.split("?")[0]);
  }
});

test("findVesperLinkInArgv picks a vesper link out of argv", () => {
  assert.equal(findVesperLinkInArgv(["/Applications/Vesper.app/Contents/MacOS/Vesper", "--foo", "vesper://inbox"]), "vesper://inbox");
  assert.equal(findVesperLinkInArgv(["/x", "--inspect"]), null);
});
