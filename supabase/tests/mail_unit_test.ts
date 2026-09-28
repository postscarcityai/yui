// yui-mail's pure pieces, offline: deno test supabase/tests/mail_unit_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  baseSubject, derToRaw, firstJson, htmlToText, messageIds, newPart, noAnswerReason, parseAddress, parseAddressList,
  parseHeaders, promoFooter, replySubject, senderAddress, template, textToHtml, verifyEventSignature,
} from "../functions/yui-mail/mail.ts";

Deno.test("addresses", () => {
  assertEquals(parseAddress('"Doe, Jane" <Jane@Example.com>'), { email: "jane@example.com", name: "Doe, Jane" });
  assertEquals(parseAddress("bob@x.io"), { email: "bob@x.io", name: null });
  assertEquals(parseAddress("not an address"), null);
  assertEquals(parseAddressList('"Doe, Jane" <jane@example.com>, yui@yuigui.com, junk'), ["jane@example.com", "yui@yuigui.com"]);
});

Deno.test("headers and ids", () => {
  const h = parseHeaders("Message-ID: <a1@mail.x>\r\nReferences: <r1@x>\r\n <r2@x>\r\nSubject: Hi\r\nReceived: one\r\nReceived: two\r\n");
  assertEquals(h["message-id"], "<a1@mail.x>");
  assertEquals(messageIds(h["references"]), ["r1@x", "r2@x"]);
  assertEquals(h["received"], "one");
});

Deno.test("subjects", () => {
  assertEquals(baseSubject("Re: Fwd: RE: Hello there"), "hello there");
  assertEquals(baseSubject("AW: [2] Re:  Hi"), "hi");
  assertEquals(replySubject("Re: Hi"), "Re: Hi");
  assertEquals(replySubject("Hi"), "Re: Hi");
  assertEquals(replySubject(""), "Re: Your email");
});

Deno.test("Yui never answers machines, lists or herself", () => {
  assertEquals(noAnswerReason("jane@example.com", {}, 0.1), null);
  assert(noAnswerReason("yui@yuigui.com", {}, 0));
  assert(noAnswerReason("no-reply@shop.com", {}, 0));
  assert(noAnswerReason("MAILER-DAEMON@x.com", {}, 0));
  assert(noAnswerReason("jane@example.com", { "auto-submitted": "auto-replied" }, 0));
  assertEquals(noAnswerReason("jane@example.com", { "auto-submitted": "no" }, 0), null);
  assert(noAnswerReason("news@brand.com", { "list-unsubscribe": "<mailto:x>" }, 0));
  assert(noAnswerReason("jane@example.com", { precedence: "bulk" }, 0));
  assertEquals(noAnswerReason("jane@example.com", {}, 7.2), "spam");
});

Deno.test("sender is always at yuigui.com", () => {
  assertEquals(senderAddress(undefined), "yui@yuigui.com");
  assertEquals(senderAddress("Hello"), "hello@yuigui.com");
  assertEquals(senderAddress("evil@other.com"), "yui@yuigui.com");
});

Deno.test("text to html escapes and links", () => {
  const h = textToHtml("Hi <b>\n\nGo to https://www.yuigui.com/start.");
  assert(h.includes("&lt;b&gt;"));
  assert(h.includes('<a href="https://www.yuigui.com/start">https://www.yuigui.com/start</a>.'));
});

Deno.test("templates need their link", () => {
  assertEquals(template("confirm", {}), null);
  const t = template("invite_request", { first_name: "Ana", link: "https://www.yuigui.com/confirm?t=abc" })!;
  assert(t.text.startsWith("Hi Ana,"));
  assert(t.text.includes("https://www.yuigui.com/confirm?t=abc"));
  assert(!/—/.test(Object.values(t).join(" ")), "no em dashes");
  assertEquals(template("nope", {}), null);
});

Deno.test("promo footer carries the address and the way out", () => {
  const f = promoFooter("https://www.yuigui.com/unsubscribe?t=x", "PO Box 1, Town");
  assert(f.text.includes("PO Box 1, Town") && f.text.includes("unsubscribe?t=x"));
});

Deno.test("model answers: first JSON object", () => {
  assertEquals(firstJson('Sure!\n```json\n{"action":"reply","reply":"Hi {there}"}\n```'), { action: "reply", reply: "Hi {there}" });
  assertEquals(firstJson("no json"), null);
});

Deno.test("only the new part of a reply", () => {
  const t = "Thanks!\n\nOn Mon, Sep 28, 2026 at 9:00 AM Yui <yui@yuigui.com> wrote:\n> Hi\n> there";
  assertEquals(newPart(t), "Thanks!");
  assertEquals(htmlToText("<p>Hi</p><p><a href=\"https://x.io\">x</a></p><style>p{}</style>"), "Hi\nx (https://x.io)");
});

function rawToDer(raw: Uint8Array): Uint8Array {
  const int = (b: Uint8Array) => {
    let v = Array.from(b);
    while (v.length > 1 && v[0] === 0) v = v.slice(1);
    if (v[0] & 0x80) v = [0, ...v];
    return [0x02, v.length, ...v];
  };
  const body = [...int(raw.slice(0, 32)), ...int(raw.slice(32))];
  return new Uint8Array([0x30, body.length, ...body]);
}

Deno.test("SendGrid event signatures verify, and a changed body does not", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey));
  const pub = btoa(String.fromCharCode(...spki));
  const ts = "1790000000", body = '[{"event":"delivered"}]';
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(ts + body)));
  assertEquals(derToRaw(rawToDer(raw)), raw);
  const sig = btoa(String.fromCharCode(...rawToDer(raw)));
  assert(await verifyEventSignature(pub, sig, ts, body));
  assert(!(await verifyEventSignature(pub, sig, ts, body + " ")));
  assert(!(await verifyEventSignature("", sig, ts, body)));
});
