import { expect, test, type Page } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

async function askFirst(page: Page, prompt: string) {
  await page.goto("/chat?project=WEB");
  const box = page.getByRole("combobox", { name: "Message" });
  await box.fill(prompt);
  await box.press("Enter");
}

async function askNext(page: Page, prompt: string) {
  const box = page.getByLabel("Message", { exact: true });
  await box.fill(prompt);
  await box.press("Enter");
}

test("PR blocks stay anchored to their reply messages when later turns follow", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await askFirst(page, "push: Add first feature");

  const replies = page.getByTestId("assistant-message");
  await expect(replies).toHaveCount(1);
  await expect(replies.nth(0).getByTestId("push-request")).toContainText("Add first feature");

  // Follow-up reply without a PR lands below PR #1 instead of above it.
  await askNext(page, "Follow up question");
  await expect(replies).toHaveCount(2);
  await expect(replies.nth(0).getByTestId("push-request")).toContainText("Add first feature");
  await expect(replies.nth(1)).toContainText("Echo: Follow up question");
  await expect(replies.nth(1).getByTestId("push-request")).toHaveCount(0);

  const pr1Box = await replies.nth(0).getByTestId("push-request").boundingBox();
  const reply2Box = await replies.nth(1).boundingBox();
  expect(pr1Box && reply2Box && pr1Box.y < reply2Box.y).toBeTruthy();

  // A second PR attaches to its own turn; pushing the first keeps both cards in their turns.
  await askNext(page, "push: Add second feature");
  await expect(replies).toHaveCount(3);
  await expect(replies.nth(0).getByTestId("push-request")).toContainText("Add first feature");
  await expect(replies.nth(1).getByTestId("push-request")).toHaveCount(0);
  await expect(replies.nth(2).getByTestId("push-request")).toContainText("Add second feature");

  await replies.nth(0).getByRole("button", { name: "Push & open PR" }).click();
  await expect(replies.nth(0).getByTestId("push-request")).toHaveAttribute("data-state", "pushed");
  await expect(replies.nth(0).getByTestId("push-request")).toContainText("Pull request #99 on GitHub");
  await expect(replies.nth(2).getByTestId("push-request")).toHaveAttribute("data-state", "pending");

  const cards = page.getByTestId("push-request");
  await expect(cards).toHaveCount(2);
  const firstCardBox = await cards.nth(0).boundingBox();
  const currentReply2Box = await replies.nth(1).boundingBox();
  const secondCardBox = await cards.nth(1).boundingBox();
  expect(firstCardBox && currentReply2Box && secondCardBox && firstCardBox.y < currentReply2Box.y && currentReply2Box.y < secondCardBox.y).toBeTruthy();
});

test("while a turn runs a staging push request shows live, then anchors to its reply", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 1200 });
  await askFirst(page, "push-live: Live branch");

  const liveCard = page.getByTestId("thinking").getByTestId("push-request");
  await expect(liveCard).toBeVisible();
  await expect(liveCard).toHaveAttribute("data-state", "staging");
  await expect(liveCard).toContainText("Live branch");

  const reply = page.getByTestId("assistant-message").last();
  await expect(reply.getByTestId("push-request")).toHaveAttribute("data-state", "pending");
  await expect(page.getByTestId("thinking")).toHaveCount(0);
});

test("legacy push requests without message_id stay in their historical turn and errors stay per card", async ({ page }) => {
  const api = await installChatApi(page, { replyDelayMs: 10 });
  await askFirst(page, "push: Legacy first PR");
  const replies = page.getByTestId("assistant-message");
  await expect(replies).toHaveCount(1);

  await askNext(page, "push: Legacy second PR");
  await expect(replies).toHaveCount(2);

  await askNext(page, "Final check");
  await expect(replies).toHaveCount(3);

  const chat = api.chats[0];
  const reqs = api.pushRequests.get(chat.id) ?? [];
  const chatMsgs = api.messages.get(chat.id) ?? [];
  expect(reqs).toHaveLength(2);
  expect(chatMsgs).toHaveLength(6);

  // Give the three turns distinct timestamps and clear message_id to model legacy rows
  // saved before message_id existed (each request created between its prompt and reply).
  const stamp = (sec: number) => new Date(Date.UTC(2026, 10, 15, 10, 0, sec)).toISOString();
  chatMsgs.forEach((m, i) => {
    m.created_at = stamp(i * 20);
  });
  reqs[0].message_id = undefined;
  reqs[0].created_at = stamp(10);
  reqs[1].message_id = undefined;
  reqs[1].created_at = stamp(50);
  api.refusePush.set(reqs[0].id, "Branch protected");

  await page.reload();
  await expect(replies).toHaveCount(3);
  await expect(replies.nth(0).getByTestId("push-request")).toContainText("Legacy first PR");
  await expect(replies.nth(1).getByTestId("push-request")).toContainText("Legacy second PR");
  await expect(replies.nth(2).getByTestId("push-request")).toHaveCount(0);

  await replies.nth(0).getByRole("button", { name: "Push & open PR" }).click();
  await expect(replies.nth(0).getByRole("alert")).toContainText("Not pushed: Branch protected");
  await expect(replies.nth(1).getByRole("alert")).toHaveCount(0);
});

test("open PR cards offer Open in Dev workspace when enabled and hide once merged", async ({ page }) => {
  const api = await installChatApi(page, { replyDelayMs: 10, devWorkspaceEnabled: true });
  await askFirst(page, "push: Open PR feature");
  const card = page.getByTestId("push-request");
  await card.getByRole("button", { name: "Push & open PR" }).click();
  await expect(card).toHaveAttribute("data-state", "pushed");

  // Merged PRs do not offer Open in Dev workspace.
  const chat = api.chats[0];
  const reqs = api.pushRequests.get(chat.id) ?? [];
  expect(reqs).toHaveLength(1);
  reqs[0].pr_state = "merged";
  await page.reload();
  await expect(page.getByTestId("push-request")).toContainText("merged");
  await expect(page.getByRole("button", { name: "Open in Dev workspace" })).toHaveCount(0);

  // Open PRs offer Open in Dev workspace, pull the branch, and navigate to /dev.
  reqs[0].pr_state = "open";
  await page.reload();
  const openBtn = page.getByRole("button", { name: "Open in Dev workspace" });
  await expect(openBtn).toBeVisible();
  await openBtn.click();
  await expect(page).toHaveURL(/\/dev$/);
  expect(api.devWorkspaceOpenBranches).toEqual([
    { repository: "https://github.com/acme/alpha.git", branch: "feat/open-pr-feature", pr_number: 99 },
  ]);
});
