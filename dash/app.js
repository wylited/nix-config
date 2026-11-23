// dash — clock, weather, the next two weeks, open todos, service health.
//
// Calendar and tasks both come from radicale; clicks deep-link into calino
// (cal.ts.wyli.tech). Calino routes by view, not by event or day, so a click
// lands on that view's page.
//
// Calendar data comes from radicale through this vhost's /caldav/* proxy, so
// the page stays same-origin. Radicale runs passwordless (auth.type = none —
// the tailnet is the boundary) but still wants an Authorization header, hence
// the dummy Basic below.
//
// ICS handling: radicale returns whole VCALENDARs, each holding a master VEVENT
// plus RECURRENCE-ID overrides for moved/skipped instances. Overrides are
// keyed by their recurrence-id and replace the generated occurrence; without
// that, every override re-expands its own series and the list doubles.

const CALENDARS = [
  { path: "lectures", label: "lectures", color: "#39bae6" },
  { path: "meetings", label: "meetings", color: "#86b300" },
  { path: "exams", label: "exams", color: "#d95757" },
  { path: "work", label: "work", color: "#4cc2b4" },
  { path: "events", label: "events", color: "#a37acc" },
  { path: "competitions", label: "competitions", color: "#fa8d3e" },
  { path: "birthdays", label: "birthdays", color: "#d597c0" },
  { path: "tasks", label: "tasks", color: "#8a9199" },
];

const HORIZON_DAYS = 14;
const MAX_EVENTS = 10;
const MAX_TASKS = 7;
const CAL_DAY = () => "https://cal.ts.wyli.tech/day";
const CAL_AGENDA = "https://cal.ts.wyli.tech/agenda";
const USER = "wyli";
const DAY = 86400000;
const DOW = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

const $time = document.getElementById("time");
const $date = document.getElementById("date");
const $events = document.getElementById("events");
const $horizon = document.getElementById("horizon");
const $tasks = document.getElementById("tasks");
const $todoMeta = document.getElementById("todo-meta");
const $eventsExpand = document.getElementById("events-expand");
const $tasksExpand = document.getElementById("tasks-expand");
const $weather = document.getElementById("weather");

const state = { events: [], todos: [], eventsOpen: false, todosOpen: false };

/* ---------- clock ---------- */

function tick() {
  const now = new Date();
  $time.textContent = now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
  $date.textContent = now.toLocaleDateString([], { weekday: "long", day: "numeric", month: "long" });
}

/* ---------- ical ---------- */

function unfold(text) {
  return text.replace(/\r?\n[ \t]/g, "").split(/\r?\n/);
}

function unescapeText(v) {
  return v.replace(/\\n/gi, "\n").replace(/\\,/g, ",").replace(/\\;/g, ";").replace(/\\\\/g, "\\");
}

function prop(line) {
  const colon = line.indexOf(":");
  if (colon < 0) return null;
  const left = line.slice(0, colon);
  const [name, ...params] = left.split(";");
  const p = {};
  for (const item of params) {
    const [k, v] = item.split("=");
    p[k.toUpperCase()] = v;
  }
  return { name: name.toUpperCase(), params: p, value: line.slice(colon + 1) };
}

// "20261118T090000" (wall time; TZID is taken as the reader's local zone) or
// "20261118" (all-day), optionally with a trailing Z for UTC.
function parseDate(value) {
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(value || "");
  if (!m) return null;
  const [, y, mo, d, h = "0", mi = "0", s = "0", utc] = m;
  const allDay = !/T/.test(value);
  const ms = utc
    ? Date.UTC(+y, +mo - 1, +d, +h, +mi, +s)
    : new Date(+y, +mo - 1, +d, +h, +mi, +s).getTime();
  return { ms, allDay };
}

function parseRrule(value) {
  const out = {};
  for (const part of value.split(";")) {
    const [k, v] = part.split("=");
    out[k.toUpperCase()] = v;
  }
  return out;
}

function parseIcs(text, calendar) {
  const out = [];
  let cur = null;
  for (const line of unfold(text)) {
    if (line === "BEGIN:VEVENT") {
      cur = { calendar, uid: "", status: "CONFIRMED" };
      continue;
    }
    if (line === "END:VEVENT") {
      if (cur && cur.start) {
        cur.startMs = cur.start.ms;
        const end = cur.end ? cur.end.ms : cur.duration ? cur.startMs + cur.duration : cur.startMs + (cur.allDay ? DAY : 3600000);
        cur.endMs = Math.max(end, cur.startMs + 60000);
        out.push(cur);
      }
      cur = null;
      continue;
    }
    if (!cur) continue;
    const p = prop(line);
    if (!p) continue;
    switch (p.name) {
      case "UID":
        cur.uid = p.value;
        break;
      case "DTSTART":
        cur.start = parseDate(p.value);
        cur.allDay = cur.start ? cur.start.allDay : false;
        break;
      case "DTEND":
        cur.end = parseDate(p.value);
        break;
      case "DURATION": {
        const d = /^(?:P(?:(\d+)D)?)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$/.exec(p.value);
        if (d) cur.duration = ((+d[1] || 0) * 24 * 60 + (+d[2] || 0) * 60 + (+d[3] || 0)) * 60000;
        break;
      }
      case "SUMMARY":
        cur.summary = unescapeText(p.value);
        break;
      case "LOCATION":
        cur.location = unescapeText(p.value);
        break;
      case "RRULE":
        cur.rrule = parseRrule(p.value);
        break;
      case "RECURRENCE-ID": {
        const r = parseDate(p.value);
        if (r) cur.recurrenceId = r.ms;
        break;
      }
      case "EXDATE": {
        const r = parseDate(p.value.split(",")[0]);
        if (r) (cur.exdates ||= new Set()).add(r.ms);
        break;
      }
      case "COLOR":
        if (/^#[0-9a-f]{6}$/i.test(p.value)) cur.color = p.value;
        break;
      case "STATUS":
        cur.status = p.value;
        break;
    }
  }
  return out;
}

function startOfWeek(d) {
  const c = new Date(d);
  c.setHours(0, 0, 0, 0);
  c.setDate(c.getDate() - ((c.getDay() + 6) % 7)); // Monday = 0
  return c.getTime();
}

// Occurrences of one VEVENT inside [from, to]: DAILY/WEEKLY/MONTHLY/YEARLY with
// INTERVAL, COUNT, UNTIL, BYDAY and EXDATE. Unknown rules yield nothing, which
// beats inventing dates.
function occurrences(ev, from, to) {
  const r = ev.rrule;
  if (!r) return ev.startMs >= from && ev.startMs <= to ? [ev.startMs] : [];
  const interval = r.INTERVAL ? +r.INTERVAL : 1;
  const count = r.COUNT ? +r.COUNT : Infinity;
  const until = r.UNTIL ? (parseDate(r.UNTIL)?.ms ?? Infinity) : Infinity;
  const byday = r.BYDAY
    ? r.BYDAY.split(",")
        .map((d) => DOW[d.slice(-2)])
        .filter((d) => d !== undefined)
    : null;
  const exdates = ev.exdates || new Set();
  const start = new Date(ev.startMs);
  const out = [];
  let n = 0;

  if (!byday) {
    const cur = new Date(start);
    while (n < count && n < 400 && cur.getTime() <= until && cur.getTime() <= to) {
      if (cur.getTime() >= from && !exdates.has(cur.getTime())) out.push(cur.getTime());
      n++;
      if (r.FREQ === "DAILY") cur.setDate(cur.getDate() + interval);
      else if (r.FREQ === "WEEKLY") cur.setDate(cur.getDate() + 7 * interval);
      else if (r.FREQ === "MONTHLY") cur.setMonth(cur.getMonth() + interval);
      else if (r.FREQ === "YEARLY") cur.setFullYear(cur.getFullYear() + interval);
      else break;
    }
    return out;
  }

  const wkst = startOfWeek(start);
  const cur = new Date(start);
  while (n < count && n < 400 && cur.getTime() <= until && cur.getTime() <= to + DAY) {
    const week = Math.round((startOfWeek(cur) - wkst) / (7 * DAY));
    const sameClock = cur.getHours() === start.getHours() && cur.getMinutes() === start.getMinutes();
    if (byday.includes(cur.getDay()) && week % interval === 0 && sameClock) {
      if (cur.getTime() >= from && !exdates.has(cur.getTime())) out.push(cur.getTime());
      n++;
    }
    cur.setDate(cur.getDate() + 1);
  }
  return out;
}

/* ---------- fetch ---------- */

function fmtUtc(ms) {
  return new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

function reportBody(from, to) {
  return `<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop><D:getetag/><C:calendar-data/></D:prop>
  <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
    <C:time-range start="${fmtUtc(from)}" end="${fmtUtc(to)}"/>
  </C:comp-filter></C:comp-filter></C:filter>
</C:calendar-query>`;
}

async function loadCalendar(cal, from, to) {
  const res = await fetch(`/caldav/${USER}/${cal.path}/`, {
    method: "REPORT",
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
      Depth: "1",
      Authorization: "Basic " + btoa(`${USER}:dash`),
    },
    body: reportBody(from, to),
  });
  if (res.status !== 207 && !res.ok) throw new Error(`${cal.path}: ${res.status}`);
  const xml = new DOMParser().parseFromString(await res.text(), "application/xml");
  return [...xml.getElementsByTagNameNS("urn:ietf:params:xml:ns:caldav", "calendar-data")].flatMap(
    (node) => parseIcs(node.textContent, cal),
  );
}

/* ---------- expand ---------- */

function rowsFor(events, from, to) {
  const byUid = new Map();
  for (const ev of events) {
    const key = ev.uid || `${ev.summary}@${ev.startMs}`;
    const group = byUid.get(key) || { master: null, overrides: new Map() };
    if (ev.recurrenceId !== undefined) group.overrides.set(ev.recurrenceId, ev);
    else group.master = ev;
    byUid.set(key, group);
  }

  const rows = [];
  const push = (ev, startMs) => {
    if (!ev || ev.status === "CANCELLED") return;
    rows.push({ ...ev, startMs, endMs: startMs + (ev.endMs - ev.startMs) });
  };

  for (const group of byUid.values()) {
    if (!group.master) {
      for (const ov of group.overrides.values()) push(ov, ov.startMs);
      continue;
    }
    const seen = new Set();
    for (const ms of occurrences(group.master, from, to)) {
      const ov = group.overrides.get(ms);
      push(ov || group.master, ov ? ov.startMs : ms);
      seen.add(ms);
    }
    // Overrides whose original slot fell outside the generated window.
    for (const [ms, ov] of group.overrides) if (!seen.has(ms)) push(ov, ov.startMs);
  }
  // Keep what has not finished yet (`endMs > from`) so an in-progress event
  // stays visible, and nothing from earlier today does.
  return rows.filter((r) => r.endMs > from && r.startMs <= to);
}

/* ---------- todos ---------- */

// VTODOs, not VEVENTs: passed/overdue ones would otherwise drown the list, and
// radicale answers the same REPORT shape with a different comp-filter.
function parseTodos(text) {
  const out = [];
  let cur = null;
  for (const line of unfold(text)) {
    if (line === "BEGIN:VTODO") {
      cur = { status: "NEEDS-ACTION" };
      continue;
    }
    if (line === "END:VTODO") {
      if (cur && cur.summary) out.push(cur);
      cur = null;
      continue;
    }
    if (!cur) continue;
    const p = prop(line);
    if (!p) continue;
    switch (p.name) {
      case "UID":
        cur.uid = p.value;
        break;
      case "SUMMARY":
        cur.summary = unescapeText(p.value);
        break;
      case "DUE": {
        const d = parseDate(p.value);
        if (d) cur.due = d.ms;
        break;
      }
      case "PRIORITY":
        cur.priority = +p.value || 0;
        break;
      case "STATUS":
        cur.status = p.value.toUpperCase();
        break;
      case "PERCENT-COMPLETE":
        if (+p.value >= 100) cur.done = true;
        break;
      case "CATEGORIES":
        cur.categories = p.value.split(",").map((c) => c.trim()).filter(Boolean);
        break;
    }
  }
  return out.filter(
    (t) => !t.done && t.status !== "COMPLETED" && t.status !== "CANCELLED",
  );
}

async function loadTodos() {
  const body = `<?xml version="1.0" encoding="utf-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop><D:getetag/><C:calendar-data/></D:prop>
  <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO"/></C:comp-filter></C:filter>
</C:calendar-query>`;
  const res = await fetch(`/caldav/${USER}/tasks/`, {
    method: "REPORT",
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
      Depth: "1",
      Authorization: "Basic " + btoa(`${USER}:dash`),
    },
    body,
  });
  if (res.status !== 207 && !res.ok) throw new Error(`tasks: ${res.status}`);
  const xml = new DOMParser().parseFromString(await res.text(), "application/xml");
  return [...xml.getElementsByTagNameNS("urn:ietf:params:xml:ns:caldav", "calendar-data")].flatMap(
    (node) => parseTodos(node.textContent),
  );
}

/* ---------- render ---------- */

function dayLabel(ms) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const start = new Date(ms);
  start.setHours(0, 0, 0, 0);
  const diff = Math.round((start - today) / DAY);
  if (diff === 0) return "today";
  if (diff === 1) return "tomorrow";
  return start.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });
}

function timeLabel(ms, allDay) {
  if (allDay) return "all day";
  return new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
}

function rowLink(href, tooltip, ...cells) {
  const a = document.createElement("a");
  a.className = "row";
  a.href = href;
  a.title = tooltip;
  a.target = "_blank";
  a.rel = "noreferrer";
  a.append(...cells);
  return a;
}

function chip(text, colour) {
  const span = document.createElement("span");
  span.className = "chip";
  span.style.setProperty("--c", colour);
  span.textContent = text;
  return span;
}

function setExpand(button, total, limit, open, noun) {
  const hidden = Math.max(0, total - limit);
  button.hidden = hidden === 0;
  button.setAttribute("aria-expanded", String(open));
  button.textContent = open ? "… less" : `… ${hidden} more ${noun}`;
}

function renderEvents() {
  const rows = state.eventsOpen ? state.events : state.events.slice(0, MAX_EVENTS);
  $events.textContent = "";
  if (!rows.length) {
    const li = document.createElement("li");
    li.className = "empty";
    li.textContent = "nothing in the next two weeks";
    $events.append(li);
  }
  let lastDay = "";
  for (const row of rows) {
    const label = dayLabel(row.startMs);
    if (label !== lastDay) {
      lastDay = label;
      const li = document.createElement("li");
      li.className = "day";
      li.textContent = label;
      $events.append(li);
    }
    const time = document.createElement("time");
    time.textContent = timeLabel(row.startMs, row.allDay);

    const body = document.createElement("div");
    const title = document.createElement("div");
    title.className = "title";
    title.textContent = row.summary || "(no title)";
    body.append(title);
    if (row.location) {
      const where = document.createElement("div");
      where.className = "where";
      where.textContent = row.location;
      body.append(where);
    }

    const span = row.allDay
      ? "all day"
      : `${timeLabel(row.startMs)}–${timeLabel(row.endMs)}`;
    const li = document.createElement("li");
    li.append(
      rowLink(
        CAL_DAY(),
        [span, row.location, row.calendar.label].filter(Boolean).join(" · "),
        time,
        body,
        chip(row.calendar.label, row.color || row.calendar.color),
      ),
    );
    $events.append(li);
  }
  setExpand($eventsExpand, state.events.length, MAX_EVENTS, state.eventsOpen, "events");
}

const taskColour = "#8a9199";

function dueLabel(todo) {
  if (todo.due === undefined) return { day: "—", sub: "", late: false };
  const due = new Date(todo.due);
  const midnight = new Date();
  midnight.setHours(0, 0, 0, 0);
  const day = new Date(due);
  day.setHours(0, 0, 0, 0);
  const diff = Math.round((day - midnight) / DAY);
  const minutes = due.getHours() * 60 + due.getMinutes();
  const timed = minutes !== 0 && minutes !== 1439;
  const sub = timed ? timeLabel(todo.due, false) : "";
  if (diff < 0) return { day: `-${-diff}d`, sub, late: true };
  if (diff === 0) return { day: "today", sub, late: todo.due < Date.now() };
  if (diff === 1) return { day: "tomorrow", sub, late: false };
  return { day: due.toLocaleDateString([], { weekday: "short", day: "numeric" }), sub, late: false };
}

function renderTodos() {
  const rows = state.todosOpen ? state.todos : state.todos.slice(0, MAX_TASKS);
  $tasks.textContent = "";
  if (!rows.length) {
    const li = document.createElement("li");
    li.className = "empty";
    li.textContent = "nothing open";
    $tasks.append(li);
  }
  for (const todo of rows) {
    const due = dueLabel(todo);
    const day = document.createElement("time");
    day.className = due.late ? "due overdue" : "due";
    day.textContent = due.day;

    const body = document.createElement("div");
    const title = document.createElement("div");
    title.className = "title";
    title.textContent = todo.summary;
    body.append(title);
    if (due.sub) {
      const where = document.createElement("div");
      where.className = "where";
      where.textContent = `due ${due.sub}`;
      body.append(where);
    }

    const cells = [day, body];
    if (todo.categories?.length) cells.push(chip(todo.categories[0], taskColour));
    const when = todo.due === undefined ? "no due date" : new Date(todo.due).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
    const li = document.createElement("li");
    li.append(
      rowLink(
        CAL_AGENDA,
        [todo.categories?.join(", "), when].filter(Boolean).join(" · "),
        ...cells,
      ),
    );
    $tasks.append(li);
  }
  setExpand($tasksExpand, state.todos.length, MAX_TASKS, state.todosOpen, "tasks");
  $todoMeta.textContent = state.todos.length ? `${state.todos.length} open` : "";
}

/* ---------- data ---------- */

async function refreshEvents() {
  const now = Date.now();
  const to = now + HORIZON_DAYS * DAY;
  let failed = 0;
  const results = await Promise.all(
    CALENDARS.filter((cal) => cal.path !== "tasks").map((cal) =>
      loadCalendar(cal, now, to).catch(() => {
        failed++;
        return [];
      }),
    ),
  );

  const all = results.flatMap((events) => rowsFor(events, now, to));
  all.sort((a, b) => a.startMs - b.startMs || (a.summary || "").localeCompare(b.summary || ""));

  const seen = new Set();
  state.events = all.filter((row) => {
    const key = `${row.uid}:${row.startMs}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });

  $horizon.textContent = failed
    ? `next ${HORIZON_DAYS} days · ${failed} calendar(s) unreachable`
    : `next ${HORIZON_DAYS} days`;
  renderEvents();
}

async function refreshTodos() {
  try {
    const todos = await loadTodos();
    todos.sort((a, b) => {
      const ad = a.due ?? Infinity;
      const bd = b.due ?? Infinity;
      if (ad !== bd) return ad - bd;
      const ap = a.priority || 9;
      const bp = b.priority || 9;
      if (ap !== bp) return ap - bp;
      return (a.summary || "").localeCompare(b.summary || "");
    });
    state.todos = todos;
  } catch {
    state.todos = [];
  }
  renderTodos();
}

/* ---------- service status ---------- */

// Same-origin probes through this vhost's /svc/* proxies: a real request to the
// real backend, so "up" means the service answered, not that a name resolves.
// `detail` is filled from the response — a version when the service offers one,
// otherwise a word for the status, because a bare dot cannot tell 200 from 401.
const SERVICES = [
  { name: "immich", probe: "/svc/immich/api/server/version", href: "https://immich.ts.wyli.tech", json: true },
  { name: "deepseek-harness", probe: "/svc/dsh/", href: "https://ds.ts.wyli.tech" },
  { name: "sure", probe: "/svc/sure/up", href: "https://sure.ts.wyli.tech" },
  { name: "cal-ui", probe: "/svc/cal/", href: "https://cal.ts.wyli.tech" },
  { name: "caldav", probe: "/svc/dav/.web/", href: "https://dav.ts.wyli.tech" },
];

const $services = document.getElementById("services");

// Server latency from the resource entry, not wall-clock around the await:
// the first probe runs while nine calendar REPORTs are being parsed, and that
// main-thread jank would otherwise show up as a slow service.
function servedMs(url) {
  const entries = performance.getEntriesByName(new URL(url, location.href).href, "resource");
  const entry = entries[entries.length - 1];
  if (!entry || !entry.requestStart) return null;
  return Math.round(entry.responseEnd - entry.requestStart);
}

function statusWord(status) {
  if (status >= 500) return `error ${status}`;
  if (status === 404) return "no route";
  if (status === 401 || status === 403) return "auth";
  if (status >= 300) return "redirect";
  return "";
}

async function probe(svc) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 4000);
  const started = performance.now();
  try {
    const res = await fetch(svc.probe, { cache: "no-store", redirect: "manual", signal: ctrl.signal });
    const ms = servedMs(svc.probe) ?? Math.round(performance.now() - started);
    let detail = statusWord(res.status);
    if (svc.json && res.ok) {
      const { major, minor, patch } = await res.json();
      if (major !== undefined) detail = `${major}.${minor}.${patch}`;
    }
    return { state: res.status >= 500 ? "degraded" : "up", ms, status: res.status, detail };
  } catch {
    return { state: "down", ms: null, status: 0, detail: "" };
  } finally {
    clearTimeout(timer);
  }
}

async function refreshStatus() {
  const states = await Promise.all(SERVICES.map(probe));
  $services.textContent = "";
  SERVICES.forEach((svc, i) => {
    const { state, ms, status, detail } = states[i];
    const a = document.createElement("a");
    a.className = `tile ${state}`;
    a.href = svc.href;
    a.title = state === "down" ? `${svc.name}: no response` : `${svc.name}: HTTP ${status} in ${ms} ms`;

    const dot = document.createElement("span");
    dot.className = "dot";
    a.append(dot, document.createTextNode(svc.name));

    if (detail) {
      const span = document.createElement("span");
      span.className = "detail";
      span.textContent = detail;
      a.append(span);
    }
    if (ms !== null) {
      const timing = document.createElement("span");
      timing.className = "ms";
      timing.textContent = `${ms}ms`;
      a.append(timing);
    }
    $services.append(a);
  });
}

/* ---------- weather ---------- */

const WMO = {
  0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast",
  45: "fog", 48: "rime fog",
  51: "light drizzle", 53: "drizzle", 55: "heavy drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
  61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
  71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains",
  80: "light showers", 81: "showers", 82: "heavy showers", 85: "snow showers", 86: "heavy snow showers",
  95: "thunderstorm", 96: "thunderstorm, hail", 99: "thunderstorm, hail",
};

async function loadWeather() {
  const url =
    "https://api.open-meteo.com/v1/forecast?latitude=22.2819&longitude=114.1582" +
    "&current=temperature_2m,relative_humidity_2m,weather_code&timezone=Asia%2FHong_Kong";
  try {
    const res = await fetch(url, { cache: "no-store" });
    const { current } = await res.json();
    const parts = [
      `${Math.round(current.temperature_2m)}°`,
      WMO[current.weather_code] ?? "",
      `${current.relative_humidity_2m}%`,
    ].filter(Boolean);
    $weather.textContent = parts.join(" · ");
    $weather.title = `Hong Kong · ${current.time.replace("T", " ")}`;
    $weather.hidden = false;
  } catch {
    /* the clock is enough when the network is not */
  }
}

/* ---------- expand ---------- */

$eventsExpand.addEventListener("click", () => {
  state.eventsOpen = !state.eventsOpen;
  renderEvents();
});

$tasksExpand.addEventListener("click", () => {
  state.todosOpen = !state.todosOpen;
  renderTodos();
});

/* ---------- dsh inbox ---------- */

const $toggle = document.getElementById("ask-toggle");
const $askBody = document.getElementById("ask-body");
const $frame = document.getElementById("ask-frame");

$toggle.addEventListener("click", () => {
  const open = $askBody.hidden;
  $askBody.hidden = !open;
  $toggle.setAttribute("aria-expanded", String(open));
  $toggle.textContent = open ? "close" : "open";
  // Lazy: the iframe only loads (and only asks for the LAN password) on demand.
  if (open && !$frame.getAttribute("src")) $frame.src = $frame.dataset.src;
});

tick();
setInterval(tick, 15000);
loadWeather();
setInterval(loadWeather, 900000);
// Status first: the calendar pulls nine RFC 4918 REPORTs, and browsers cap
// connections per origin — probing after them made the last probe look slow.
refreshStatus().finally(() => {
  refreshEvents();
  refreshTodos();
});
setInterval(refreshStatus, 60000);
setInterval(refreshEvents, 300000);
setInterval(refreshTodos, 300000);
