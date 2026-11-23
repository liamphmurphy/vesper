import test from "node:test";
import assert from "node:assert/strict";
import { isGalleryFence, isProductFence, mediaHost, parseGallery, parseProduct } from "./chat-media.ts";

test("fence predicates match gallery and product tags", () => {
  assert.equal(isGalleryFence("gallery"), true);
  assert.equal(isGalleryFence("GALLERY "), true);
  assert.equal(isGalleryFence("product"), false);
  assert.equal(isProductFence("product"), true);
  assert.equal(isProductFence("json"), false);
});

test("parseGallery validates urls, drops unsafe protocols and caps items", () => {
  const spec = parseGallery(JSON.stringify({
    title: "Article Photos",
    items: [
      { image: "https://cdn.example/1.jpg", url: "https://news.example/a", caption: "First photo", source: "News" },
      { image: "javascript:alert(1)", url: "ftp://bad.example/file" },
      { url: "https://article.example/og-only", caption: "Page fallback" },
    ],
  }));
  assert.ok(spec);
  assert.equal(spec.title, "Article Photos");
  assert.equal(spec.items.length, 2);
  assert.equal(spec.items[0].image, "https://cdn.example/1.jpg");
  assert.equal(spec.items[1].url, "https://article.example/og-only");
  assert.equal(parseGallery("{bad json"), null);
  assert.equal(parseGallery(JSON.stringify({ items: [{ image: "data:image/png;base64,abc" }] })), null);
});

test("parseProduct parses cards with specs, price, rating and sanitizes urls", () => {
  const spec = parseProduct(JSON.stringify({
    title: "Top Keyboards",
    items: [
      {
        name: "Keychron Q1 Pro",
        url: "https://shop.example/q1",
        image: "https://cdn.example/q1.png",
        price: "$199",
        rating: "4.8/5",
        badge: "Top Pick",
        specs: ["QMK/VIA", "Aluminum", "Wireless"],
      },
      { name: "No URL", image: "https://user:pass@secret.example/x.png" },
    ],
  }));
  assert.ok(spec);
  assert.equal(spec.items.length, 2);
  assert.equal(spec.items[0].price, "$199");
  assert.deepEqual(spec.items[0].specs, ["QMK/VIA", "Aluminum", "Wireless"]);
  assert.equal(spec.items[1].image, undefined);
  assert.equal(mediaHost("https://www.shop.example/q1"), "shop.example");
});
