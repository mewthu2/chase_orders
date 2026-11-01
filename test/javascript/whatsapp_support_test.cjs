// Run with: node --test test/javascript/whatsapp_support_test.cjs
// The real inbox script runs against a small DOM/fetch adapter, without Rails,
// credentials, network access, customer records or third-party dependencies.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.resolve(__dirname, "../..");
const script = fs.readFileSync(path.join(root, "app/javascript/whatsapp_support.js"), "utf8");
const template = fs.readFileSync(path.join(root, "app/views/whatsapp/conversations/index.html.erb"), "utf8");
const flush = () => new Promise(setImmediate);
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
class Element {
  constructor(tag = "div") {
    this.tagName = tag;
    this.children = [];
    this.value = "";
    this.files = [];
    this.hidden = false;
    this.attributes = {};
    this.classList = { add() {}, remove() {} };
    this.scrollHeight = this.clientHeight = this.scrollTop = 0;
    this._text = "";
  }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map((child) => child.textContent).join(" "); }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this._text = ""; this.children = children; }
  add(child) { this.append(child); }
  setAttribute(name, value) { this.attributes[name] = value; }
  addEventListener() {}
  focus() {}
  querySelectorAll(tag) { return this.children.flatMap((child) => [...(child.tagName === tag ? [child] : []), ...child.querySelectorAll(tag)]); }
}
function response(data, status = 200) {
  return { ok: status >= 200 && status < 300, status, redirected: false,
    headers: { get: () => "application/json" }, json: async () => data };
}
function context(orderName = "#1001") {
  return { customer: { id: 10, name: "Cliente teste" }, orders: [{ id: orderName, name: orderName,
    total_price: "119.90", currency: "BRL", financial_status: "PAID", fulfillment_status: "UNFULFILLED",
    items: [{ title: "Produto teste", quantity: 1 }], tracking: [], shopify_url: "https://example.test/orders/1" }],
    page_info: { has_next_page: false, end_cursor: null }, fetched_at: "2026-10-31T12:00:00Z" };
}
async function inbox() {
  const elements = new Map([...template.matchAll(/id="([^"]+)"/g)].map((match) => [match[1], new Element()]));
  elements.get("wa-contact-panel").hidden = true;
  elements.get("wa-customer-picker").hidden = true;
  const workspace = new Element();
  const rows = [1, 2].map((id) => ({ id, name: `Cliente ${id}`, phone: `551199990000${id}`,
    customer: { id: id * 10, name: `Cadastro ${id}`, phone: "1199990000" },
    connection_name: "Atendimento", connection_state: "connected", state: "open", assignees: [],
    can_link_customer: true, can_view_customer_context: true,
    attendance_summary: { body: `Resumo ${id}`, version: 1, updated_at: null, author_name: null } }));
  const calls = [], timers = [], handlers = [];
  const fetch = async (url, options = {}) => {
    calls.push({ url, options });
    for (const handler of handlers) {
      const result = handler(url, options);
      if (result !== undefined) return result;
    }
    if (url.startsWith("/whatsapp/conversations.json")) return response({ connections: [], conversations: rows, more: false });
    if (/\/messages.json/.test(url)) return response({ messages: [], before: null, after_id: 0 });
    if (/\/read$/.test(url)) return response({});
    if (/\/customer_context/.test(url)) {
      const result = context();
      result.customer.id = Number(url.match(/conversations\/(\d+)/)[1]) * 10;
      return response(result);
    }
    if (/\/customers\?/.test(url)) return response({ customers: [] });
    const show = url.match(/conversations\/(\d+)\.json$/);
    if (show) return response(structuredClone(rows.find((row) => row.id === Number(show[1]))));
    throw new Error(`Unexpected request ${url}`);
  };
  vm.runInNewContext(script, { document: { getElementById: (id) => elements.get(id),
    createElement: (tag) => new Element(tag), querySelector: (selector) => selector === ".wa-workspace" ? workspace : { content: "test" }, hidden: false },
    window: { addEventListener() {}, confirm: () => true }, navigator: {}, fetch,
    URL, URLSearchParams, Intl, Date, console, setTimeout: (fn) => { timers.push(fn); }, clearTimeout() {},
    Option: class extends Element { constructor(text, value) { super("option"); this.textContent = text; this.value = value; } } });
  await flush();
  const get = (id) => elements.get(id);
  const click = async (id) => { await get(id).onclick(); await flush(); };
  const select = async (id) => { await get("wa-threads").children[id - 1].onclick(); await flush(); };
  const typeSummary = (text) => { get("wa-summary-body").value = text; get("wa-summary-body").oninput(); };
  return { get, click, select, typeSummary, rows, calls, handlers,
    poll: async () => { await timers.shift()(); await flush(); } };
}

test("polling and switching conversations preserve private drafts without querying Shopify every poll", async () => {
  const app = await inbox();
  await app.select(1);
  await app.click("wa-contact-toggle");
  app.typeSummary("Meu rascunho interno");
  const count = app.calls.filter((call) => call.url.includes("customer_context")).length;
  await app.poll();
  assert.equal(app.get("wa-summary-body").value, "Meu rascunho interno");
  assert.equal(app.calls.filter((call) => call.url.includes("customer_context")).length, count);
  await app.select(2);
  assert.equal(app.get("wa-summary-body").value, "Resumo 2");
  await app.select(1);
  assert.equal(app.get("wa-summary-body").value, "Meu rascunho interno");
  assert.match(app.get("wa-summary-status").textContent, /não salvas/);
});

test("a stale Shopify response cannot show another conversation's orders", async () => {
  const app = await inbox(), old = deferred();
  app.handlers.push((url) => url.includes("/1/customer_context") ? old.promise : undefined);
  await app.select(1);
  const opening = app.click("wa-contact-toggle");
  await app.select(2);
  assert.match(app.get("wa-orders").textContent, /#1001/);
  old.resolve(response(context("#ERRADO")));
  await opening;
  assert.doesNotMatch(app.get("wa-orders").textContent, /ERRADO/);
});

test("out-of-order customer searches and links do not replace the active conversation", async () => {
  const app = await inbox(), oldSearch = deferred(), oldLink = deferred();
  app.handlers.push((url) => url.includes("/customers?q=antigo") ? oldSearch.promise :
    url.includes("/customers?q=novo") ? response({ customers: [{ id: 30, name: "Cadastro novo", email: "teste@example.test" }] }) :
    url.includes("/1/link_customer") ? oldLink.promise : undefined);
  await app.select(1);
  app.get("wa-customer-search").value = "antigo";
  const first = app.click("wa-customer-find");
  app.get("wa-customer-search").value = "novo";
  await app.click("wa-customer-find");
  oldSearch.resolve(response({ customers: [{ id: 40, name: "Cadastro antigo" }] }));
  await first;
  assert.match(app.get("wa-customer-results").textContent, /Cadastro novo/);
  assert.doesNotMatch(app.get("wa-customer-results").textContent, /Cadastro antigo/);
  const linking = app.get("wa-customer-results").children[0].onclick();
  await app.select(2);
  oldLink.resolve(response({ ...app.rows[0], customer: { id: 30, name: "Cadastro novo" } }));
  await linking;
  assert.equal(app.get("wa-contact-name").textContent, "Cliente 2");
});

test("a 409 preserves the draft and requires reviewing the latest version before saving again", async () => {
  const app = await inbox();
  let saves = 0;
  app.handlers.push((url, options) => {
    if (!url.endsWith("/attendance_summary")) return;
    saves++;
    const body = JSON.parse(options.body);
    if (saves === 1) return response({ error: "Conflito", attendance_summary: { body: "Outro atendente", version: 2, author_name: "Equipe" } }, 409);
    assert.equal(body.version, 2);
    return response({ attendance_summary: { body: body.body, version: 3, author_name: "Operador" } });
  });
  await app.select(1);
  app.typeSummary("Meu texto");
  await app.click("wa-summary-save");
  assert.equal(app.get("wa-summary-body").value, "Meu texto");
  assert.equal(app.get("wa-summary-save").disabled, true);
  assert.equal(app.get("wa-summary-conflict").hidden, false);
  assert.equal(app.get("wa-summary-latest").textContent, "Outro atendente");
  await app.click("wa-summary-keep-draft");
  assert.equal(app.get("wa-summary-save").disabled, false);
  await app.click("wa-summary-save");
  assert.equal(app.get("wa-summary-status").textContent, "Resumo salvo.");
  assert.equal(saves, 2);
});

test("edits during an in-flight save survive its response and a conversation switch", async () => {
  const app = await inbox(), saving = deferred();
  app.handlers.push((url) => url.includes("/attendance_summary") ? saving.promise : undefined);
  await app.select(1);
  app.typeSummary("Texto enviado");
  const pending = app.click("wa-summary-save");
  app.typeSummary("Texto editado durante o envio");
  await app.select(2);
  saving.resolve(response({ attendance_summary: { body: "Texto enviado", version: 2 } }));
  await pending;
  assert.equal(app.get("wa-summary-body").value, "Resumo 2");
  await app.select(1);
  assert.equal(app.get("wa-summary-body").value, "Texto editado durante o envio");
  assert.equal(app.get("wa-summary-save").disabled, false);
});

test("polling detects another operator's edit without overwriting the local draft", async () => {
  const app = await inbox();
  await app.select(1);
  app.typeSummary("Rascunho local");
  app.rows[0].attendance_summary = { body: "Atualizado pela equipe", version: 2 };
  await app.poll();
  assert.equal(app.get("wa-summary-body").value, "Rascunho local");
  assert.equal(app.get("wa-summary-conflict").hidden, false);
  await app.click("wa-summary-load-latest");
  assert.equal(app.get("wa-summary-body").value, "Atualizado pela equipe");
  assert.equal(app.get("wa-summary-save").disabled, true);
});

test("order pagination keeps existing orders and rejects non-HTTP links", async () => {
  const app = await inbox();
  app.handlers.push((url) => {
    if (!url.includes("/customer_context")) return;
    const result = context(url.includes("after=") ? "#1002" : "#1001");
    result.page_info = { has_next_page: !url.includes("after="), end_cursor: "next+page" };
    result.orders[0].shopify_url = "javascript:alert(1)";
    result.orders[0].tracking = [{ number: "TESTE", url: "data:text/html,unsafe" }];
    return response(result);
  });
  await app.select(1);
  await app.click("wa-contact-toggle");
  assert.equal(app.get("wa-orders-more").hidden, false);
  await app.click("wa-orders-more");
  assert.match(app.get("wa-orders").textContent, /#1001/);
  assert.match(app.get("wa-orders").textContent, /#1002/);
  assert.equal(app.get("wa-orders").querySelectorAll("a").length, 0);
  assert.equal(app.get("wa-orders-more").hidden, true);
  assert.ok(app.calls.some((call) => call.url.endsWith("?after=next%2Bpage")));
});

test("revoking order permission removes cached orders and invalidates an in-flight refresh", async () => {
  const app = await inbox(), pending = deferred();
  await app.select(1);
  await app.click("wa-contact-toggle");
  assert.match(app.get("wa-orders").textContent, /#1001/);
  app.handlers.push((url) => url.includes("/customer_context") ? pending.promise : undefined);
  const refresh = app.click("wa-orders-refresh");
  app.rows[0].can_view_customer_context = false;
  await app.poll();
  assert.equal(app.get("wa-orders").textContent, "");
  assert.equal(app.get("wa-orders-updated").textContent, "");
  assert.equal(app.get("wa-orders-more").hidden, true);
  assert.equal(app.get("wa-orders-refresh").disabled, true);
  assert.match(app.get("wa-orders-status").textContent, /não permite/);
  pending.resolve(response(context("#NAO-AUTORIZADO")));
  await refresh;
  assert.equal(app.get("wa-orders").textContent, "");
});

test("a customer relink during Shopify loading clears orders, refreshes the header and asks for a fresh query", async () => {
  const app = await inbox();
  await app.select(1);
  await app.click("wa-contact-toggle");
  assert.match(app.get("wa-orders").textContent, /#1001/);
  app.rows[0].customer = { id: 30, name: "Cadastro alterado pela equipe" };
  app.handlers.push((url) => {
    if (!url.includes("/customer_context")) return;
    const result = context("#NOVO-CLIENTE");
    result.customer = app.rows[0].customer;
    return response(result);
  });
  const callsBefore = app.calls.length;
  await app.click("wa-orders-refresh");
  assert.equal(app.get("wa-orders").textContent, "");
  assert.match(app.get("wa-linked").textContent, /Cadastro alterado pela equipe/);
  assert.match(app.get("wa-orders-status").textContent, /vínculo.*mudou/);
  assert.equal(app.get("wa-orders-more").hidden, true);
  assert.equal(app.calls.slice(callsBefore).filter((call) => call.url.includes("/customer_context")).length, 1);
  await app.click("wa-orders-refresh");
  assert.match(app.get("wa-orders").textContent, /#NOVO-CLIENTE/);
});

test("details fetched to reconcile a changed customer cannot overwrite another conversation", async () => {
  const app = await inbox(), details = deferred();
  await app.select(1);
  app.handlers.push((url) => {
    if (url.includes("/1/customer_context")) {
      const result = context("#OUTRO-CLIENTE");
      result.customer.id = 30;
      return response(result);
    }
    if (url === "/whatsapp/conversations/1.json") return details.promise;
  });
  const loading = app.click("wa-contact-toggle");
  await flush();
  await app.select(2);
  details.resolve(response({ ...app.rows[0], customer: { id: 30, name: "Outro cadastro" } }));
  await loading;
  assert.equal(app.get("wa-contact-name").textContent, "Cliente 2");
  assert.match(app.get("wa-linked").textContent, /Cadastro 2/);
  assert.doesNotMatch(app.get("wa-orders").textContent, /OUTRO-CLIENTE/);
});
