# Milestone J — Dashboard

**Goal:** one read-only web page for the clinic owner: **upcoming bookings**, the
**inbox** (every conversation, patient and bot side by side), **analytics** for the
last 30 days, and a **health** view (what was blocked or failed). It runs inside
n8n, so nothing new to host and nothing new to pay for.

**Why last:** a dashboard only shows what the system already does. Now that
bookings (F), Messenger (G), reminders (H) and voice (I) all write to the same
tables, one query can show all of it. It's also the screen you show a prospective
client: "here's every booking and every message, and what the bot did with it".

**Time:** about 1.5 hours. One workflow of 4 nodes.

**Prerequisite:** Milestones F and G green. (H and I make the page richer, but
aren't required.)

**Acceptance test (master plan):** the dashboard shows the booking you just made.

---

## J0. What gets built

```
Browser ──GET https://<ngrok>/webhook/salesfixr/v1/dashboard?view=inbox──► n8n
          (asks for username + password: Basic Auth)

SF WF-12 Dashboard                    (new)
  WH Dashboard            GET, Basic Auth
  → PG Dashboard Data     ONE query → clinic, KPIs, upcoming, cancelled, threads,
                          one thread, 30-day series, channels, intents, reminders, problems
  → FN Render Dashboard   builds the complete HTML page on the server
  → RESP Dashboard Page   text/html
```

| View | URL | Shows |
|---|---|---|
| Bookings (default) | `…/dashboard` | Next 14 days (booked + held), cancelled in the last 7 days |
| Inbox | `…/dashboard?view=inbox` | Last 40 conversations; click one to read the thread with intents and reminders |
| Analytics | `…/dashboard?view=analytics` | 30-day totals, bookings/day, messages/day, by channel, top intents |
| Health | `…/dashboard?view=health` | Reminder outcomes, last 7 days of `blocked`/`error` audit rows |

### Design decisions

**Server-rendered, no JavaScript in the page.** n8n serves HTML responses from
webhooks inside a **sandbox** (a security feature since n8n 1.x): scripts in the
page can't call other URLs as if they were n8n. A page that fetched data with
JavaScript would need CORS, sandbox exceptions and a token stored in the browser.
Instead WF-12 builds the finished HTML, tables and bar charts included, and the
browser only displays it. Navigation is plain links (`?view=inbox`). Nothing to
break, nothing to configure.

**Read-only.** There are no buttons that change data. Actions stay where they're
audited: Messenger (owner persona), the tools, or SQL. A dashboard that can cancel
appointments needs its own permission model; that's post-MVP.

**Basic Auth, because it shows patient data.** Names, phone numbers and messages
are personal data. The page is on your public ngrok address, so it's locked with a
username + password the browser asks for. Use a long password, and only open it
on your own devices.

**Escaping.** Every value from the database goes through `esc()` before it's put
into HTML. Patient messages are untrusted text: without escaping, a patient who
types `<script>…</script>` into Messenger would run code in **your** browser when you
open the inbox. (The test in J4 checks this on purpose.)

---

## J1. The dashboard login

Make a password (PowerShell):

```powershell
-join ((48..57)+(65..90)+(97..122) | Get-Random -Count 24 | % {[char]$_})
```

Save it in your password manager (not in chat, not in a doc). Then n8n →
Credentials → Create → **Basic Auth**:

| Field | Mode | Value |
|---|---|---|
| Credential name | — | `SalesFixr Dashboard` |
| User | Fixed | `owner` |
| Password | Fixed | the password you generated just above (the one you saved in your password manager) |

---

## J2. Build WF-12 — Dashboard

New workflow: **`SF WF-12 Dashboard`**. Tags: `salesfixr`, `dashboard`.

> **How to add each node below.** Click the **+** on the right edge of the previous
> node (or press **Tab** on the canvas, or the **+** at top right). A search box opens:
> type what each node's **Add it** line says and click that result. Then **rename** the
> node to the name in the heading: double-click its title at the top of the panel (or
> select it on the canvas and press **F2**) and type the name exactly. The 2-to-5-letter
> prefix (`FN`, `PG`, `TRG`…) is only part of our naming convention
> (`docs/02-NAMING-CONVENTIONS.md`); it is **not** something you search for.


### Node 1 — `WH Dashboard`  (Webhook)

**Add it:** search **`Webhook`** → click **Webhook** (the trigger, not "Respond to Webhook"). If it's the workflow's first node, use **Add first step**.

| Setting | Mode | Value |
|---|---|---|
| HTTP Method | — | `GET` |
| Path | Fixed | `salesfixr/v1/dashboard` |
| Authentication | — | **Basic Auth** → `SalesFixr Dashboard` |
| Respond | — | **Using 'Respond to Webhook' Node** |

### Node 2 — `PG Dashboard Data`  (Postgres → Execute Query)

**Add it:** search **`Postgres`** → in the action list click **Execute a SQL query** → Credential: **`Postgres account`**.

Credential `Postgres account`. **Settings → Always Output Data: ON.**

One statement, one row, every section as a JSON column. All times are converted
to the clinic's timezone in Postgres (`tenants.timezone`), so the page shows New
York times however your PC is set.

```sql
WITH t AS (
  SELECT t.id, t.slug, t.display_name, t.timezone
  FROM tenants t WHERE t.slug = $1 AND t.is_active
),
upcoming AS (
  SELECT a.start_time,
         to_char(a.start_time AT TIME ZONE t.timezone, 'Dy DD Mon')    AS day,
         to_char(a.start_time AT TIME ZONE t.timezone, 'FMHH12:MI AM') AS time,
         COALESCE(sv.display_name, a.service_code)                     AS service,
         COALESCE(c.full_name, '(no name)')                            AS patient,
         c.phone_e164                                                  AS phone,
         a.source_channel::text                                        AS channel,
         a.status::text                                                AS status,
         a.calendar_event_id IS NOT NULL                               AS on_calendar,
         c.id::text                                                    AS contact_id
  FROM t
  JOIN appointments a ON a.tenant_id = t.id
  JOIN contacts c     ON c.id = a.contact_id
  LEFT JOIN services sv ON sv.tenant_id = t.id AND sv.code = a.service_code
  WHERE a.status IN ('booked', 'held')
    AND a.start_time >= now() - interval '2 hours'
    AND a.start_time <  now() + interval '14 days'
  ORDER BY a.start_time
  LIMIT 200
),
cancelled AS (
  SELECT to_char(a.start_time AT TIME ZONE t.timezone, 'Dy DD Mon FMHH12:MI AM') AS slot,
         COALESCE(sv.display_name, a.service_code) AS service,
         COALESCE(c.full_name, c.phone_e164, '(unknown)') AS patient,
         COALESCE(a.cancel_reason, '') AS reason,
         to_char(a.updated_at AT TIME ZONE t.timezone, 'Dy DD Mon HH24:MI') AS changed
  FROM t
  JOIN appointments a ON a.tenant_id = t.id
  JOIN contacts c     ON c.id = a.contact_id
  LEFT JOIN services sv ON sv.tenant_id = t.id AND sv.code = a.service_code
  WHERE a.status IN ('cancelled', 'no_show') AND a.updated_at > now() - interval '7 days'
  ORDER BY a.updated_at DESC
  LIMIT 30
),
last_msg AS (
  SELECT DISTINCT ON (cv.contact_id)
         cv.contact_id, cv.body, cv.direction::text AS direction, cv.channel::text AS channel, cv.created_at
  FROM t JOIN conversations cv ON cv.tenant_id = t.id
  WHERE cv.contact_id IS NOT NULL AND cv.created_at > now() - interval '30 days'
  ORDER BY cv.contact_id, cv.created_at DESC
),
threads AS (
  SELECT c.id::text AS contact_id,
         COALESCE(c.full_name, c.phone_e164, ci.display_name, 'Messenger user') AS name,
         c.phone_e164 AS phone,
         lm.channel, lm.direction,
         left(COALESCE(lm.body, ''), 120) AS last_body,
         to_char(lm.created_at AT TIME ZONE t.timezone, 'Dy DD Mon HH24:MI') AS at,
         (c.ai_paused_until > now()) AS ai_paused,
         c.opted_out,
         EXISTS (SELECT 1 FROM staff_users su
                  WHERE su.tenant_id = t.id AND su.is_active
                    AND su.external_contact_id IN (SELECT external_contact_id FROM contact_identities x WHERE x.contact_id = c.id)) AS is_staff
  FROM t
  JOIN last_msg lm ON true
  JOIN contacts c ON c.id = lm.contact_id AND c.tenant_id = t.id
  LEFT JOIN LATERAL (SELECT display_name FROM contact_identities WHERE contact_id = c.id ORDER BY created_at LIMIT 1) ci ON true
  ORDER BY lm.created_at DESC
  LIMIT 40
),
thread AS (
  SELECT * FROM (
    SELECT cv.created_at,
           to_char(cv.created_at AT TIME ZONE t.timezone, 'Dy DD Mon HH24:MI') AS at,
           cv.direction::text AS direction, cv.actor_role::text AS actor_role,
           cv.channel::text AS channel, COALESCE(cv.intent::text, '') AS intent,
           cv.message_type, COALESCE(cv.body, '') AS body
    FROM t JOIN conversations cv ON cv.tenant_id = t.id
    WHERE cv.contact_id = NULLIF($2, '')::uuid
    ORDER BY cv.created_at DESC
    LIMIT 60
  ) x ORDER BY created_at
),
days AS (
  SELECT d::date AS day
  FROM t, generate_series((now() AT TIME ZONE t.timezone)::date - 29,
                          (now() AT TIME ZONE t.timezone)::date, interval '1 day') d
),
per_day AS (
  SELECT dd.day,
         to_char(dd.day, 'DD Mon') AS label,
         (SELECT count(*) FROM appointments a, t
           WHERE a.tenant_id = t.id AND a.booked_by_role IN ('customer','staff','owner')
             AND a.calendar_event_id IS NOT NULL
             AND (a.created_at AT TIME ZONE t.timezone)::date = dd.day) AS bookings,
         (SELECT count(*) FROM conversations cv, t
           WHERE cv.tenant_id = t.id AND cv.direction = 'inbound'
             AND (cv.created_at AT TIME ZONE t.timezone)::date = dd.day) AS messages
  FROM days dd
),
k AS (
  SELECT
    (SELECT count(*) FROM appointments a, t WHERE a.tenant_id = t.id AND a.status = 'booked'
        AND (a.start_time AT TIME ZONE t.timezone)::date = (now() AT TIME ZONE t.timezone)::date) AS today_appointments,
    (SELECT count(*) FROM upcoming WHERE status = 'booked') AS next_14_days,
    (SELECT count(*) FROM conversations cv, t WHERE cv.tenant_id = t.id AND cv.direction = 'inbound'
        AND (cv.created_at AT TIME ZONE t.timezone)::date = (now() AT TIME ZONE t.timezone)::date) AS messages_today,
    (SELECT count(*) FROM contacts c, t WHERE c.tenant_id = t.id AND c.ai_paused_until > now()) AS waiting_for_human,
    (SELECT count(*) FROM reminders r, t WHERE r.tenant_id = t.id AND r.status = 'pending') AS reminders_pending
),
a30 AS (
  SELECT
    (SELECT count(*) FROM appointments a, t WHERE a.tenant_id = t.id AND a.calendar_event_id IS NOT NULL
        AND a.created_at > now() - interval '30 days') AS bookings,
    (SELECT count(*) FROM appointments a, t WHERE a.tenant_id = t.id AND a.status = 'cancelled'
        AND a.cancel_reason IS DISTINCT FROM 'hold_expired' AND a.updated_at > now() - interval '30 days') AS cancellations,
    (SELECT count(*) FROM conversations cv, t WHERE cv.tenant_id = t.id AND cv.direction = 'inbound'
        AND cv.created_at > now() - interval '30 days') AS messages_in,
    (SELECT count(*) FROM conversations cv, t WHERE cv.tenant_id = t.id AND cv.direction = 'outbound'
        AND cv.created_at > now() - interval '30 days') AS messages_out,
    (SELECT count(*) FROM audit_logs l, t WHERE l.tenant_id = t.id AND l.action = 'escalate_to_human'
        AND l.status = 'ok' AND l.created_at > now() - interval '30 days') AS escalations,
    (SELECT count(*) FROM audit_logs l, t WHERE l.tenant_id = t.id AND l.reason_code LIKE 'llm\_%'
        AND l.created_at > now() - interval '30 days') AS ai_fallbacks
),
by_channel AS (
  SELECT a.source_channel::text AS channel, count(*) AS n
  FROM appointments a, t
  WHERE a.tenant_id = t.id AND a.calendar_event_id IS NOT NULL AND a.created_at > now() - interval '30 days'
  GROUP BY 1 ORDER BY 2 DESC
),
by_intent AS (
  SELECT cv.intent::text AS intent, count(*) AS n
  FROM conversations cv, t
  WHERE cv.tenant_id = t.id AND cv.intent IS NOT NULL AND cv.created_at > now() - interval '30 days'
  GROUP BY 1 ORDER BY 2 DESC LIMIT 10
),
rem AS (
  SELECT r.status::text || CASE WHEN r.skip_reason IS NOT NULL THEN ' · ' || r.skip_reason ELSE '' END AS outcome,
         count(*) AS n
  FROM reminders r, t
  WHERE r.tenant_id = t.id AND r.created_at > now() - interval '30 days'
  GROUP BY 1 ORDER BY 2 DESC
),
problems AS (
  SELECT to_char(l.created_at AT TIME ZONE t.timezone, 'Dy DD Mon HH24:MI') AS at,
         l.workflow, l.action, l.status, COALESCE(l.reason_code, '') AS reason_code
  FROM audit_logs l, t
  WHERE (l.tenant_id = t.id OR l.tenant_id IS NULL)
    AND l.status IN ('error', 'blocked')
    AND l.created_at > now() - interval '7 days'
  ORDER BY l.created_at DESC
  LIMIT 25
)
SELECT
  (SELECT row_to_json(x) FROM (SELECT slug, display_name, timezone,
          to_char(now() AT TIME ZONE timezone, 'Dy DD Mon YYYY, FMHH12:MI AM') AS local_now FROM t) x) AS clinic,
  (SELECT row_to_json(k) FROM k)                                         AS kpi,
  (SELECT COALESCE(json_agg(u ORDER BY u.start_time), '[]') FROM upcoming u)      AS upcoming,
  (SELECT COALESCE(json_agg(c), '[]') FROM cancelled c)                  AS cancelled,
  (SELECT COALESCE(json_agg(th), '[]') FROM threads th)                  AS threads,
  (SELECT COALESCE(json_agg(m ORDER BY m.created_at), '[]') FROM thread m)        AS thread,
  (SELECT COALESCE(json_agg(p ORDER BY p.day), '[]') FROM per_day p)     AS per_day,
  (SELECT row_to_json(a30) FROM a30)                                     AS last30,
  (SELECT COALESCE(json_agg(b), '[]') FROM by_channel b)                 AS by_channel,
  (SELECT COALESCE(json_agg(i), '[]') FROM by_intent i)                  AS by_intent,
  (SELECT COALESCE(json_agg(r), '[]') FROM rem r)                        AS reminders,
  (SELECT COALESCE(json_agg(p), '[]') FROM problems p)                   AS problems;
```

**Query Parameters** (Expression):

```
{{ [ $json.query.clinic || 'demo_clinic', /^[0-9a-f-]{36}$/i.test($json.query.contact || '') ? $json.query.contact : '' ] }}
```

- `$1` = which clinic (`?clinic=demo_clinic` by default; a second clinic later is a
  different link, same workflow).
- `$2` = the conversation to open in the inbox (`?contact=<uuid>`). Anything that
  isn't a uuid is replaced by `''` **before** it reaches SQL.

**Connect:** `WH Dashboard` → this node.

### Node 3 — `FN Render Dashboard`  (Code)

**Add it:** search **`Code`** → click **Code** (Language: **JavaScript**). Delete the sample code before pasting.

```javascript
// FN Render Dashboard
// Builds the whole page on the server: no JavaScript runs in the browser, so n8n's
// HTML sandbox doesn't matter and nothing needs CORS. Read-only by design.
// EVERY value from the database goes through esc(): patient messages are untrusted
// text, and without escaping a message like "<script>…" would run in your browser.

const d = $input.first().json;
const q = $('WH Dashboard').first().json.query || {};
const VIEWS = ['bookings', 'inbox', 'analytics', 'health'];
const view = VIEWS.includes(q.view) ? q.view : 'bookings';
const contact = /^[0-9a-f-]{36}$/i.test(q.contact || '') ? q.contact : '';
const clinicSlug = d.clinic ? d.clinic.slug : '';

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const link = (params, label, cls = '') => {
  const p = new URLSearchParams({ clinic: clinicSlug, ...params }).toString();
  return `<a class="${cls}" target="_top" href="?${esc(p)}">${label}</a>`;
};
const table = (cols, rows, empty) => rows.length
  ? `<div class="scroll"><table><thead><tr>${cols.map((c) => `<th>${esc(c[0])}</th>`).join('')}</tr></thead><tbody>` +
    rows.map((r) => `<tr>${cols.map((c) => `<td>${c[1](r)}</td>`).join('')}</tr>`).join('') +
    '</tbody></table></div>'
  : `<p class="muted">${esc(empty)}</p>`;
const pill = (text, kind = '') => `<span class="pill ${kind}">${esc(text)}</span>`;
const bars = (rows, key, labelKey) => {
  const max = Math.max(1, ...rows.map((r) => Number(r[key]) || 0));
  return '<div class="bars">' + rows.map((r) => {
    const n = Number(r[key]) || 0;
    return `<div class="bar" title="${esc(r[labelKey])}: ${n}"><span style="height:${Math.round((n / max) * 100)}%"></span><em>${n || ''}</em></div>`;
  }).join('') + '</div><div class="axis"><span>' + esc(rows[0]?.[labelKey] || '') + '</span><span>' +
    esc(rows[rows.length - 1]?.[labelKey] || '') + '</span></div>';
};

if (!d.clinic) {
  return [{ json: { html: `<!doctype html><meta charset="utf-8"><title>SalesFixr</title><p>Unknown clinic "${esc(q.clinic)}".</p>` } }];
}

const k = d.kpi || {};
const cards = [
  ['Today', k.today_appointments, 'appointments'],
  ['Next 14 days', k.next_14_days, 'booked'],
  ['Messages today', k.messages_today, 'from patients'],
  ['Waiting for a human', k.waiting_for_human, 'AI paused'],
  ['Reminders queued', k.reminders_pending, 'pending'],
].map(([t, n, sub]) => `<div class="card"><div class="num">${esc(n ?? 0)}</div><div>${esc(t)}</div><div class="muted">${esc(sub)}</div></div>`).join('');

let body = '';
if (view === 'bookings') {
  body = '<h2>Upcoming (14 days)</h2>' + table([
    ['Day', (r) => esc(r.day)], ['Time', (r) => esc(r.time)], ['Service', (r) => esc(r.service)],
    ['Patient', (r) => link({ view: 'inbox', contact: r.contact_id }, esc(r.patient))],
    ['Phone', (r) => esc(r.phone || '')], ['Channel', (r) => pill(r.channel)],
    ['Status', (r) => pill(r.status, r.status === 'held' ? 'warn' : 'ok') + (r.on_calendar ? '' : ' ' + pill('not on calendar', 'bad'))],
  ], d.upcoming || [], 'No upcoming appointments.') +
  '<h2>Cancelled in the last 7 days</h2>' + table([
    ['Was', (r) => esc(r.slot)], ['Service', (r) => esc(r.service)], ['Patient', (r) => esc(r.patient)],
    ['Reason', (r) => esc(r.reason)], ['Changed', (r) => esc(r.changed)],
  ], d.cancelled || [], 'None.');
} else if (view === 'inbox') {
  const threads = table([
    ['Who', (r) => link({ view: 'inbox', contact: r.contact_id }, esc(r.name)) +
      (r.is_staff ? ' ' + pill('staff') : '') + (r.ai_paused ? ' ' + pill('needs human', 'bad') : '') +
      (r.opted_out ? ' ' + pill('opted out', 'warn') : '')],
    ['Channel', (r) => pill(r.channel)],
    ['Last message', (r) => (r.direction === 'outbound' ? '<span class="muted">↩ </span>' : '') + esc(r.last_body)],
    ['When', (r) => esc(r.at)],
  ], d.threads || [], 'No conversations in the last 30 days.');
  const msgs = (d.thread || []).map((m) => `<div class="msg ${m.direction === 'inbound' ? 'in' : 'out'}">` +
    `<div class="meta">${esc(m.at)} · ${esc(m.actor_role)} · ${esc(m.channel)}${m.intent ? ' · ' + esc(m.intent) : ''}` +
    `${m.message_type !== 'text' ? ' · ' + esc(m.message_type) : ''}</div>${esc(m.body).replace(/\n/g, '<br>')}</div>`).join('');
  body = '<div class="split"><div><h2>Conversations</h2>' + threads + '</div><div><h2>Thread</h2>' +
    (contact ? (msgs || '<p class="muted">No messages.</p>') : '<p class="muted">Pick a conversation.</p>') + '</div></div>';
} else if (view === 'analytics') {
  const a = d.last30 || {};
  const rate = a.messages_in ? Math.round((Number(a.ai_fallbacks) / Number(a.messages_in)) * 100) : 0;
  body = '<h2>Last 30 days</h2><div class="cards">' + [
    ['Bookings', a.bookings], ['Cancellations', a.cancellations], ['Messages in', a.messages_in],
    ['Replies out', a.messages_out], ['Escalations', a.escalations], ['AI fallbacks', `${a.ai_fallbacks ?? 0} (${rate}%)`],
  ].map(([t, n]) => `<div class="card"><div class="num">${esc(n ?? 0)}</div><div>${esc(t)}</div></div>`).join('') + '</div>' +
  '<h2>Bookings per day</h2>' + bars(d.per_day || [], 'bookings', 'label') +
  '<h2>Patient messages per day</h2>' + bars(d.per_day || [], 'messages', 'label') +
  '<div class="split"><div><h2>Bookings by channel</h2>' + table([['Channel', (r) => pill(r.channel)], ['Bookings', (r) => esc(r.n)]], d.by_channel || [], 'No bookings yet.') +
  '</div><div><h2>Top intents</h2>' + table([['Intent', (r) => esc(r.intent)], ['Messages', (r) => esc(r.n)]], d.by_intent || [], 'No data yet.') + '</div></div>';
} else {
  body = '<h2>Reminders (30 days)</h2>' + table([['Outcome', (r) => esc(r.outcome)], ['Count', (r) => esc(r.n)]], d.reminders || [], 'No reminders yet.') +
    '<h2>Blocked or failed (7 days)</h2>' + table([
      ['When', (r) => esc(r.at)], ['Workflow', (r) => esc(r.workflow)], ['Action', (r) => esc(r.action)],
      ['Status', (r) => pill(r.status, r.status === 'error' ? 'bad' : 'warn')], ['Reason', (r) => esc(r.reason_code)],
    ], d.problems || [], 'Nothing blocked or failed. 🎉');
}

const nav = VIEWS.map((v) => link({ view: v }, v[0].toUpperCase() + v.slice(1), v === view ? 'on' : '')).join('');
const html = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(d.clinic.display_name)} · SalesFixr</title>
<style>
:root{--bg:#f6f7f9;--fg:#1d2330;--muted:#6b7385;--card:#fff;--line:#e3e6ec;--acc:#2f6fed;--ok:#1f9d55;--warn:#c27c0e;--bad:#d64545}
@media (prefers-color-scheme:dark){:root{--bg:#12151b;--fg:#e8ebf1;--muted:#98a0b3;--card:#1b2029;--line:#2a313d;--acc:#6c9bff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{padding:16px;border-bottom:1px solid var(--line);background:var(--card);display:flex;flex-wrap:wrap;gap:8px 16px;align-items:baseline}
header h1{font-size:18px;margin:0}main{padding:16px;max-width:1200px;margin:0 auto}
nav{display:flex;gap:4px;flex-wrap:wrap;margin-left:auto}nav a{padding:6px 12px;border-radius:8px;color:var(--fg);text-decoration:none}
nav a.on{background:var(--acc);color:#fff}a{color:var(--acc)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:0 0 8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px}.num{font-size:24px;font-weight:600}
.muted{color:var(--muted)}h2{font-size:15px;margin:24px 0 8px}
.scroll{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-weight:600;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.03em}tr:last-child td{border-bottom:0}
.pill{display:inline-block;padding:1px 8px;border-radius:999px;border:1px solid var(--line);font-size:12px}
.pill.ok{border-color:var(--ok);color:var(--ok)}.pill.warn{border-color:var(--warn);color:var(--warn)}.pill.bad{border-color:var(--bad);color:var(--bad)}
.split{display:grid;grid-template-columns:1fr 1fr;gap:16px}@media (max-width:800px){.split{grid-template-columns:1fr}}
.msg{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px 10px;margin:0 0 8px;max-width:90%}
.msg.out{margin-left:auto;border-color:var(--acc)}.meta{font-size:12px;color:var(--muted);margin-bottom:2px}
.bars{display:flex;align-items:flex-end;gap:3px;height:120px;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px}
.bar{flex:1;height:100%;display:flex;flex-direction:column;justify-content:flex-end;align-items:center;position:relative}
.bar span{display:block;width:100%;background:var(--acc);border-radius:3px 3px 0 0;min-height:1px}.bar em{font-size:10px;font-style:normal;color:var(--muted)}
.axis{display:flex;justify-content:space-between;font-size:12px;color:var(--muted);margin-top:4px}
</style></head><body>
<header><h1>${esc(d.clinic.display_name)}</h1><span class="muted">${esc(d.clinic.local_now)} (${esc(d.clinic.timezone)}) · ${link({ view, ...(contact ? { contact } : {}) }, 'Refresh')}</span><nav>${nav}</nav></header>
<main><div class="cards">${cards}</div>${body}</main></body></html>`;

return [{ json: { html } }];
```

**Connect:** `PG Dashboard Data` → this node.

### Node 4 — `RESP Dashboard Page`  (Respond to Webhook)

**Add it:** search **`Respond to Webhook`** → click it.

| Setting | Mode | Value |
|---|---|---|
| Respond With | — | **Text** |
| Response Body | **Expression** | `{{ $json.html }}` |
| Options → Add Option → **Response Headers** → Add Response Header | — | Name `Content-Type`, Value `text/html; charset=utf-8` |
| Options → Response Headers → second header | — | Name `Cache-Control`, Value `no-store` |

`no-store` stops the browser keeping a copy of patient data in its cache.

**Connect:** `FN Render Dashboard` → this node.

### Wiring table — `SF WF-12 Dashboard`

Draw exactly these connections, and nothing else. "→" means: drag from the **output** dot on the right of the first node to the **input** dot on the left of the second.

| # | From (output) | To (input) |
|---|---|---|
| 1 | `WH Dashboard` | `PG Dashboard Data` |
| 2 | `PG Dashboard Data` | `FN Render Dashboard` |
| 3 | `FN Render Dashboard` | `RESP Dashboard Page` (last node) |

**Check:** 4 nodes in a straight line. Response Body has a green preview.

**Save → Publish.**

---

## J3. Open it

On your PC: **http://localhost:5678/webhook/salesfixr/v1/dashboard**

From your phone or anywhere else (ngrok running):
**https://YOUR-NGROK-DOMAIN/webhook/salesfixr/v1/dashboard** (click through ngrok's
"You are about to visit" page first).

The browser asks for a username and password: `owner` + your password. The
**Bookings** view opens.

> **Bookmark tip:** bookmark `…/dashboard?view=inbox` too. That's the one you'll
> open most.

---

## J4. Acceptance tests

| # | Do | Expect |
|---|---|---|
| J-T1 | Open the page without credentials (private/incognito window, click **Cancel** on the login box) | `401` / "Authorization data is wrong" or a blank page. No data |
| J-T2 | Book from Messenger (or `Send-SF` test channel) for a day this week, then **Refresh** | **The booking appears** under *Upcoming*: day, time, service, name, phone, channel `messenger`/`test`, status `booked`. **← master-plan acceptance** |
| J-T3 | Click the patient's name | Inbox opens with that thread: their messages left, bot replies right (blue border), each with time, role, channel and intent |
| J-T4 | From the test channel: `Send-SF (New-TestPhone) "<script>alert('x')</script> hello"` → open Inbox | The message shows **as text**, `<script>…` literally. **No alert box.** |
| J-T5 | Ask for a human (`Send-SF $p "Can I speak to a real person?"`) → Inbox | That conversation has a red **needs human** tag; the *Waiting for a human* card counts it |
| J-T6 | Analytics view | Totals and bars include today's test traffic; *Bookings by channel* lists the channels you used (incl. `voice` if I is done) |
| J-T7 | Health view | Reminder outcomes (if H is done) and recent `blocked` rows, e.g. the forged-signature test from G10 (`bad_signature`) |
| J-T8 | `…/dashboard?clinic=nope` | "Unknown clinic", no data |
| J-T9 | On your phone (ngrok URL) | Same page; cards wrap; tables scroll sideways |

Clean up the J-T2/J-T5 test data as in F8 (cancel the booking, `ai_paused_until = NULL`).

---

## J5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `404 webhook not registered` | WF-12 not **Published**, or the path has a typo |
| Login box keeps reappearing | Wrong user/password, or the credential's User isn't `owner`. Browsers remember Basic Auth until you close all windows |
| Page shows the HTML **as text** (you see `<!doctype html>…`) | The `Content-Type: text/html; charset=utf-8` response header is missing in node 4 |
| Odd characters (Ã©, â€") | `charset=utf-8` missing from that header |
| Every section empty, header says "Unknown clinic" | `?clinic=` doesn't match `tenants.slug` (default `demo_clinic`), or the tenant is inactive |
| Error in `PG Dashboard Data`: `invalid input syntax for type uuid` | The Query Parameters expression isn't the one above (the uuid check must happen there) |
| A booking you made isn't listed | It's more than 14 days ahead, it's still `held` and expired, or it was made for another clinic slug. Check `appointments` directly |
| Links don't navigate | Some browsers block navigation from n8n's sandboxed page without a click; use the links (not keyboard shortcuts). If it persists, open the view's URL directly |
| Times are off by hours | `tenants.timezone`. The page never uses your PC's timezone |

---

## Done when

- [ ] `SalesFixr Dashboard` Basic Auth credential (password in your password manager)
- [ ] `SF WF-12 Dashboard` built per the wiring table, **Published**
- [ ] J-T1 to J-T9 pass, including **J-T2 (the acceptance test)** and **J-T4 (escaping)**
- [ ] Exported and committed:

```powershell
cd F:\Agency\Automation_MVP
git add docs workflows
git commit -m "Milestone J: read-only owner dashboard (bookings, inbox, analytics, health)"
git push
```

**That's the MVP.** Master plan §1 is complete: patients book over Messenger and
voice, the owner gets alerts, reminders and a schedule on demand, and everything
is visible and audited. Next steps are in master plan §8 (production swaps) and §9
(compliance) — do §9 before the first real patient.
