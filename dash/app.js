// dash — one page: clock, the next two weeks of calendar, service links.
// Calendar data comes from radicale through this vhost's /caldav/* proxy, so
// there is no CORS and no credential to store: radicale runs passwordless
// (auth.type = none) — the tailnet is the boundary — but still wants any
// Authorization header, hence the dummy Basic below.

const CALENDARS = [
  { path: "lectures", label: "lectures", color: "#55b4d4" },
  { path: "meetings", label: "meetings", color: "#aad94c" },
  { path: "exams", label: "exams", color: "#f07178" },
  { path: "work", label: "work", color: "#95e6cb" },
  { path: "events", label: "events", color: "#d2a6ff" },
  { path: "competitions", label: "competitions", color: "#ff8f40" },
  { path: "birthdays", label: "birthdays", color: "#f28779" },
  { path: "inbox", label: "inbox", color: "#81858c" },
  { path: "tasks", label: "tasks", color: "#8e8e93" },
];

const HORIZON_DAYS = 14;
const MAX_ROWS = 40;
const USER = "wyli";
const DAY = 86400000;
const DOW = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

const $time = document.getElementById("time");
const $date = document.getElementById("date");
const $events = document.getElementById("events");
const $horizon = document.getElementById("horizon");

/* ---------- clock ---------- */

function tick() {
  const now = new Date();
  $time.textContent = now.toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });
  $date.textContent = now.toLocaleDateString([], {
    weekday: "long",
    day: "numeric",
    month: "long",
  });
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
  const value = line.slice(colon + 1);
  const [name, ...params] = left.split(";");
  const p = {};
  for (const item of params) {
    const [k, v] = item.split("=");
    p[k.toUpperCase()] = v;
  }
  return { name: name.toUpperCase(), params: p, value };
}

// "20261118T090000" (local wall time, TZID or floating) or "20261118" (all-day).
function parseDate(value, params) {
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
      cur = { calendar };
      continue;
    }
    if (line === "END:VEVENT") {
      if (cur && cur.start) out.push(cur);
      cur = null;
      continue;
    }
    if (!cur) continue;
    const p = prop(line);
    if (!p) continue;
    switch (p.name) {
      case "DTSTART":
        cur.start = parseDate(p.value, p.params);
        break;
      case "DTEND":
        cur.end = parseDate(p.value, p.params);
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
      case "COLOR":
        if (/^#[0-9a-f]{6}$/i.test(p.value)) cur.color = p.value;
        break;
      case "STATUS":
        cur.status = p.value;
        break;
    }
  }
  for (const ev of out) {
    const start = ev.start.ms;
    const end = ev.end ? ev.end.ms : ev.duration ? start + ev.duration : start + (ev.start.allDay ? DAY : 3600000);
    ev.startMs = start;
    ev.endMs = Math.max(end, start + 60000);
    ev.allDay = ev.start.allDay;
  }
  return out;
}

// Occurrences of one VEVENT inside [from, to]. DAILY/WEEKLY/MONTHLY/YEARLY
// with INTERVAL, COUNT, UNTIL and BYDAY; unknown rules fall back to the master
// instance, which is the honest answer for something we do not understand.
function startOfWeek(d) {
  const c = new Date(d);
  c.setHours(0, 0, 0, 0);
  const shift = (c.getDay() + 6) % 7; // Monday = 0
  c.setDate(c.getDate() - shift);
  return c.getTime();
}

function occurrences(ev, from, to) {
  const r = ev.rrule;
  if (!r) return ev.startMs <= to ? [ev.startMs] : [];
  const interval = r.INTERVAL ? +r.INTERVAL : 1;
  const count = r.COUNT ? +r.COUNT : Infinity;
  const until = r.UNTIL ? (parseDate(r.UNTIL)?.ms ?? Infinity) : Infinity;
  const byday = r.BYDAY
    ? r.BYDAY.split(",")
        .map((d) => DOW[d.slice(-2)])
        .filter((d) => d !== undefined)
    : null;
  const start = new Date(ev.startMs);
  const out = [];
  let n = 0;

  if (!byday) {
    const cur = new Date(start);
    while (n < count && n < 400 && cur.getTime() <= until && cur.getTime() <= to) {
      if (cur.getTime() >= from) out.push(cur.getTime());
      n++;
      if (r.FREQ === "DAILY") cur.setDate(cur.getDate() + interval);
      else if (r.FREQ === "WEEKLY") cur.setDate(cur.getDate() + 7 * interval);
      else if (r.FREQ === "MONTHLY") cur.setMonth(cur.getMonth() + interval);
      else if (r.FREQ === "YEARLY") cur.setFullYear(cur.getFullYear() + interval);
      else break;
    }
    return out;
  }

  // BYDAY: walk day by day; a week counts once every `interval` weeks.
  const wkst = startOfWeek(start);
  const cur = new Date(start);
  while (n < count && n < 400 && cur.getTime() <= until && cur.getTime() <= to + DAY) {
    const week = Math.round((startOfWeek(cur) - wkst) / (7 * DAY));
    const sameClock = cur.getHours() === start.getHours() && cur.getMinutes() === start.getMinutes();
    if (byday.includes(cur.getDay()) && week % interval === 0 && sameClock) {
      if (cur.getTime() >= from) out.push(cur.getTime());
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
  if (!res.ok && res.status !== 207) throw new Error(`${cal.path}: ${res.status}`);
  const xml = new DOMParser().parseFromString(await res.text(), "application/xml");
  const nodes = xml.getElementsByTagNameNS("urn:ietf:params:xml:ns:caldav", "calendar-data");
  const events = [];
  for (const node of nodes) events.push(...parseIcs(node.textContent, cal));
  return events;
}

/* ---------- render ---------- */

function dayLabel(d) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const start = new Date(d);
  start.setHours(0, 0, 0, 0);
  const diff = Math.round((start - today) / DAY);
  if (diff === 0) return "today";
  if (diff === 1) return "tomorrow";
  return d.toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });
}

function timeLabel(ms, allDay) {
  if (allDay) return "all day";
  return new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false });
}

function render(rows) {
  $events.textContent = "";
  if (!rows.length) {
    const li = document.createElement("li");
    li.className = "empty";
    li.textContent = "nothing in the next two weeks";
    $events.append(li);
    return;
  }
  let lastDay = "";
  const now = Date.now();
  for (const row of rows) {
    const label = dayLabel(new Date(row.startMs));
    if (label !== lastDay) {
      lastDay = label;
      const li = document.createElement("li");
      li.className = "day";
      li.textContent = label;
      $events.append(li);
    }
    const li = document.createElement("li");
    if (row.endMs < now) li.className = "past";

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

    const chip = document.createElement("span");
    chip.className = "chip";
    chip.style.setProperty("--c", row.color || row.calendar.color);
    chip.textContent = row.calendar.label;

    li.append(time, body, chip);
    $events.append(li);
  }
}

async function refresh() {
  const now = Date.now();
  const to = now + HORIZON_DAYS * DAY;
  let failed = 0;
  const results = await Promise.all(
    CALENDARS.map((cal) =>
      loadCalendar(cal, now - DAY, to).catch(() => {
        failed++;
        return [];
      }),
    ),
  );
  const rows = [];
  for (const events of results) {
    for (const ev of events) {
      if (ev.status === "CANCELLED") continue;
      for (const startMs of occurrences(ev, now, to)) {
        rows.push({ ...ev, startMs, endMs: startMs + (ev.endMs - ev.startMs) });
      }
    }
  }
  rows.sort((a, b) => a.startMs - b.startMs || (a.summary || "").localeCompare(b.summary || ""));
  render(rows.slice(0, MAX_ROWS));
  $horizon.textContent = failed ? `next ${HORIZON_DAYS} days · ${failed} calendar(s) unreachable` : `next ${HORIZON_DAYS} days`;
}

tick();
setInterval(tick, 15000);
$horizon.textContent = `next ${HORIZON_DAYS} days`;
refresh();
setInterval(refresh, 300000);
