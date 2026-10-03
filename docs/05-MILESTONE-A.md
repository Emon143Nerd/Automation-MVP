# Milestone A — Database + n8n + WF-01 (test channel)

**Goal:** POST a test JSON payload at n8n, and end up with a contact and a message
row in Neon. No AI, no calendar, no Facebook yet.

**Why this first:** it proves the four things everything else stands on — n8n runs,
it can reach the database, the normalizer produces the standard envelope, and the
contact/role lookup works. If any of those is shaky, every later milestone will
appear to fail for the wrong reason.

**Time:** about 45 minutes.

---

## A1. Create the database

1. https://console.neon.tech → **New Project**.
   - Name: `salesfixr`
   - Postgres version: latest offered
   - Region: pick the one closest to you (you already have projects in `us-east-2`)
2. Open the **SQL Editor** for that project.
3. Paste the entire contents of `db/001_schema.sql`. Run.
   Expect: success, no rows returned. It creates 15 tables.
4. New query. Paste the entire contents of `db/002_seed_demo_clinic.sql`. Run.
5. Verify — run this and check each count:

```sql
SELECT 'tenants'   AS t, count(*) FROM tenants
UNION ALL SELECT 'services',       count(*) FROM services
UNION ALL SELECT 'business_hours', count(*) FROM business_hours
UNION ALL SELECT 'faqs',           count(*) FROM faqs
UNION ALL SELECT 'ai_personas',    count(*) FROM ai_personas
UNION ALL SELECT 'contacts',       count(*) FROM contacts;
```

Expected: `tenants 1`, `services 8`, `business_hours 7`, `faqs 8`,
`ai_personas 3`, `contacts 1`.

6. Confirm the double-booking guard actually exists — this is the constraint the
   whole booking design relies on:

```sql
SELECT conname FROM pg_constraint WHERE conname = 'appointments_no_overlap';
```

Expected: one row. If it's missing, `btree_gist` didn't install — tell me.

7. **Copy your connection string.** Neon dashboard → *Connect*. Take the **pooled**
   one. Save it in `infra/.env` as `SF_DATABASE_URL`.

---

## A2. Start n8n

1. Install **Docker Desktop for Windows**, enable WSL 2, let it finish starting.
2. In PowerShell:

```powershell
cd F:\Agency\Automation_MVP\infra
Copy-Item .env.example .env
notepad .env
```

3. In `.env`, set at minimum:
   - `N8N_BASIC_AUTH_PASSWORD` — something real
   - `N8N_ENCRYPTION_KEY` — a long random string. **Never change it afterwards**, or
     n8n loses the ability to decrypt every credential you've saved.
   - `SF_DATABASE_URL` — from A1.7
   - `SF_TOOL_TOKEN` — another long random string (used from Milestone E)

   Need random strings? In PowerShell:
   ```powershell
   -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 48 | % {[char]$_})
   ```

4. Start it:

```powershell
docker compose up -d
docker compose logs -f n8n
```

Wait for a line saying the editor is ready, then Ctrl+C to stop tailing logs
(the container keeps running).

5. Open **http://localhost:5678**. Log in with the basic-auth user/password from
   `.env`, then create the n8n owner account it asks for.

**Checkpoint:** you can see an empty n8n canvas. If not, stop here and send me
`docker compose logs n8n`.

---

## A3. Connect n8n to Neon

Your connection string looks like:

```
postgresql://neondb_owner:npg_REDACTED@ep-wild-firefly-xxxxxxx-pooler.c-7.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require
             └── user ──┘ └─ pass ─┘ └────────────── host ──────────────────────┘ └ db ┘
```

In n8n: **Credentials → New → Postgres**

| Field | Value |
|---|---|
| Host | everything between `@` and the next `/` — e.g. `ep-wild-firefly-xxxxxxx-pooler.c-7.us-east-2.aws.neon.tech`. Copy **all** of it including any `.c-7.` segment. No `https://`, no `/neondb` |
| Database | `neondb` |
| User | `neondb_owner` |
| Password | the part between `:` and `@` |
| Port | `5432` |
| SSL | **require** — Neon rejects unencrypted connections |
| — | The `?sslmode=...&channel_binding=...` tail is **not** a field. The SSL dropdown covers it; n8n's driver ignores `channel_binding` and Neon accepts that |
| Ignore SSL Issues | off |

Name it **`SalesFixr Neon`**.

Click **Test / Save**. It must say connection successful before you continue.

---

## A4. Build WF-01

New workflow. Name it exactly: **`SF WF-01 Inbound Gateway`**. Tag: `salesfixr`, `core`.

Five nodes, in a straight line. Names matter — n8n expressions reference them by name,
so a typo here breaks a later node.

```
WH Inbound Test → FN Normalize Inbound → PG Resolve Contact And Role
                → PG Insert Inbound Message → RESP Ack
```

---

### Node 1 — `WH Inbound Test`  (Webhook)

| Setting | Value |
|---|---|
| HTTP Method | `POST` |
| Path | `salesfixr/v1/inbound/test` |
| Authentication | None (local only for now) |
| Respond | **Using 'Respond to Webhook' Node** |

n8n shows you two URLs — a **Test URL** (`/webhook-test/...`, only live while you
click "Listen for test event") and a **Production URL** (`/webhook/...`, live when
the workflow is Active). We'll use the Test URL while building.

---

### Node 2 — `FN Normalize Inbound`  (Code)

Mode: **Run Once for All Items**. Language: JavaScript.

This is where a provider-specific payload becomes the standard envelope. Right now
it only handles the `test` channel; Milestone G adds a Messenger branch beside it.

```javascript
// FN Normalize Inbound
// Converts any inbound payload into the SalesFixr standard envelope.
// See docs/02-NAMING-CONVENTIONS.md §5.

// n8n's Code node sandbox does not expose the global `crypto` object, so we
// generate a v4 UUID by hand. Math.random is fine here: correlation_id is a
// debugging trace id, not a secret or a security token.
function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

const out = [];

for (const item of $input.all()) {
  const body = item.json.body ?? item.json;

  // --- test channel (Milestone A) ---------------------------------
  const channel = (body.channel || 'test').toLowerCase();

  // Phones must be E.164. Strip anything that isn't a digit or '+'.
  const rawPhone = String(body.phone ?? '').trim();
  const phone = rawPhone ? rawPhone.replace(/[^\d+]/g, '') : null;

  // Identify the sender. For the test channel we use the phone;
  // Messenger will use the PSID instead.
  const externalContactId = String(
    body.external_contact_id ?? phone ?? 'anonymous'
  );

  out.push({
    json: {
      correlation_id: uuidv4(),
      tenant_slug: body.tenant_slug || $env.SF_DEFAULT_TENANT_SLUG || 'demo_clinic',
      channel,
      external_contact_id: externalContactId,
      external_message_id: body.external_message_id ?? null,
      name: body.name ?? null,
      phone_e164: phone,
      message: String(body.message ?? '').trim(),
      message_type: body.message_type || 'text',
      received_at: new Date().toISOString(),
      reply_to: { channel, address: externalContactId },
    },
  });
}

return out;

**Test it now.** Click *Listen for test event* on the Webhook node, then in a second
PowerShell window:

```powershell
$body = '{"channel":"test","phone":"+1 212 555 0199","name":"Test Patient","message":"I want to book a dental cleaning tomorrow at 2 PM"}'
Invoke-RestMethod -Uri "http://localhost:5678/webhook-test/salesfixr/v1/inbound/test" -Method Post -ContentType "application/json" -Body $body
```

The Code node output should show `phone_e164: "+12125550199"` and a fresh
`correlation_id`. **Don't move on until that's right.**

---

### Node 3 — `PG Resolve Contact And Role`  (Postgres)

| Setting | Value |
|---|---|
| Credential | `SalesFixr Neon` |
| Operation | **Execute Query** |

This single query does find-or-create **and** decides whether the sender is a
patient or the owner. One statement, so there's no race between "check" and "insert",
and no fragile IF branches.

```sql
WITH t AS (
  SELECT id, timezone FROM tenants WHERE slug = $1 AND is_active
),
existing AS (
  SELECT c.id AS contact_id
  FROM contacts c, t
  WHERE c.tenant_id = t.id
    AND (
      c.id IN (
        SELECT ci.contact_id FROM contact_identities ci
        WHERE ci.tenant_id = t.id
          AND ci.channel = $2::channel_t
          AND ci.external_contact_id = $3
      )
      OR (NULLIF($5,'') IS NOT NULL AND c.phone_e164 = $5)
    )
  LIMIT 1
),
new_contact AS (
  INSERT INTO contacts (tenant_id, full_name, phone_e164, preferred_channel, timezone)
  SELECT t.id, NULLIF($4,''), NULLIF($5,''), $2::channel_t, t.timezone
  FROM t
  WHERE NOT EXISTS (SELECT 1 FROM existing)
  RETURNING id
),
resolved AS (
  SELECT contact_id AS id FROM existing
  UNION ALL
  SELECT id FROM new_contact
),
new_identity AS (
  INSERT INTO contact_identities (tenant_id, contact_id, channel, external_contact_id, display_name)
  SELECT t.id, r.id, $2::channel_t, $3, NULLIF($4,'')
  FROM t, resolved r
  ON CONFLICT (tenant_id, channel, external_contact_id) DO NOTHING
  RETURNING contact_id
),
staff AS (
  SELECT su.id AS staff_user_id, su.role
  FROM staff_users su, t
  WHERE su.tenant_id = t.id
    AND su.is_active
    AND su.channel = $2::channel_t
    AND su.external_contact_id = $3
  LIMIT 1
)
SELECT
  t.id                                                   AS tenant_id,
  t.timezone                                             AS tenant_timezone,
  r.id                                                   AS contact_id,
  (SELECT staff_user_id FROM staff)                      AS staff_user_id,
  COALESCE((SELECT role::text FROM staff), 'customer')   AS actor_role,
  NOT EXISTS (SELECT 1 FROM existing)                    AS is_new_contact
FROM t, resolved r;
```

**Query parameters.** Open *Options → Add Option → Query Parameters*, switch the
field to **Expression** mode (the gear icon beside it), and paste this **single
expression** — one line, returning an array:

```
{{ [ $json.tenant_slug, $json.channel, $json.external_contact_id, $json.name ?? '', $json.phone_e164 ?? '' ] }}
```

> ⚠️ **Use the array form, not a comma-separated list.** n8n's Query Parameters
> field splits a plain string on commas. A patient who writes *"Hi, can I book
> Tuesday?"* would split one parameter into two, shifting every `$n` and either
> erroring or — worse — silently writing the wrong value into the wrong column.
> The array expression has no such problem. This bites hardest on node 4, where
> `$7` is the raw message text.
>
> **Never** paste values straight into the SQL. Parameters are what stop a patient's
> message from being executed as SQL.

Array order maps to `$1 … $5` exactly as written above.

Note `actor_role` comes out as `'customer'` unless a `staff_users` row matches.
That's layer 1 of the role system — a database lookup, not anything the message said.

---

### Node 4 — `PG Insert Inbound Message`  (Postgres, Execute Query)

```sql
INSERT INTO conversations (
  tenant_id, contact_id, staff_user_id, actor_role,
  channel, direction, external_message_id, body, message_type
)
VALUES ($1::uuid, $2::uuid, NULLIF($3,'')::uuid, $4::actor_role_t,
        $5::channel_t, 'inbound', NULLIF($6,''), $7, $8)
ON CONFLICT DO NOTHING
RETURNING id, created_at;
```

**Query parameters** — same array form, Expression mode. Note these pull from
**two different nodes**, which is why naming nodes properly mattered:

```
{{ [ $json.tenant_id, $json.contact_id, $json.staff_user_id ?? '', $json.actor_role, $('FN Normalize Inbound').item.json.channel, $('FN Normalize Inbound').item.json.external_message_id ?? '', $('FN Normalize Inbound').item.json.message, $('FN Normalize Inbound').item.json.message_type ] }}
```

### ⚠️ Node 4 needs one setting changed, or the workflow stalls

Go to this node's **Settings** tab and turn **Always Output Data** ON.

Here's why. `ON CONFLICT DO NOTHING` returns **zero rows** when the message is a
duplicate — that's the idempotency guard working correctly. But in n8n, a node that
outputs zero items stops the branch: node 5 never runs, no response is ever sent,
and the caller hangs until it times out. "Always Output Data" makes n8n emit a
single empty item instead, so the branch continues and the caller still gets its
`200 OK`.

(Verified against your database: the second insert with the same
`external_message_id` returns `[]`.)

---

### Node 5 — `RESP Ack`  (Respond to Webhook)

Respond With: **JSON**. Switch the **Response Body** field to **Expression** mode,
then paste:

```
{
  "ok": true,
  "correlation_id": "{{ $('FN Normalize Inbound').first().json.correlation_id }}",
  "contact_id": "{{ $('PG Resolve Contact And Role').first().json.contact_id }}",
  "actor_role": "{{ $('PG Resolve Contact And Role').first().json.actor_role }}",
  "is_new_contact": {{ $('PG Resolve Contact And Role').first().json.is_new_contact }}
}
```

Three details that matter:

- **`.first()`, not `.item`.** `.item` resolves through n8n's paired-item tracking,
  which the empty item from "Always Output Data" breaks — you'd get *"Can't get data
  for expression"* on exactly the duplicate-message case. `.first()` always resolves.
  Each request carries one message, so first *is* the item.
- **`is_new_contact` is unquoted** so it serialises as a real JSON boolean, not the
  string `"false"`.
- **No `=` prefix.** You'll see `"={{ ... }}"` inside exported workflow JSON — that
  `=` is n8n's internal marker meaning "this field is an expression". You don't type
  it; switching the field to Expression mode is what adds it.

Save the workflow.

---

## A5. The acceptance test

Run the same PowerShell command from A4 (with *Listen for test event* active).

**Expected response:**

```json
{
  "ok": true,
  "correlation_id": "some-uuid",
  "contact_id": "some-uuid",
  "actor_role": "customer",
  "is_new_contact": false
}
```

`is_new_contact` is **false** because the seed already created Test Patient with
that phone number. That's the dedupe working.

**Now verify in Neon:**

```sql
SELECT c.full_name, c.phone_e164, ci.channel, ci.external_contact_id
FROM contacts c
LEFT JOIN contact_identities ci ON ci.contact_id = c.id;

SELECT actor_role, channel, direction, body, created_at
FROM conversations ORDER BY created_at DESC LIMIT 5;
```

You should see Test Patient now has a `test` channel identity, and your message
is stored with `actor_role = customer`.

**Then run these three checks:**

1. **New contact** — send the same payload with `"phone":"+12125550123"` and a
   different name. `is_new_contact` should be `true`, and a second contact row appears.

2. **Idempotency** — send the same payload **twice** with
   `"external_message_id":"test-msg-001"` added. The second call must **not** create
   a second `conversations` row. That's `ON CONFLICT DO NOTHING` plus the unique index.

   Both calls must still return `200` with a JSON body. If the second one **hangs**
   instead, you missed **Always Output Data** on node 4 — go back and turn it on.

3. **Role switching** — this is the one that proves the role design. Register the
   first test phone as the owner:

```sql
INSERT INTO staff_users (tenant_id, full_name, role, channel, external_contact_id)
SELECT id, 'Demo Owner', 'owner', 'test', '+12125550199'
FROM tenants WHERE slug = 'demo_clinic';
```

   Send the original payload again. `actor_role` must now come back `"owner"`, and
   `staff_user_id` is no longer `null`. Then clean up so you're a patient again:

```sql
DELETE FROM staff_users WHERE full_name = 'Demo Owner';
DELETE FROM contacts WHERE phone_e164 = '+12125550123';
```

> All three of these queries were executed against your actual `salesfixr` database
> before this doc was finalised, so the SQL is verified — if a check fails, the
> problem is node configuration in n8n, not the SQL.

---

## A6. Commit it

```powershell
cd F:\Agency\Automation_MVP
git init
git add .
git commit -m "Milestone A: schema, seed, WF-01 inbound gateway"
```

In n8n: workflow menu → **Download**, and save the JSON to
`workflows/exports/SF_WF-01_inbound-gateway.json`. Commit that too. Do this after
every milestone — `git log` becomes your build journal for the portfolio write-up.

---

## Done when

- [ ] 15 tables exist in Neon, seed counts match
- [ ] `appointments_no_overlap` constraint present
- [ ] n8n reachable at localhost:5678, Postgres credential tests green
- [ ] Node 3 and node 4 Query Parameters use the **array expression** form
- [ ] Node 4 has **Always Output Data** turned on
- [ ] Test payload returns `ok:true` with a `contact_id`
- [ ] Rows visible in `contacts`, `contact_identities`, `conversations`
- [ ] Duplicate `external_message_id` does not double-insert
- [ ] Adding a `staff_users` row flips `actor_role` to `owner`

**Next:** Milestone B — the safety gate (opt-out, quiet hours, rate limits) and
audit logging. Tell me when A is green, or paste the error if it isn't.
