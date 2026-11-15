import { expect, test } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// Customization → You: display name, role title, email addresses, picture upload/replace/remove. The menu has no profile.

const PNG = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64");
const profile = (page: import("@playwright/test").Page) => page.getByRole("region", { name: "Profile" });
const headerPic = (page: import("@playwright/test").Page) => page.getByRole("region", { name: "Customization" }).locator("header img");

async function openProfile(page: import("@playwright/test").Page) {
  await page.goto("/customization?who=person");
  await page.getByRole("button", { name: "Edit profile" }).click();
}

test("edit the display name and role: Save is gated, and the shell shows the new name", async ({ page }) => {
  const mock = await installChatApi(page);
  await openProfile(page);
  const section = profile(page);
  await expect(section.getByRole("list", { name: "Email addresses" })).toHaveText(/liam@example\.com/);
  const save = section.getByRole("button", { name: "Save profile" });
  await expect(save).toBeDisabled();

  await section.getByLabel("Display name").fill("   ");
  await expect(section.getByText("Enter a display name.")).toBeVisible();
  await expect(save).toBeDisabled();
  await section.getByLabel("Display name").fill("x".repeat(81));
  await expect(section.getByText("Use 80 characters or fewer.")).toBeVisible();
  await expect(save).toBeDisabled();

  await section.getByLabel("Display name").fill("Maya Chen");
  await section.getByLabel("Role title").fill("Engineering lead");
  await save.click();
  await expect(section.getByRole("status")).toHaveText("Profile saved.");
  expect(mock.profileRequests).toEqual([`PATCH ${JSON.stringify({ name: "Maya Chen", role_title: "Engineering lead" })}`]);
  const header = page.getByRole("region", { name: "Customization" }).locator("header").last();
  await expect(header).toContainText("Maya Chen");
  await expect(header).toContainText("Engineering lead");
  await expect(save).toBeDisabled();
});

test("add, reorder and remove email addresses; Save sends the whole list, primary first", async ({ page }) => {
  const mock = await installChatApi(page);
  await openProfile(page);
  const section = profile(page);
  const list = section.getByRole("list", { name: "Email addresses" });
  const save = section.getByRole("button", { name: "Save profile" });
  // The only address can't be removed.
  await expect(list.getByRole("button", { name: "Remove liam@example.com" })).toBeDisabled();

  const add = section.getByPlaceholder("Add another address");
  await add.fill("not an email");
  await add.press("Enter");
  await expect(section.getByText("That doesn’t look like an email address.")).toBeVisible();
  await add.fill("LIAM@example.com");
  await section.getByRole("button", { name: "Add", exact: true }).click();
  await expect(section.getByText("That address is already listed.")).toBeVisible();
  expect(mock.profileRequests).toEqual([]);

  // Enter adds rather than saving the form.
  await add.fill("liam@phmurphy.com");
  await add.press("Enter");
  await add.fill("old@example.com");
  await add.press("Enter");
  await expect(list.getByRole("listitem")).toHaveCount(3);
  expect(mock.profileRequests).toEqual([]);
  await list.getByRole("button", { name: "Remove old@example.com" }).click();
  await list.getByRole("listitem").filter({ hasText: "liam@phmurphy.com" }).getByRole("button", { name: "Make primary" }).click();
  await expect(list.getByRole("listitem").first()).toContainText("liam@phmurphy.com");
  await expect(list.getByRole("listitem").first()).toContainText("Primary");
  await expect(section.getByText("Each coding chat asks which one its commits use.")).toBeVisible();

  await save.click();
  await expect(section.getByRole("status")).toHaveText("Profile saved.");
  expect(mock.profileRequests).toEqual([`PATCH ${JSON.stringify({ emails: ["liam@phmurphy.com", "liam@example.com"] })}`]);
  await expect(save).toBeDisabled();

  // A server refusal lands on the list.
  await add.fill("someone@taken.example");
  await add.press("Enter");
  await list.getByRole("listitem").filter({ hasText: "someone@taken.example" }).getByRole("button", { name: "Make primary" }).click();
  await save.click();
  await expect(section.getByRole("alert").filter({ hasText: "already another person's primary email" })).toBeVisible();
  expect(mock.unhandled).toEqual([]);
});

test("upload, replace and remove a picture; the header follows", async ({ page }) => {
  const mock = await installChatApi(page);
  await openProfile(page);
  const section = profile(page);
  await expect(headerPic(page)).toHaveCount(0);
  await expect(section.getByRole("button", { name: "Remove", exact: true })).toHaveCount(0);

  // Client checks: a text file never reaches the server.
  await section.getByLabel("Profile picture file").setInputFiles({ name: "notes.txt", mimeType: "text/plain", buffer: Buffer.from("hi") });
  await expect(section.getByRole("alert")).toContainText("type not supported");
  expect(mock.profileRequests).toEqual([]);

  await section.getByLabel("Profile picture file").setInputFiles({ name: "me.png", mimeType: "image/png", buffer: PNG });
  await expect(section.getByRole("button", { name: "Replace picture" })).toBeVisible();
  await expect(section.locator("img")).toHaveCount(1);
  await expect(headerPic(page)).toHaveCount(1);
  await expect(section.getByRole("alert")).toHaveCount(0);

  await section.getByRole("button", { name: "Remove", exact: true }).click();
  await expect(section.getByRole("button", { name: "Upload picture" })).toBeVisible();
  await expect(headerPic(page)).toHaveCount(0);
  expect(mock.profileRequests).toEqual(["PUT avatar", "DELETE avatar"]);
});

test("the profile is only under Customization, not in the menu or Settings", async ({ page }) => {
  await installChatApi(page);
  await page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1"));
  await page.goto("/chat?project=WEB");
  const menu = page.getByRole("complementary", { name: "Main menu" });
  await expect(menu.getByRole("button", { name: "New chat" })).toBeVisible();
  await expect(menu.getByRole("link", { name: /Liam/ })).toHaveCount(0);
  await expect(menu.getByRole("link", { name: "Customization" })).toHaveCount(0);
  await page.getByRole("complementary", { name: "Right rail" }).getByRole("link", { name: "Customization", exact: true }).click();
  await page.getByRole("button", { name: /^You/ }).click();
  await page.getByRole("button", { name: "Edit profile" }).click();
  await expect(profile(page).getByLabel("Display name")).toHaveValue("Liam");
  await page.goto("/settings");
  await expect(page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /Profile/ })).toHaveCount(0);
});
