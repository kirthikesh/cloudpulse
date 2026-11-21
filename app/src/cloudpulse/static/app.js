// CloudPulse dashboard — vanilla JS, no dependencies.
const REFRESH_MS = 10000;
const BAR_COUNT = 30;
let selectedId = null;

const $ = (sel) => document.querySelector(sel);

async function api(path, options = {}) {
  const res = await fetch(path, { headers: { "Content-Type": "application/json" }, ...options });
  if (!res.ok) {
    let msg = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      msg = Array.isArray(body.detail) ? body.detail.map((d) => d.msg).join(", ") : body.detail || msg;
    } catch (_) { /* not JSON */ }
    throw new Error(msg);
  }
  return res.status === 204 ? null : res.json();
}

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
    else node.setAttribute(k, v);
  }
  for (const c of children) node.append(c instanceof Node ? c : document.createTextNode(c ?? ""));
  return node;
}

function timeAgo(iso) {
  if (!iso) return "never";
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  return `${Math.round(s / 3600)}h ago`;
}

function formatUptime(sec) {
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m ${sec % 60}s`;
}

// ---------- summary ----------
async function loadSummary() {
  const s = await api("/api/summary");
  $("#s-total").textContent = s.total;
  $("#s-up").textContent = s.up;
  $("#s-down").textContent = s.down;
  $("#s-uptime").textContent = s.uptime_pct == null ? "–" : `${s.uptime_pct}%`;
  $("#s-latency").textContent = s.avg_latency_ms == null ? "–" : `${Math.round(s.avg_latency_ms)}ms`;
}

// ---------- monitor cards ----------
function renderBars(checks) {
  const bars = el("div", { class: "bars" });
  const recent = checks.slice(0, BAR_COUNT).reverse(); // oldest -> newest
  for (let i = 0; i < BAR_COUNT - recent.length; i++) bars.append(el("div", { class: "bar" }));
  for (const c of recent) {
    bars.append(el("div", {
      class: `bar ${c.up ? "up" : "down"}`,
      title: `${new Date(c.checked_at).toLocaleTimeString()} · ${c.status_code || c.error || "error"} · ${c.latency_ms}ms`,
    }));
  }
  return bars;
}

function renderCard(m, checks) {
  const del = el("button", {
    class: "del", title: "Delete monitor",
    onclick: async (e) => {
      e.stopPropagation();
      if (!confirm(`Stop monitoring ${m.name}?`)) return;
      await api(`/api/monitors/${m.id}`, { method: "DELETE" });
      if (selectedId === m.id) closeDetail();
      refresh();
    },
  }, "×");

  return el("div", {
    class: `card ${selectedId === m.id ? "selected" : ""}`,
    onclick: () => openDetail(m),
  },
    el("div", { class: "card-head" },
      el("span", { class: `dot ${m.status}` }),
      el("span", { class: "name" }, m.name),
      del),
    el("div", { class: "url" }, m.url),
    el("div", { class: "meta" },
      el("span", {}, "latency ", el("b", {}, m.last_latency_ms != null ? `${Math.round(m.last_latency_ms)}ms` : "–")),
      el("span", {}, "code ", el("b", {}, m.last_status_code ? String(m.last_status_code) : "–")),
      el("span", {}, "checked ", el("b", {}, timeAgo(m.last_checked_at)))),
    renderBars(checks));
}

async function loadMonitors() {
  const monitors = await api("/api/monitors");
  const checksList = await Promise.all(
    monitors.map((m) => api(`/api/monitors/${m.id}/checks?limit=${BAR_COUNT}`).catch(() => []))
  );
  const grid = $("#monitors");
  grid.replaceChildren(...monitors.map((m, i) => renderCard(m, checksList[i])));
  $("#empty").hidden = monitors.length > 0;
  if (selectedId) {
    const m = monitors.find((x) => x.id === selectedId);
    m ? drawDetail(m) : closeDetail();
  }
}

// ---------- latency chart (hand-drawn on canvas) ----------
function openDetail(m) {
  selectedId = m.id;
  loadMonitors(); // re-renders cards (highlight) and redraws the chart
}

function closeDetail() {
  selectedId = null;
  $("#detail").hidden = true;
  document.querySelectorAll(".card").forEach((c) => c.classList.remove("selected"));
}

async function drawDetail(m) {
  $("#detail").hidden = false;
  $("#d-title").textContent = `${m.name} — ${m.url}`;
  const checks = (await api(`/api/monitors/${m.id}/checks?limit=50`)).reverse();
  drawChart($("#chart"), checks);
}

function drawChart(canvas, checks) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = 220;
  canvas.width = w * dpr; canvas.height = h * dpr;
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, w, h);

  const css = getComputedStyle(document.documentElement);
  const color = (v) => css.getPropertyValue(v).trim();
  ctx.font = "11px ui-monospace, Menlo, monospace";

  if (!checks.length) {
    ctx.fillStyle = color("--muted");
    ctx.fillText("No checks yet — the worker runs every minute.", 12, h / 2);
    return;
  }

  const pad = { l: 48, r: 12, t: 10, b: 24 };
  const max = Math.max(...checks.map((c) => c.latency_ms), 10) * 1.15;
  const x = (i) => pad.l + (checks.length === 1 ? 0 : (i / (checks.length - 1)) * (w - pad.l - pad.r));
  const y = (v) => pad.t + (1 - v / max) * (h - pad.t - pad.b);

  // grid + y labels
  ctx.strokeStyle = color("--line"); ctx.fillStyle = color("--muted"); ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const v = (max / 4) * i, yy = y(v);
    ctx.beginPath(); ctx.moveTo(pad.l, yy); ctx.lineTo(w - pad.r, yy); ctx.stroke();
    ctx.fillText(`${Math.round(v)}`, 8, yy + 4);
  }
  // x labels: first and last timestamp
  const t = (c) => new Date(c.checked_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  ctx.fillText(t(checks[0]), pad.l, h - 6);
  const last = t(checks[checks.length - 1]);
  ctx.fillText(last, w - pad.r - ctx.measureText(last).width, h - 6);

  // line
  ctx.strokeStyle = color("--text"); ctx.lineWidth = 1.5;
  ctx.beginPath();
  checks.forEach((c, i) => (i ? ctx.lineTo(x(i), y(c.latency_ms)) : ctx.moveTo(x(i), y(c.latency_ms))));
  ctx.stroke();

  // points
  checks.forEach((c, i) => {
    ctx.fillStyle = c.up ? color("--up") : color("--down");
    ctx.beginPath(); ctx.arc(x(i), y(c.latency_ms), c.up ? 2.5 : 4, 0, Math.PI * 2); ctx.fill();
  });
}

// ---------- ops tab ----------
async function loadInfo() {
  const info = await api("/api/info");
  const badge = $("#env-badge");
  badge.textContent = info.env;
  badge.className = `badge ${info.env}`;
  document.title = `CloudPulse · ${info.env}`;
  const rows = [
    ["Environment", info.env], ["Version", info.version], ["Image tag", info.image_tag],
    ["Build ID", info.build_id], ["Git commit", info.git_sha.slice(0, 12)],
    ["Pod", info.pod], ["Node", info.node], ["Pod uptime", formatUptime(info.uptime_seconds)],
  ];
  $("#ops").replaceChildren(...rows.map(([k, v]) =>
    el("div", { class: "stat" }, el("span", { class: "label" }, k), el("span", { class: "value" }, String(v)))));
}

// ---------- wiring ----------
$("#add-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#form-error");
  err.hidden = true;
  try {
    await api("/api/monitors", {
      method: "POST",
      body: JSON.stringify({ name: $("#f-name").value.trim(), url: $("#f-url").value.trim() }),
    });
    e.target.reset();
    refresh();
  } catch (ex) {
    err.textContent = ex.message;
    err.hidden = false;
  }
});

$("#d-close").addEventListener("click", closeDetail);

document.querySelectorAll(".tab").forEach((btn) => btn.addEventListener("click", () => {
  document.querySelectorAll(".tab").forEach((b) => b.classList.toggle("active", b === btn));
  document.querySelectorAll(".tab-panel").forEach((p) => (p.hidden = p.id !== `tab-${btn.dataset.tab}`));
}));

window.addEventListener("resize", () => {
  if (selectedId) loadMonitors();
});

async function refresh() {
  try {
    await Promise.all([loadSummary(), loadMonitors(), loadInfo()]);
    $("#last-refresh").textContent = `updated ${new Date().toLocaleTimeString()}`;
  } catch (e) {
    $("#last-refresh").textContent = `refresh failed: ${e.message}`;
  }
}

refresh();
setInterval(refresh, REFRESH_MS);
