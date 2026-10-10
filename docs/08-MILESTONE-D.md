# Milestone D — Action Router

**Goal:** every one of the 14 intents lands on a named branch, and nothing falls
through silently. Missing or impossible booking details turn into one clear
question, decided by code from the facts Milestone C computed.

**Why now:** after C, the system *understands* messages but does nothing with them.
Every booking got the same "Let me check that for you" holding line. D is the
switchboard: it decides, for every message, **what should happen next**. Branches
whose real action doesn't exist yet (availability, booking changes, owner reports,
escalation) get an honest placeholder. Milestones E and F then replace those
placeholders one by one, without touching the router again.

**Time:** about 90 minutes.

**Prerequisite:** Milestone C green. WF-02 and WF-10 **Published**.

**Acceptance test (master plan):** all 14 intents land on a branch, none fall
through silently. You'll prove it with one script that sends a message for every
intent and prints the route each one took.

---

## D1. The design in one picture

All the work happens inside **WF-02**, between `FN Validate AI Output` and
`PG Save AI Result`:

```
… FN Validate AI Output
     → FN Plan Action                     ← new: decides route + clarifying question
     → SW Route By Action                 ← new: 6 outputs
          ├─ reply            ────────────────────────────────┐
          ├─ check_availability → FN Stub Check Availability ─┤   (E replaces this)
          ├─ change_booking     → FN Stub Change Booking     ─┤   (F replaces this)
          ├─ owner_query        → FN Stub Owner Query        ─┤   (F replaces this)
          ├─ escalate           → FN Stub Escalate           ─┤   (F replaces this)
          └─ unrouted (fallback)→ FN Unrouted                ─┤   (should never fire)
                                                              ↓
                                                   FN Finalize Reply   ← new
                                                   → PG Save AI Result (existing)
                                                   → FN Return AI Result (1-line change)
```

**Why the router lives in WF-02 and not WF-01:** the reply that gets saved to
`conversations` and the audit row WF-02 writes must describe what *actually*
happened. If the router sat in WF-01 after WF-02 had already saved "Let me check
that", the log would contradict the real reply. Keep the decision and the record
of the decision in the same place.

**Why a Code node *and* a Switch:** the Code node (`FN Plan Action`) holds all the
rules in one readable place: 14 intents, 9 validation flags, the role. The Switch
only fans out on the single answer it produces (`route`). A Switch with 14 × 9
conditions spread across the canvas is how routing bugs hide.

### The routing table

This is the whole contract. If you ever wonder "where does X go?", it's here.

| Intent | Who | Route | What the person gets in D |
|---|---|---|---|
| `booking` (all details valid) | customer | `check_availability` | Placeholder → real availability in **E** |
| `booking` (detail missing / impossible) | customer | `reply` | One clarifying question, from code |
| `booking` | owner / staff | `change_booking` | Placeholder (booking for a patient, F+) |
| `reschedule`, `cancel` | anyone | `change_booking` | Placeholder (F+) |
| `owner_schedule`, `owner_report`, `owner_contact_lookup` | owner / staff | `owner_query` | Placeholder (F+) |
| `human` | anyone | `escalate` | Honest "please call us" (WF-06 later) |
| `medical_question` | anyone | `escalate` | The fixed medical template from C |
| `faq`, `pricing`, `hours`, `insurance` | anyone | `reply` | The AI's grounded answer |
| `opt_out` | anyone | `reply` | "Reply STOP to unsubscribe" template |
| `unknown` | anyone | `reply` | AI's answer, or the fallback |
| *anything with `needs_human: true`* | anyone | `escalate` | Overrides the intent's normal route |
| *AI failed (`ai_ok: false`)* | anyone | `reply` | The fallback from C |
| *anything else* | — | `unrouted` | Logged as `unrouted_intent`. Means a bug |

### The clarifying questions, in priority order

When a booking can't proceed, the patient gets **one** question, the first match
from this list. (The persona rule "ask at most one question at a time" is now
enforced by code, not by hoping the model obeys.)

| Flag (from C) | Question asked |
|---|---|
| `past_date` | That date has already passed. Which upcoming day would suit you? |
| `date_invalid` | Sorry, I couldn't work out the date. Which day would you like? |
| `too_far_ahead` | We can book up to 90 days ahead. Could you pick an earlier date? |
| `clinic_closed` | We're closed on Sundays. Our hours are … Which day works instead? |
| `slot_outside_hours` | 7:00 PM is outside our hours on Wednesday (8:00 AM–6:00 PM). What time would suit you? |
| `lead_time_too_short` | That's a little too soon for us to prepare. Could you choose a later time? |
| `missing_service` | Which service would you like? We offer: Dental Cleaning, New Patient Exam, … |
| `missing_date` | Which day would you like to come in? |
| `missing_time` | What time would suit you on Wednesday 8 Oct? |

Every number and name in those questions (hours, days, service names, the 90 days)
comes from the database context loaded in C. Change the clinic's hours with one
SQL `UPDATE` and the questions change with them.

---

## D2. Build it in WF-02

Open **SF WF-02 AI Conversation**.

### D2.1 Make room

1. Delete the connection `FN Validate AI Output` → `PG Save AI Result` (hover the
   line → trash icon).
2. Drag `PG Save AI Result` and `FN Return AI Result` to the right to make space.

---

### Node A — `FN Plan Action`  (Code, Run Once for All Items)

Connect: `FN Validate AI Output` → `FN Plan Action`.

```javascript
// FN Plan Action
// DETERMINISTIC router brain. Reads the validated AI result and decides:
//   route       — which branch of SW Route By Action runs next
//   reply_text  — set here only when the answer is already known
//                 (a clarifying question, a template, or the AI's grounded reply)
// No network, no database. Same input → same route, every time.

const v   = $input.first().json;                          // FN Validate AI Output
const ctx = $('PG Load AI Context').first().json;

const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const tenantView = ctx.data_scope === 'tenant';           // owner / staff
const flags = new Set(v.validation_flags || []);
const phone = ctx.phone_public || 'the office';

// ---- helpers -------------------------------------------------------------
const to12h = (hhmm) => {
  let [h, m] = String(hhmm).split(':').map(Number);
  const ap = h >= 12 ? 'PM' : 'AM';
  h = h % 12 || 12;
  return `${h}:${String(m).padStart(2, '0')} ${ap}`;
};
const dayLabel = (iso) => {
  const d = (ctx.next_days || []).find((x) => x.date === iso);
  return d ? d.label : iso;                               // "Wednesday 08 Oct" or the raw date
};
const weekdayOf = (iso) => new Date(`${iso}T00:00:00Z`).getUTCDay();
const hoursText = () => (ctx.hours || [])
  .filter((h) => !h.closed)
  .map((h) => `${DAYS[h.weekday].slice(0, 3)} ${to12h(h.opens)}–${to12h(h.closes)}`)
  .join(', ');
const serviceList = () => (ctx.services || []).map((s) => s.name).join(', ');

// ---- clarifying question for an incomplete / impossible booking ----------
// Checked in priority order; the first match wins. One question at a time.
function clarify() {
  if (flags.has('past_date'))
    return ['past_date', 'That date has already passed. Which upcoming day would suit you?'];
  if (flags.has('date_invalid'))
    return ['needs_clarification', "Sorry, I couldn't work out the date. Which day would you like?"];
  if (flags.has('too_far_ahead'))
    return ['too_far_ahead', `We can book up to ${ctx.max_days_in_advance} days ahead. Could you pick an earlier date?`];
  if (flags.has('clinic_closed')) {
    const day = v.date ? DAYS[weekdayOf(v.date)] + 's' : 'that day';
    return ['clinic_closed', `We're closed on ${day}. Our hours are ${hoursText()}. Which day works instead?`];
  }
  if (flags.has('slot_outside_hours')) {
    const h = (ctx.hours || []).find((x) => Number(x.weekday) === weekdayOf(v.date));
    return ['slot_outside_hours',
      `${to12h(v.preferred_time)} is outside our hours on ${DAYS[weekdayOf(v.date)]} ` +
      `(${to12h(h.opens)}–${to12h(h.closes)}). What time would suit you?`];
  }
  if (flags.has('lead_time_too_short'))
    return ['lead_time_too_short', "That's a little too soon for us to prepare. Could you choose a later time?"];
  if (flags.has('missing_service'))
    return ['needs_clarification', `Which service would you like? We offer: ${serviceList()}.`];
  if (flags.has('missing_date'))
    return ['needs_clarification', 'Which day would you like to come in?'];
  if (flags.has('missing_time'))
    return ['needs_clarification', `What time would suit you on ${dayLabel(v.date)}?`];
  return null;
}

// ---- the routing table (docs/08-MILESTONE-D.md §D1) -----------------------
let route = 'unrouted';
let reply = v.reply_text;            // from C: AI draft or a fixed template
let source = v.reply_source;
let reason = v.reason_code;

const REPLY_INTENTS = ['faq', 'pricing', 'hours', 'insurance', 'opt_out', 'unknown'];

if (!v.ai_ok) {
  route = 'reply';                                     // C already chose the fallback
} else if (v.intent === 'medical_question') {
  route = 'escalate';                                  // keeps C's medical template
} else if (v.intent === 'human' || v.needs_human === true) {
  route = 'escalate';
  reply = null; source = null;                         // the escalate branch writes it
} else if (v.intent === 'booking' && !tenantView) {
  const q = clarify();
  if (q) {
    route = 'reply';
    [reason, reply] = q;
    source = 'template';
  } else {
    route = 'check_availability';
    reply = null; source = null;
  }
} else if (v.intent === 'booking' || v.intent === 'reschedule' || v.intent === 'cancel') {
  route = 'change_booking';
  reply = null; source = null;
} else if (['owner_schedule', 'owner_report', 'owner_contact_lookup'].includes(v.intent)) {
  route = 'owner_query';
  reply = null; source = null;
} else if (REPLY_INTENTS.includes(v.intent)) {
  route = 'reply';
}
// Anything not matched above stays 'unrouted' and is caught by the Switch fallback.

return [{
  json: {
    ...v,
    route,
    reason_code: reason,
    reply_text: reply,
    reply_source: source,
    contact_phone_public: phone,       // convenience for the branch nodes
  },
}];
```

**Two details worth noticing:**

- **The router never invents a reason.** `reason_code` is either C's code, or the
  validation flag that triggered the question (`past_date`, `clinic_closed` …),
  or `needs_clarification` for a missing detail. All of them are in the fixed
  vocabulary, so `GROUP BY reason_code` in the audit log stays meaningful.
- **Owners and staff skip the clarifying questions.** "Book Test Patient in for a
  cleaning" is a staff action on someone else's behalf. It needs a patient lookup
  first, so it goes to `change_booking` (built in F).

---

### Node B — `SW Route By Action`  (Switch)

Connect: `FN Plan Action` → `SW Route By Action`.

| Setting | Value |
|---|---|
| Mode | **Rules** |
| Routing rules | 5 rules, each **String → is equal to**, left value `{{ $json.route }}` |
| Options → Fallback Output | **Extra Output** |

| Output | Right value | Rename Output → |
|---|---|---|
| 0 | `reply` | `reply` |
| 1 | `check_availability` | `check_availability` |
| 2 | `change_booking` | `change_booking` |
| 3 | `owner_query` | `owner_query` |
| 4 | `escalate` | `escalate` |
| 5 *(fallback)* | — | `unrouted` |

To rename an output: in each rule, toggle **Rename Output** on and type the name.
The names appear on the canvas next to each connector, so you never have to count
outputs to know which line is which.

**Why the fallback goes to its own node instead of `reply`:** a fallback that looks
like a normal reply hides bugs. If `FN Plan Action` ever produces a route the
Switch doesn't know (a typo, or a new intent added to the enum without a rule), you
want a loud `unrouted_intent` in the audit log, not a reply that seems fine.

---

### Nodes C–G — the branch nodes  (Code, one each)

Each is a small Code node. Create them, name them exactly, and connect the matching
Switch output to each. **The `reply` output connects straight to `FN Finalize
Reply`** (Node H). It needs no branch node because its reply is already decided.

Every stub follows the same contract: take the planned item, add `action_status`,
and fill in `reply_text` **only if the plan left it empty**. The medical template
from C must survive the escalate branch.

**`FN Stub Check Availability`**  ← Switch output `check_availability`

```javascript
// FN Stub Check Availability — REPLACED in Milestone E by the real tool call.
const p = $input.first().json;
return [{ json: {
  ...p,
  action_status: 'not_built',
  reply_text: p.reply_text ?? `I can't check live availability just yet. Please call us on ${p.contact_phone_public} and we'll find you a time.`,
  reply_source: p.reply_source ?? 'template',
} }];
```

**`FN Stub Change Booking`**  ← Switch output `change_booking`

```javascript
// FN Stub Change Booking — REPLACED in Milestone F (book / reschedule / cancel).
const p = $input.first().json;
const staff = p.persona_role !== 'customer';
return [{ json: {
  ...p,
  action_status: 'not_built',
  reply_text: p.reply_text ?? (staff
    ? 'Booking changes from chat are not connected yet (Milestone F).'
    : `I can't change bookings over chat just yet. Please call us on ${p.contact_phone_public} and we'll sort it out.`),
  reply_source: p.reply_source ?? 'template',
} }];
```

**`FN Stub Owner Query`**  ← Switch output `owner_query`

```javascript
// FN Stub Owner Query — REPLACED in Milestone F (get_schedule, get_daily_report, lookup_contact).
const p = $input.first().json;
return [{ json: {
  ...p,
  action_status: 'not_built',
  reply_text: p.reply_text ?? `Understood (${p.intent.replace('owner_', '').replace('_', ' ')}). Schedule and report lookups are not connected yet (Milestone F).`,
  reply_source: p.reply_source ?? 'template',
} }];
```

**`FN Stub Escalate`**  ← Switch output `escalate`

```javascript
// FN Stub Escalate — REPLACED by WF-06 (notify staff + pause the AI).
// Until WF-06 exists nobody is notified, so the reply must not claim they are.
const p = $input.first().json;
return [{ json: {
  ...p,
  action_status: 'not_built',
  reply_text: p.reply_text ?? `I'll need a member of our team for this. Please call us on ${p.contact_phone_public}.`,
  reply_source: p.reply_source ?? 'template',
} }];
```

**`FN Unrouted`**  ← Switch output `unrouted` (fallback)

```javascript
// FN Unrouted — should NEVER run. If it does, FN Plan Action has a gap.
const p = $input.first().json;
return [{ json: {
  ...p,
  action_status: 'unrouted',
  reason_code: 'unrouted_intent',
  reply_text: `Sorry, I didn't quite get that. Could you say it another way? You can also call us on ${p.contact_phone_public}.`,
  reply_source: 'template',
} }];
```

---

### Node H — `FN Finalize Reply`  (Code)

Connect **all six** into its input: the Switch's `reply` output plus the five branch
nodes above. (Like `PG Write Audit Log` in WF-01, one node with many inputs. Only
one branch runs per message.)

Then connect `FN Finalize Reply` → `PG Save AI Result`.

```javascript
// FN Finalize Reply
// One exit from the router, whatever branch ran. Produces the SAME shape that
// FN Validate AI Output used to produce, so PG Save AI Result works unchanged,
// plus the route/action fields for the audit log and WF-01's response.

const r = $input.first().json;
const ctx = $('PG Load AI Context').first().json;

// Final safety net: there must always be something to say.
const reply = String(r.reply_text ?? '').trim()
  || `Sorry, I didn't quite get that. Could you say it another way? You can also call us on ${r.contact_phone_public}.`;

const ACTIONS_THAT_CONFIRM = ['check_availability', 'change_booking', 'owner_query'];

return [{
  json: {
    ...r,
    reply_text: reply,
    reply_source: r.reply_source || 'template',
    action_status: r.action_status || 'none',      // 'none' for the plain reply branch
    // Final when nothing is still pending. Stubs are final too: they say honestly
    // that the action isn't available, and promise nothing.
    reply_is_final: !(ACTIONS_THAT_CONFIRM.includes(r.route) && r.action_status === 'pending'),
    // offered_slots: filled by the availability branch from Milestone E on, so
    // Milestone F knows which times the patient was offered.
    ai_payload: { ...r.ai_payload, route: r.route, action_status: r.action_status || 'none', offered_slots: r.offered_slots ?? null },
    audit_details: {
      ...r.audit_details,
      route: r.route,
      action_status: r.action_status || 'none',
      final_reason: r.reason_code,
      reply_source: r.reply_source || 'template',
    },
  },
}];
```

`PG Save AI Result` needs **no changes**. It reads `$json.reply_text`,
`$json.reason_code`, `$json.audit_details` and so on, and `FN Finalize Reply`
provides all of them. The reply saved to `conversations` is now the *final* one,
and the audit row records which route it took.

---

### Node I — `FN Return AI Result`  (existing, change one line)

It currently reads from `FN Validate AI Output`, which no longer has the final
reply. Replace its code with:

```javascript
// FN Return AI Result — the single exit of WF-02.
const { ai_payload, audit_details, contact_phone_public, ...result } = $('FN Finalize Reply').first().json;
return [{ json: result }];
```

### D2.2 Save and publish

**Save**, then **Publish** (top right). WF-01 calls the *published* WF-02. Forget
this and every test below runs yesterday's version. (C4 explains why.)

---

## D3. A faster way to test: publish WF-01

So far every test needed a click on **Execute workflow** first, because the
`/webhook-test/` URL only listens while the editor is waiting. With 16 messages to
send, that's 16 clicks.

**Publish WF-01** instead (top right → Publish). Its **production** URL then works
permanently, with no clicking:

```
http://localhost:5678/webhook/salesfixr/v1/inbound/test        ← production (published)
http://localhost:5678/webhook-test/salesfixr/v1/inbound/test   ← test (needs Execute workflow)
```

- It is still only reachable from your own PC. Nothing public exists until
  Milestone G's tunnel.
- Production runs don't light up the canvas. Watch them in **Overview →
  Executions**.
- **Re-publish WF-01 after every change**, the same rule as WF-02 and WF-10.

---

## D4. Acceptance tests

### D4.1 The router test script

This script is already in your project at `tests\d-router.ps1` (it loads the
shared helpers in `tests\sf-helpers.ps1`). It sends one message per intent, waits between calls so the free Gemini
tier doesn't rate-limit you, and prints a table.

```powershell
# tests/d-router.ps1 - Milestone D acceptance: every intent lands on a branch.
# Run:  cd F:\Agency\Automation_MVP ;  powershell -ExecutionPolicy Bypass -File .\tests\d-router.ps1
. "$PSScriptRoot\sf-helpers.ps1"                      # WF-01 must be Published (D3)

# A fresh "patient" number per run: avoids the 20-messages-a-day rate limit from
# Milestone B, and keeps old test chatter out of the conversation history.
$patient = New-TestPhone
$owner   = "+15550000001"

$cases = @(
  @{ who=$patient; msg="Can I book a cleaning tomorrow at 2?";            expect="check_availability" },
  @{ who=$patient; msg="Can I come in tomorrow at 10?";                   expect="reply (missing service)" },
  @{ who=$patient; msg="I'd like a cleaning on Friday";                   expect="reply (missing time)" },
  @{ who=$patient; msg="Can I get a cleaning on 1 January 2020 at 10am?"; expect="reply (past_date)" },
  @{ who=$patient; msg="Can I move my appointment to Thursday?";          expect="change_booking" },
  @{ who=$patient; msg="I need to cancel my appointment";                 expect="change_booking" },
  @{ who=$patient; msg="Do you treat children?";                          expect="reply" },
  @{ who=$patient; msg="How much is teeth whitening?";                    expect="reply" },
  @{ who=$patient; msg="Are you open on Saturday?";                       expect="reply" },
  @{ who=$patient; msg="Do you accept insurance?";                        expect="reply" },
  @{ who=(New-TestPhone); msg="Can I talk to a real person please?";       expect="escalate" },
  @{ who=(New-TestPhone); msg="My gum is bleeding and swollen";            expect="escalate (medical)" },
  @{ who=$patient; msg="Please stop sending me messages";                 expect="reply (opt-out hint)" },
  @{ who=$patient; msg="asdf qwerty";                                     expect="reply" },
  @{ who=$owner;   msg="What does tomorrow look like?";                   expect="owner_query" },
  @{ who=$owner;   msg="How many bookings did we get today?";             expect="owner_query" },
  @{ who=$owner;   msg="Find Test Patient's phone number";                expect="owner_query" }
)

$rows = foreach ($c in $cases) {
  try {
    $r = Send-SFRaw $c.who $c.msg
    $reply = [string]$r.reply_text
    [pscustomobject]@{
      Message = $c.msg.Substring(0, [Math]::Min(38, $c.msg.Length))
      Role    = $r.actor_role
      Intent  = $r.ai.intent
      Route   = $r.ai.route
      Reason  = $r.ai.reason_code
      Expect  = $c.expect
      Reply   = $reply.Substring(0, [Math]::Min(60, $reply.Length))
    }
  } catch {
    [pscustomobject]@{ Message = $c.msg; Route = "HTTP ERROR"; Reply = $_.Exception.Message }
  }
  Start-Sleep -Seconds 5      # stay under the free tier's requests-per-minute
}
$rows | Format-Table -AutoSize -Wrap
Write-Host "Test patient used: $patient"
# The two escalate rows use their own numbers: from Milestone F on, escalating pauses
# that patient for 12 h, which would block every later row for the same number.
```

Run it:

```powershell
cd F:\Agency\Automation_MVP
powershell -ExecutionPolicy Bypass -File .\tests\d-router.ps1
```

It takes about 2 minutes. **Pass criteria:**

- [ ] No row says `unrouted` or `HTTP ERROR`
- [ ] Every `Route` matches `Expect`. The model may legitimately read a borderline
      sentence differently (e.g. "Are you open on Saturday?" as `hours` or `faq`).
      That's fine **as long as the route is right**
- [ ] The three incomplete bookings get a **specific question**, not the holding line
- [ ] The medical row's reply is C's fixed medical template
- [ ] No reply claims anything was booked, moved, cancelled or passed to staff

### D4.2 Prove the questions come from data, not the model

```sql
UPDATE business_hours SET closes_at = '15:00'
WHERE weekday = 3 AND tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic');
```

Send (from any test patient): *"Can I get a cleaning next Wednesday at 4pm?"*
→ the reply now says Wednesday hours end at **3:00 PM**. Put it back:

```sql
UPDATE business_hours SET closes_at = '18:00'
WHERE weekday = 3 AND tenant_id = (SELECT id FROM tenants WHERE slug = 'demo_clinic');
```

### D4.3 The audit trail now shows routes

```sql
SELECT details->>'route'         AS route,
       details->>'action_status' AS action_status,
       reason_code,
       count(*)
FROM audit_logs
WHERE workflow = 'WF-02' AND created_at > now() - interval '1 hour'
GROUP BY 1, 2, 3
ORDER BY 1, 2;
```

You should see every route from the table in D1, and **zero** rows with route
`unrouted` or a null route. This query is your router health check from now on.

---

## D5. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Script rows all show the old "Let me check that for you" reply, no `Route` | WF-02 not **re-published** after adding the router. Publish it |
| `HTTP ERROR … 404` for every row | WF-01 isn't Published, so the `/webhook/` URL doesn't exist. Publish WF-01 (D3) |
| `Route` column empty but reply is new | `FN Return AI Result` still reads `FN Validate AI Output`. Apply the I change |
| A row says `unrouted` | `FN Plan Action` doesn't handle that intent. Compare its intent with the table in D1 |
| Rows after the 10th or so show `gate_decision: block`, `rate_limited` | You reused a fixed patient number. The script makes a fresh one per run; for manual tests use a new number or raise the limit: `UPDATE clinic_settings SET max_msgs_per_contact_per_day = 200;` |
| Several rows say `llm_error` with `429` | Free-tier per-minute limit. Increase `Start-Sleep` to 8 |
| `PG Save AI Result` error: `invalid input value for enum intent_t` | Something set `intent` to a non-enum value. The router never changes `intent`. Check you didn't overwrite it in a stub |
| The medical reply turned into "I'll need a member of our team" | A stub overwrote `reply_text`. Each stub must use `p.reply_text ?? …`, not `…` alone |

---

## Done when

- [ ] `FN Plan Action`, `SW Route By Action` (6 named outputs), 5 branch nodes and
      `FN Finalize Reply` built in WF-02
- [ ] `FN Return AI Result` reads from `FN Finalize Reply`
- [ ] WF-02 **Published**. WF-01 **Published** (for the script)
- [ ] `tests/d-router.ps1` passes: no `unrouted`, every route as expected
- [ ] D4.2 shows the question changes when the database changes
- [ ] The D4.3 query shows every route and no `unrouted`
- [ ] All workflows exported to `workflows/exports/` and committed:

```powershell
cd F:\Agency\Automation_MVP
git add docs tests workflows
git commit -m "Milestone D: deterministic action router + clarifying questions"
git push
```

**Next:** Milestone E — replace `FN Stub Check Availability` with real availability
from Postgres and Google Calendar. `docs/09-MILESTONE-E.md`.
