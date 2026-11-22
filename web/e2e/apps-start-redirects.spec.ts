import { expect, test, type Route } from "@playwright/test";

// Docs, Slides and Designs have no homes of their own: each kind's start page is in Knowledge
// (/knowledge?kind=…), which the Mac app renders natively.
const json = (route: Route, data: unknown) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(data) });

test("the old Slides, Designs and Docs addresses open their start pages", async ({ page }) => {
  await page.route(/\/api\/v1\/knowledge\/query/, (route) => json(route, { columns: [], rows: [], has_more: false }));
  for (const [from, kind] of [["/apps/slides", "deck"], ["/apps/designs", "design"], ["/apps/docs", "document"]]) {
    await page.goto(from);
    await expect(page).toHaveURL(new RegExp(`/knowledge\\?kind=${kind}$`));
  }
});
