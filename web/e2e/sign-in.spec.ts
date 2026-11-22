import { expect, test, type Page } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

const refused = { status: 401, json: { code: "unauthenticated", message: "Sign in with the link from `make signin`." } };

function authStatus(page: Page, status: { claimed: boolean; password_set: boolean; signed_in: boolean }) {
  return page.route("**/api/v1/auth/status", (route) => route.fulfill({ json: status }));
}

test("a browser the API refuses lands on the sign-in page", async ({ page }) => {
  await installChatApi(page);
  await page.route("**/api/v1/**", (route) => route.fulfill(refused));
  await page.goto("/plans");
  await expect(page).toHaveURL(/\/sign-in$/);
  await expect(page.getByRole("heading", { name: "Sign in to Vesper" })).toBeVisible();
  await expect(page.getByText("make signin")).toBeVisible();
});

test("a used or expired link explains itself", async ({ page }) => {
  await page.goto("/sign-in?error=invalid");
  await expect(page.getByRole("heading", { name: "That sign-in link didn't work" })).toBeVisible();
  await expect(page.getByText(/already used or has expired/)).toBeVisible();
});

test("a fresh install is set up from the browser", async ({ page }) => {
  await authStatus(page, { claimed: false, password_set: false, signed_in: false });
  let sent: unknown;
  await page.route("**/api/v1/auth/setup", async (route) => {
    sent = route.request().postDataJSON();
    await route.fulfill({ json: { claimed: true, password_set: true, signed_in: true } });
  });
  await page.route("http://localhost:3100/", (route) => route.fulfill({ body: "<h1>App</h1>", contentType: "text/html" }));
  await page.goto("/sign-in");

  await expect(page.getByRole("heading", { name: "Set up Vesper" })).toBeVisible();
  await page.getByLabel("Username").fill("liam");
  await page.getByLabel("Password", { exact: true }).fill("correct horse");
  await page.getByLabel("Confirm password").fill("correct horses");
  await page.getByRole("button", { name: "Create sign-in" }).click();
  await expect(page.locator("form").getByRole("alert")).toHaveText("The passwords don't match.");
  expect(sent).toBeUndefined();

  await page.getByLabel("Confirm password").fill("correct horse");
  await page.getByRole("button", { name: "Create sign-in" }).click();
  await expect(page.getByRole("heading", { name: "App" })).toBeVisible();
  expect(sent).toEqual({ login: "liam", password: "correct horse" });
});

test("a claimed install asks for the password and shows a wrong one", async ({ page }) => {
  await authStatus(page, { claimed: true, password_set: true, signed_in: false });
  await page.route("**/api/v1/auth/login", (route) =>
    route.fulfill({ status: 401, json: { code: "unauthenticated", message: "That username and password don't match." } }),
  );
  await page.goto("/sign-in");

  await expect(page.getByRole("heading", { name: "Sign in to Vesper" })).toBeVisible();
  await expect(page.getByLabel("Confirm password")).toHaveCount(0);
  await page.getByLabel("Username").fill("liam");
  await page.getByLabel("Password").fill("wrong password");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.locator("form").getByRole("alert")).toHaveText("That username and password don't match.");
  await expect(page.getByText("make signin")).toBeVisible();
});
