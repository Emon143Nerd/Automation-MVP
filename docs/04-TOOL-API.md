# Internal Tool API

Every action the AI can take is an n8n workflow exposed as an HTTP webhook.
This is the contract. It exists so that the **chat AI and the future voice AI call
the identical code**, and so that swapping Google Calendar for a dental PMS later
changes nothing outside these workflows.

Base URL: `{SF_PUBLIC_BASE_URL}/webhook/salesfixr/v1/tool/<tool_name>`

---

## Conventions

**Every request** carries this envelope. The caller (WF-02 for chat, ElevenLabs for
voice) fills it from the **authenticated identity**, never from model output:

```json
{
  "auth": { "tool_token": "shared secret, checked first" },
  "context": {
    "correlation_id": "uuid",
    "tenant_slug": "demo_clinic",
    "actor_role": "customer",
    "contact_id": "uuid",
    "staff_user_id": null
  },
  "args": { }
}
```

**Every response** has exactly this shape. No exceptions — the caller must never
have to guess.

```json
{
  "ok": true,
  "reason_code": "ok",
  "data": { },
  "human_summary": "One sentence the AI may paraphrase to the user."
}
```

On failure:

```json
{
  "ok": false,
  "reason_code": "slot_taken",
  "data": { "alternatives": ["2026-09-30T15:00:00+06:00"] },
  "human_summary": "That time was just taken. 3 PM or 4 PM are free."
}
```

**Non-negotiable rules for every tool workflow:**

1. **Check `tool_token` first.** These are public URLs. Reject with 401 otherwise.
2. **Re-check `actor_role` against `ai_personas.allowed_tools`.** Don't trust the caller.
3. **Scope every query by `tenant_id`.** Always.
4. **Never accept `contact_id` inside `args`.** It comes from `context` only.
   This single rule is what stops a patient reading another patient's record.
5. **Write an `audit_logs` row** with the `correlation_id` before returning.
6. **Return `ok:false` rather than throwing** — the AI needs a sentence it can say.

---

## Customer-scope tools

### `check_availability`
```json
{ "args": { "service_code": "dental_cleaning",
            "date": "2026-09-30",
            "preferred_time": "14:00" } }
```
Reads `services.duration_minutes`, `business_hours`, existing `appointments` and the
Google Calendar. Returns free slots, preferred one first.

```json
{ "ok": true, "data": {
    "requested_available": false,
    "slots": ["2026-09-30T15:00:00+06:00","2026-09-30T15:30:00+06:00"] } }
```
Reason codes: `slot_outside_hours`, `lead_time_too_short`, `past_date`, `service_unknown`.

---

### `book_appointment`
```json
{ "args": { "service_code": "dental_cleaning",
            "start_time": "2026-09-30T14:00:00+06:00",
            "patient_name": "John Smith" } }
```

Order of operations — **this order matters**:

1. `INSERT INTO appointments (... status='held', hold_expires_at=now()+ttl)`
   The `EXCLUDE` constraint fires here if the slot is taken → catch → `slot_taken`
   → call `check_availability` → return alternatives. *This is the double-booking fix.*
2. Create the Google Calendar event.
3. `UPDATE appointments SET status='booked', calendar_event_id=...`
4. Insert `reminders` rows from `clinic_settings.reminder_offsets_hours`.
5. Audit log.

If step 2 fails, the row stays `held` and expires on its own — no orphan bookings.

```json
{ "ok": true, "data": {
    "appointment_id": "uuid",
    "start_time": "2026-09-30T14:00:00+06:00",
    "service_display_name": "Dental Cleaning" },
    "human_summary": "Booked: Dental Cleaning, Tue 30 Sep at 2:00 PM." }
```

> The confirmation sent to the patient is generated **from `data`**, not from the
> model's `reply_text`. The model never announces a booking it didn't get confirmed.

---

### `reschedule_appointment`
`args: { appointment_id, new_start_time }` — must belong to `context.contact_id`
when `actor_role = customer`. Holds the new slot before releasing the old one.

### `cancel_appointment`
`args: { appointment_id, reason? }` — sets `status='cancelled'`, deletes the calendar
event, marks pending `reminders` as `skipped`. Ownership check as above.

### `list_my_appointments`
`args: {}` — deliberately takes no arguments. Scoped entirely by `context.contact_id`.

### `escalate_to_human`
`args: { summary, urgency }` — flags the thread, pauses the AI for that contact,
Telegrams the owner. Available to every role.

---

## Owner / staff-scope tools

All of these **hard-fail with `tool_not_allowed`** if `actor_role = 'customer'`.

| Tool | Args | Returns |
|---|---|---|
| `get_schedule` | `{ date? , date_from?, date_to? }` | appointments with patient name + phone |
| `get_daily_report` | `{ date? }` | counts: booked, cancelled, no-show, messages handled, escalations |
| `lookup_contact` | `{ query }` (name or phone) | matching contacts + their appointment history |
| `list_appointments_any` | `{ contact_id }` | any patient's appointments |
| `cancel_appointment_any` | `{ appointment_id, reason }` | cancels without ownership check |
| `reschedule_appointment_any` | `{ appointment_id, new_start_time }` | moves any appointment |
| `block_time` | `{ start_time, end_time, note }` | inserts a `booked` appointment on a system contact, so the slot is genuinely blocked by the same constraint |
| `get_daily_report` is owner-only | | staff get `get_schedule` but not metrics |

---

## Build order

Do **not** build all of these at once. Tool workflows arrive with the milestone that
needs them:

| Milestone | Tools built |
|---|---|
| E | `check_availability` |
| F | `book_appointment`, `escalate_to_human` |
| F+ | `list_my_appointments`, `cancel_appointment`, `reschedule_appointment` |
| F+ | `get_schedule`, `get_daily_report`, `lookup_contact` — *this is where role-awareness becomes visible in the demo* |
| H | (reminders use the DB directly, no tool needed) |
| I | none new — ElevenLabs reuses everything above |

---

## Why HTTP webhooks instead of n8n sub-workflow calls

n8n's AI Agent node can call sub-workflows as tools directly, which is slightly
simpler. We use HTTP webhooks anyway because:

- **ElevenLabs can only call HTTP.** A sub-workflow tool would have to be rebuilt as
  a webhook later — exactly the refactor this design exists to avoid.
- A future dashboard, a Zapier user, or a client's own system can call them too.
- You can test any tool with `curl` without opening n8n.

The cost is one extra network hop on localhost. Worth it.

---

## Testing a tool by hand

PowerShell (what you'll actually use on this machine):

```powershell
$payload = @{
  auth    = @{ tool_token = "YOUR_SF_TOOL_TOKEN" }
  context = @{
    correlation_id = "manual-test-1"
    tenant_slug    = "demo_clinic"
    actor_role     = "customer"
    contact_id     = "PUT_A_REAL_CONTACT_UUID_HERE"
  }
  args    = @{ service_code = "dental_cleaning"; date = "2026-09-30"; preferred_time = "14:00" }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Post -ContentType "application/json" -Body $payload `
  -Uri "http://localhost:5678/webhook/salesfixr/v1/tool/check_availability"
```

> ⚠️ `curl` in Windows PowerShell 5.1 is an alias for `Invoke-WebRequest` and does
> **not** accept `-H` / `-d`. Use `Invoke-RestMethod` as above, or call `curl.exe`
> by its full name.

bash / WSL / macOS equivalent:

```bash
curl -X POST "$SF_PUBLIC_BASE_URL/webhook/salesfixr/v1/tool/check_availability" \
  -H "Content-Type: application/json" \
  -d '{
    "auth": { "tool_token": "YOUR_SF_TOOL_TOKEN" },
    "context": {
      "correlation_id": "manual-test-1",
      "tenant_slug": "demo_clinic",
      "actor_role": "customer",
      "contact_id": "PUT_A_REAL_CONTACT_UUID_HERE"
    },
    "args": { "service_code": "dental_cleaning", "date": "2026-09-30", "preferred_time": "14:00" }
  }'
```

Do this for every tool before wiring it to the AI. When the AI misbehaves later,
you'll already know the tools are sound — so the bug is in the prompt, and you've
halved your search space.
