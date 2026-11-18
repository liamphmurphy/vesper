import { expect, test } from "@playwright/test";
import { installChatApi, openEmptyChat } from "./mock-chat-api";

// Below lg the open dock floats over the chat. In the Mac app the composer floats too
// (native-mac.css lifts it above the transcript), and the dock must still cover it.

test("in the Mac app, a dock floating over a narrow chat covers the composer", async ({ page }) => {
  // The Mac app's user script (macos/Sources/Vesper/Window/WebViewFactory.swift) and a bridge
  // handler that drops every message, so the page runs as it does in the app's web view.
  await page.addInitScript(() => {
    const w = window as unknown as Record<string, unknown>;
    w.__VESPER_NATIVE__ = { v: 1, platform: "macos" };
    w.webkit = { messageHandlers: { vesper: { postMessage: () => {} } } };
    // Chromium runs init scripts before <html> is parsed, which would drop a class added now.
    document.addEventListener("DOMContentLoaded", () => document.documentElement.classList.add("native-mac"));
  });
  await page.setViewportSize({ width: 900, height: 800 });
  await installChatApi(page);
  const id = await openEmptyChat(page);
  await page.goto(`/chat/${id}?panel=activity`);

  const dock = page.getByRole("complementary", { name: "Panel" });
  await expect(dock.getByRole("tabpanel", { name: "Activity" })).toBeVisible();
  const composer = page.locator("[data-composer-frame]");
  await expect(composer).toBeVisible();

  // Check once the composer floats as it does in the app: raised by native-mac.css and placed by its
  // measured height (lib/dock-height).
  const floating = page.locator("[data-chat-dock]");
  await expect(floating).toHaveCSS("z-index", "10");
  await expect.poll(() => floating.evaluate((el) => getComputedStyle(el.parentElement!).getPropertyValue("--chat-dock-h"))).not.toBe("");
  // While the page fades in, its opacity holds the composer down; the bug shows once the fade ends.
  await page.evaluate(() =>
    Promise.all(document.getAnimations().filter((a) => a.effect?.getComputedTiming().endTime !== Infinity).map((a) => a.finished)),
  );

  // What is drawn at a point inside both: the dock, or the composer above it.
  const topmost = () =>
    page.evaluate(() => {
      const d = document.querySelector('aside[aria-label="Panel"]')!.getBoundingClientRect();
      const c = document.querySelector("[data-composer-frame]")!.getBoundingClientRect();
      if (c.right < d.left + 20) return "no overlap";
      const hit = document.elementFromPoint(d.left + 10, c.top + c.height / 2);
      return hit?.closest('aside[aria-label="Panel"]') ? "dock" : hit?.closest("[data-composer-frame]") ? "composer" : "other";
    });
  expect(await topmost(), "the dock, not the composer, is on top where they overlap").toBe("dock");
});
