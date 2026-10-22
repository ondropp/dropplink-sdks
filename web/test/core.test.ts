import { readFileSync } from "node:fs";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_ENDPOINT, type DropplinkConfig, createDropplink } from "../src/core.js";

const KEY = "pk_3f9c1e2a7b6d4c80";
const ENDPOINT = "https://go.brand.com/_d/e";
const CLICK = "c_0123456789abcdef";
// Tests run from web/; the fixtures live once, at the repo root (CONTRIBUTING.md).
const contract = (path: string) => JSON.parse(readFileSync(`../contract/${path}`, "utf8"));

interface Call {
  url: string;
  body: { key: string; visitorId: string; sdkVersion: string; items: Array<Record<string, unknown>> };
  keepalive: boolean;
  contentType: string;
}

let calls: Call[];
let respond: (url: string) => Response | "network-error";
let stop: AbortController;

const ok = () => new Response(JSON.stringify({ accepted: 1, duplicates: 0, rejected: [] }), { status: 200 });
const status = (code: number, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify({ error: { code: "x", message: "x" } }), { status: code, headers });

function setReferrer(value: string) {
  Object.defineProperty(document, "referrer", { value, configurable: true });
}
function setVisibility(value: "visible" | "hidden") {
  Object.defineProperty(document, "visibilityState", { value, configurable: true });
  document.dispatchEvent(new Event("visibilitychange"));
}

function start(config: Partial<DropplinkConfig> = {}, url = "/") {
  stop?.abort();
  history.replaceState(null, "", url);
  stop = new AbortController();
  return createDropplink({ key: KEY, endpoint: ENDPOINT, ...config }, { signal: stop.signal });
}

const items = () => calls.flatMap((c) => c.body.items);
const queued = () => (JSON.parse(localStorage.getItem("dl_q") ?? '{"items":[]}') as { items: unknown[] }).items;
const cookie = (name: string) => document.cookie.match(new RegExp(`(?:^|; )${name}=([^;]*)`))?.[1] ?? null;

beforeEach(() => {
  localStorage.clear();
  for (const c of document.cookie.split("; ").filter(Boolean)) document.cookie = `${c.split("=")[0]}=; max-age=0; path=/`;
  setReferrer("");
  Object.defineProperty(document, "visibilityState", { value: "visible", configurable: true });
  calls = [];
  respond = () => ok();
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string, init: RequestInit) => {
      calls.push({
        url,
        body: JSON.parse(init.body as string),
        keepalive: !!init.keepalive,
        contentType: (init.headers as Record<string, string>)["content-type"]!,
      });
      const res = respond(url);
      if (res === "network-error") throw new TypeError("Failed to fetch");
      return res;
    }),
  );
});

afterEach(() => {
  stop?.abort();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("landing", () => {
  it("a landing from a creator's link: page view with referrer, UTM tags and click id, in the contract's shape", async () => {
    setReferrer("https://l.instagram.com/");
    const dl = start({}, `/products/red-shoe?dropp_click_id=${CLICK}&utm_source=instagram&size=9`);
    await dl.flush();

    expect(calls).toHaveLength(1);
    const [call] = calls;
    expect(call!.url).toBe(ENDPOINT);
    // text/plain: no CORS preflight.
    expect(call!.contentType).toBe("text/plain;charset=UTF-8");
    expect(call!.body).toMatchObject({ key: KEY, sdkVersion: "0.2.0-web" });
    expect(call!.body.visitorId).toMatch(/^[0-9a-f-]{36}$/);
    expect(call!.body.items[0]).toMatchObject({
      type: "event",
      name: "page_view",
      path: "/products/red-shoe",
      referrer: "https://l.instagram.com/",
      utm: { source: "instagram" },
      clickId: CLICK,
    });

    // The same fields and types as the server's fixture.
    const sample = contract("web/request.json");
    expect(Object.keys(call!.body).sort()).toEqual(Object.keys(sample).sort());
    for (const [k, v] of Object.entries(call!.body.items[0]!)) {
      if (k in sample.items[0]) expect(typeof v).toBe(typeof sample.items[0][k]);
    }
  });

  it("keeps the first click (first touch), cleans the URL, and sets the cookies the brand's server reads", async () => {
    const dl = start({}, `/p?dropp_click_id=${CLICK}&size=9#reviews`);
    expect(location.pathname + location.search + location.hash).toBe("/p?size=9#reviews");
    expect(dl.getClickId()).toBe(CLICK);
    expect(cookie("dropp_click_id")).toBe(CLICK);
    expect(cookie("dropp_vid")).toBe(dl.getVisitorId());

    const later = start({}, "/p?dropp_click_id=c_ffffffffffffffff");
    expect(later.getClickId()).toBe(CLICK);
    await later.flush();
    // The later click still marks its own landing, and starts a session of its own.
    const [first, second] = items();
    expect(second).toMatchObject({ clickId: "c_ffffffffffffffff" });
    expect(second!.sessionId).not.toBe(first!.sessionId);
    // One visitor across both.
    expect(new Set(calls.map((c) => c.body.visitorId)).size).toBe(1);
  });

  it("one session within 30 minutes idle; a new one after, with its own landing fields", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-22T10:00:00Z"));
    setReferrer("https://www.google.com/");
    start({}, "/");
    vi.setSystemTime(new Date("2026-10-22T10:20:00Z"));
    start({}, "/about");
    vi.setSystemTime(new Date("2026-10-22T11:00:00Z"));
    const dl = start({}, "/contact");
    await dl.flush();

    const [a, b, c] = items();
    expect(b!.sessionId).toBe(a!.sessionId);
    expect(b).not.toHaveProperty("referrer");
    expect(c!.sessionId).not.toBe(a!.sessionId);
    expect(c).toMatchObject({ referrer: "https://www.google.com/" });
  });
});

describe("page views and engaged time", () => {
  it("page views on pushState and popstate, none for the same page; engaged time per page", async () => {
    vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"] });
    const dl = start({}, "/");
    vi.advanceTimersByTime(5_000);
    history.pushState({}, "", "/cart");
    vi.advanceTimersByTime(0);
    history.replaceState({}, "", "/cart");
    vi.advanceTimersByTime(0);
    history.pushState({}, "", "/cart#top");
    vi.advanceTimersByTime(3_000);
    setVisibility("hidden");
    vi.useRealTimers();
    await dl.flush();

    const sent = items().filter((i, n, all) => all.findIndex((j) => j.eventId === i.eventId) === n);
    expect(sent.map((i) => (i.type === "event" ? `${i.name} ${i.path}` : `${i.type} ${i.path} ${i.ms}`))).toEqual([
      "page_view /",
      "engage / 5000",
      "page_view /cart",
      "engage /cart 3000",
    ]);
  });

  it("on page hide: sends with keepalive, so the request outlives the page", async () => {
    start({}, "/");
    setVisibility("hidden");
    await vi.waitFor(() => expect(calls.length).toBeGreaterThan(0));
    expect(calls[0]!.keepalive).toBe(true);
  });
});

describe("track and identify", () => {
  it("drops bad names, cleans props, and never sends personal data", async () => {
    const dl = start({}, "/");
    dl.track("Add To Cart");
    dl.track("add_to_cart", {
      sku: "RS-9",
      price: 1499,
      gift: false,
      email: "riya@example.com",
      phone: "+91 98765 43210",
      nested: { a: 1 } as never,
      "bad key": 1,
      note: "x".repeat(300),
    });
    dl.identify("riya@example.com");
    dl.identify("user_8812");
    dl.identify("user_8812");
    dl.logout();
    await dl.flush();

    const sent = items().slice(1);
    expect(sent).toHaveLength(3);
    expect(sent[0]).toMatchObject({ name: "add_to_cart", props: { sku: "RS-9", price: 1499, gift: false, note: "x".repeat(256) } });
    expect(Object.keys(sent[0]!.props as object)).toEqual(["sku", "price", "gift", "note"]);
    expect(sent[1]).toMatchObject({ type: "identify", userId: "user_8812" });
    expect(sent[2]).toMatchObject({ type: "identify", userId: null });
  });
});

describe("sending", () => {
  it("keeps everything on 503 and retries after Retry-After; a reload sends what was left", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    respond = () => status(503, { "retry-after": "10" });
    const dl = start({}, "/");
    dl.track("add_to_cart");
    await dl.flush();
    expect(calls).toHaveLength(1);
    expect(queued()).toHaveLength(2);

    respond = () => ok();
    await vi.advanceTimersByTimeAsync(5_000);
    expect(calls).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(calls).toHaveLength(2);
    expect(queued()).toHaveLength(0);

    // Offline, then the visitor opens another page: the queue survives in localStorage.
    respond = () => "network-error";
    const page = start({}, "/a");
    await page.flush();
    expect(queued()).toHaveLength(1);
    respond = () => ok();
    const next = start({}, "/b");
    await next.flush();
    expect(calls.at(-1)!.body.items.map((i) => i.path)).toEqual(["/a", "/b"]);
    expect(queued()).toHaveLength(0);
  });

  it("drops a malformed batch (400), and stops on 403 (wrong key or website)", async () => {
    respond = () => status(400);
    const dl = start({}, "/");
    await dl.flush();
    expect(queued()).toHaveLength(0);

    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    respond = () => status(403);
    dl.track("add_to_cart");
    await dl.flush();
    dl.track("begin_checkout");
    await dl.flush();
    expect(calls).toHaveLength(2);
    expect(errors).toHaveBeenCalledOnce();
  });

  it("falls back to the API host when the link domain isn't routed", async () => {
    respond = (url) => (url === ENDPOINT ? status(404) : ok());
    const dl = start({}, "/");
    await dl.flush();
    expect(calls.map((c) => c.url)).toEqual([ENDPOINT, DEFAULT_ENDPOINT]);
    expect(queued()).toHaveLength(0);
  });
});

describe("consent and bots", () => {
  it("consent required: only the click id is kept until grant(); revoke() clears everything", async () => {
    const dl = start({ consent: "required" }, `/?dropp_click_id=${CLICK}`);
    dl.track("add_to_cart");
    await dl.flush();
    expect(calls).toHaveLength(0);
    expect(dl.getVisitorId()).toBeNull();
    expect(cookie("dropp_vid")).toBeNull();
    expect(cookie("dropp_click_id")).toBe(CLICK);
    expect(localStorage.getItem("dl_sess")).toBeNull();
    expect(localStorage.getItem("dl_q")).toBeNull();

    dl.grant();
    await dl.flush();
    expect(items().map((i) => i.name)).toEqual(["page_view", "add_to_cart"]);
    expect(cookie("dropp_vid")).toBe(dl.getVisitorId());

    dl.revoke();
    expect(cookie("dropp_vid")).toBeNull();
    expect(cookie("dropp_click_id")).toBeNull();
    expect(["dl_vid", "dl_sess", "dl_click", "dl_q"].map((k) => localStorage.getItem(k))).toEqual([null, null, null, null]);
    dl.track("add_to_cart");
    await dl.flush();
    expect(calls).toHaveLength(1);
  });

  it("does nothing in an automated browser, or without a valid key", async () => {
    Object.defineProperty(navigator, "webdriver", { value: true, configurable: true });
    const bot = start({}, "/");
    bot.track("add_to_cart");
    await bot.flush();
    Object.defineProperty(navigator, "webdriver", { value: false, configurable: true });

    vi.spyOn(console, "error").mockImplementation(() => {});
    const noKey = start({ key: "sk_live_wrong" }, "/");
    await noKey.flush();
    expect(calls).toHaveLength(0);
    expect(localStorage.length).toBe(0);
  });
});
