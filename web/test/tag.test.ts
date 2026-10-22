import { expect, it, vi } from "vitest";

// Its own file: the tag build starts an instance that lives for the rest of the page.
it("the script tag reads its data attributes, posts back to where it came from, and replays queued calls", async () => {
  const calls: Array<{ url: string; names: unknown[] }> = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string, init: RequestInit) => {
      calls.push({ url, names: JSON.parse(init.body as string).items.map((i: { name?: string }) => i.name) });
      return new Response("{}", { status: 200 });
    }),
  );
  const script = document.createElement("script");
  script.src = "https://go.brand.com/_d/s.js";
  script.dataset.key = "pk_3f9c1e2a7b6d4c80";
  document.head.append(script);
  window.dropplink = { q: [["track", "add_to_cart", { sku: "RS-9" }], ["nope"]] };

  await import("../src/tag.js");
  await window.dropplink!.flush!();

  expect(calls[0]).toEqual({ url: "https://go.brand.com/_d/e", names: ["page_view", "add_to_cart"] });
  expect(typeof window.dropplink!.getVisitorId).toBe("function");
});
