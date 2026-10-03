# SalesFixr — Claude Build Context
## Dental Clinic AI Booking Automation — n8n Portfolio Project

Use this document as the master context for building my SalesFixr portfolio project in Claude.

---

# 1. PROJECT GOAL

I am building a portfolio-quality automation called **SalesFixr** for a fictional dental clinic.

The final system should handle:

Patient message/call
→ receive event
→ normalize data
→ find/create patient
→ enforce deterministic safety/business rules
→ AI understands intent
→ AI uses tools
→ check appointment availability
→ book/reschedule/cancel
→ save data
→ send patient confirmation
→ notify clinic
→ later send reminders
→ show data in a dashboard.

This is initially a **portfolio/demo project using free, local, or trial resources**.

Later, when selling the product, I will replace the free/test providers with paid production providers without redesigning the core architecture.

---

# 2. IMPORTANT BUILD PHILOSOPHY

The project must be designed so that:

**AI decides what to say/understand.**
**Backend/n8n deterministic logic decides what is allowed.**

Never let the LLM decide:
- whether marketing consent exists
- whether a patient opted out
- whether DNC applies
- whether quiet hours allow a message
- whether an appointment is actually available
- whether an appointment was successfully booked
- whether a message is legally allowed to send.

The LLM can request an action.
The workflow validates and executes the action.

Example:

Patient:
"I want a cleaning tomorrow at 2."

AI:
intent=booking, service=cleaning, date=tomorrow, time=14:00

n8n:
check patient → safety → calendar → availability → booking

Only after the calendar/database operation succeeds should the AI tell the patient the appointment is booked.

---

# 3. PORTFOLIO STACK — FREE FIRST

Use these for the portfolio version wherever practical:

### Automation
- n8n self-hosted/local
- Docker if convenient

Official:
https://docs.n8n.io/

### AI
Use **Ollama locally**, not a paid LLM API initially.

https://ollama.com/
https://github.com/ollama/ollama

Choose a reasonably capable local instruct/chat model appropriate for the developer's hardware.

Later replace Ollama with:
- OpenAI
- Google Gemini
- Anthropic
- another production model

The AI provider must be treated as a replaceable component.

### Database
PostgreSQL.

https://www.postgresql.org/
https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.postgres/

For the portfolio, local PostgreSQL via Docker is preferred.

### Calendar
Google Calendar API / n8n Google Calendar node.

https://developers.google.com/calendar/api
https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.googlecalendar/

### Owner notification
Use Telegram Bot or Gmail for the portfolio.

Telegram:
https://core.telegram.org/bots/api
https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.telegram/

Gmail:
https://developers.google.com/gmail/api
https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.gmail/

### Messaging — portfolio/testing
Use Meta test/developer resources where available.

Meta developer:
https://developers.facebook.com/

WhatsApp Cloud API:
https://developers.facebook.com/docs/whatsapp/cloud-api/

Messenger Platform:
https://developers.facebook.com/docs/messenger-platform/

For SMS, Twilio trial/testing can be used where available:
https://www.twilio.com/docs
https://www.twilio.com/docs/usage/tutorials/how-to-use-your-free-trial-account

Later use production Twilio/Meta messaging.

### Voice
For the portfolio, use a trial/free developer allowance if available, or build the voice workflow against a webhook/mock input first.

Twilio Voice:
https://www.twilio.com/docs/voice

The voice layer must remain replaceable.

### Public webhook during local development
Cloudflare Tunnel:
https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/

Alternative:
https://ngrok.com/docs/

Do not make the application depend permanently on a temporary tunnel URL.

---

# 4. HIGH-LEVEL ARCHITECTURE

```text
                    PATIENT
                       |
          +------------+-------------+
          |            |             |
       WhatsApp    Messenger        SMS
          |            |             |
          +------------+-------------+
                       |
                  WEBHOOKS
                       |
                NORMALIZE DATA
                       |
                FIND CONTACT
                       |
               CREATE IF NEEDED
                       |
                 SAFETY GATE
                       |
             +---------+---------+
             |                   |
           BLOCK                ALLOW
             |                   |
        Policy Reply          AI AGENT
                                  |
                            ACTION ROUTER
                                  |
            +-----------+---------+----------+
            |           |         |          |
          BOOK       RESCHEDULE  CANCEL      FAQ
            |           |         |          |
            +-----------+---------+----------+
                                  |
                         CALENDAR / PMS
                                  |
                              POSTGRES
                                  |
                       +----------+----------+
                       |                     |
                PATIENT MESSAGE       CLINIC ALERT
                       |
                    REMINDERS
                       |
                  DASHBOARD
```

---

# 5. DO NOT BUILD ONE GIANT WORKFLOW

Create multiple n8n workflows.

## WF-01 — Inbound Message Handler
Receives SMS/WhatsApp/Messenger/website/voice events and normalizes them.

## WF-02 — AI Conversation / Intent
Processes normalized input and determines intent.

## WF-03 — Booking Operations
Availability, hold, confirmation, booking, rescheduling, cancellation.

## WF-04 — Appointment Reminders
Scheduled workflow that finds upcoming appointments and sends reminders.

## WF-05 — Voice Handler
Inbound voice call → transcription/AI → booking tools → voice response.

## WF-06 — Human Escalation
Escalation to clinic staff and owner notification.

## WF-07 — Daily/Weekly Clinic Report
Appointment and automation summary.

## WF-08 — Error/Audit Logger
Centralized logging of workflow failures and important actions.

For the first milestone, only build WF-01 + a minimal booking path.

---

# 6. FIRST MILESTONE

Do NOT start with WhatsApp, Messenger, voice, or complex dashboard.

First make this work:

```text
Webhook
  ↓
Normalize
  ↓
PostgreSQL: find/create contact
  ↓
Safety Gate
  ↓
Ollama
  ↓
Intent
  ↓
Switch
  ↓
Google Calendar
  ↓
Save booking in PostgreSQL
  ↓
Telegram notification
  ↓
Return/send confirmation
```

Test input:

```json
{
  "channel": "test",
  "phone": "01700000000",
  "message": "I want to book a dental cleaning tomorrow at 2 PM"
}
```

Expected behavior:

1. Receive request.
2. Normalize it.
3. Find or create contact.
4. Check deterministic rules.
5. Ask local Ollama to understand intent.
6. Extract:
   - intent=booking
   - service=cleaning
   - date=tomorrow
   - preferred_time=14:00
7. Check Google Calendar.
8. If unavailable, provide available alternatives.
9. If available, create appointment.
10. Save appointment in PostgreSQL.
11. Notify clinic via Telegram.
12. Return confirmation.

---

# 7. STANDARD INTERNAL MESSAGE FORMAT

Every inbound channel should eventually become approximately:

```json
{
  "tenant_id": "demo_clinic",
  "channel": "whatsapp",
  "external_contact_id": "provider-specific-id",
  "phone": "+123456789",
  "name": "John Smith",
  "message": "Can I book a cleaning tomorrow?",
  "message_type": "text",
  "external_message_id": "abc123",
  "timestamp": "2026-09-29T12:00:00Z"
}
```

The rest of the system should work with this normalized structure instead of provider-specific payloads.

---

# 8. DATABASE

Use PostgreSQL.

Initial tables:

## contacts

```sql
id
tenant_id
name
phone
email
preferred_channel
timezone
marketing_consent
appointment_consent
opted_out
created_at
updated_at
```

## conversations

```sql
id
tenant_id
contact_id
channel
external_message_id
direction
message
message_type
created_at
```

## appointments

```sql
id
tenant_id
contact_id
service
start_time
end_time
status
calendar_event_id
source_channel
created_at
updated_at
```

## consents

```sql
id
tenant_id
contact_id
channel
purpose
consent
source
captured_at
revoked_at
```

## audit_logs

```sql
id
tenant_id
contact_id
workflow
action
status
details
created_at
```

## clinic_settings

```sql
id
tenant_id
clinic_name
timezone
business_hours
services
appointment_durations
reminder_settings
quiet_hours
```

Use `tenant_id` from the beginning even though the portfolio has only one demo clinic. This makes the architecture ready for multiple clients.

---

# 9. DATA RETENTION FOR PORTFOLIO DESIGN

Design the system around structured data.

Suggested conceptual retention:

Permanent/long-term:
- contact identity
- consent/opt-out status
- structured appointment records
- audit records as appropriate

Limited retention:
- detailed conversation messages
- raw webhook payloads
- voice transcripts

Do not store unnecessary sensitive information.

For a real dental deployment, compliance/privacy requirements must be reviewed separately before production use.

---

# 10. WF-01 — INBOUND MESSAGE HANDLER

### Node sequence

```text
Webhook Trigger
↓
Set / Code — Normalize Data
↓
PostgreSQL — Find Contact
↓
IF — Contact Exists?
    ├── YES → Continue
    └── NO → PostgreSQL Create Contact
↓
PostgreSQL — Save Incoming Message
↓
Execute Workflow — AI Conversation
```

Potential webhook inputs:
- WhatsApp
- Messenger
- SMS
- website chat/form
- voice provider

Each should be converted to the same internal format.

---

# 11. SAFETY GATE

Build deterministic checks with IF/Code nodes.

Order:

```text
Is contact opted out?
        ↓
Is this marketing?
        ↓
Does marketing consent exist?
        ↓
DNC check
        ↓
Quiet-hours check
        ↓
Frequency/rate limit
        ↓
Client spending limit
        ↓
ALLOW
```

If blocked:

```text
Safety Gate
↓
Prepare safe response
↓
Send through original channel
↓
Audit log
↓
End
```

Never ask the LLM whether something is allowed.

---

# 12. AI AGENT

The AI receives:
- normalized patient message
- relevant contact information
- clinic information
- current conversation context
- available tools

The AI should be instructed:

```text
You are an AI receptionist for a dental clinic.

You may:
- answer basic clinic FAQs
- understand appointment requests
- check availability
- book appointments
- reschedule
- cancel
- collect basic booking information
- escalate to a human

You must:
- never diagnose
- never provide medical treatment advice
- never claim a booking is completed unless the booking tool confirms success
- never invent appointment availability
- never invent clinic policy
- ask for missing booking information
- escalate medical/emergency questions to clinic staff
```

---

# 13. STRUCTURED AI OUTPUT

Prefer structured JSON over free-form AI output.

Example:

```json
{
  "intent": "booking",
  "service": "dental_cleaning",
  "date": "2026-09-30",
  "preferred_time": "14:00",
  "patient_name": "John Smith",
  "needs_human": false,
  "response_needed": true
}
```

Possible intents:

```text
booking
reschedule
cancel
faq
pricing
hours
insurance
human
medical_question
unknown
```

---

# 14. ACTION ROUTER

Use n8n Switch.

```text
booking → Booking Workflow
reschedule → Booking Workflow
cancel → Booking Workflow
faq → FAQ response
pricing → Knowledge/FAQ
hours → Clinic settings
insurance → FAQ/human if uncertain
medical_question → Human escalation
human → Human escalation
unknown → Clarification
```

---

# 15. BOOKING WORKFLOW

```text
Receive booking request
↓
Validate service
↓
Get appointment duration
↓
Calculate requested time window
↓
Google Calendar: Get Events
↓
Determine availability
↓
IF available?
   ├── NO → Prepare alternatives
   └── YES
          ↓
       Hold/lock strategy
          ↓
       Ask patient confirmation
          ↓
       Confirmed?
        /       \
       NO       YES
       ↓         ↓
Release       Google Calendar
hold          Create Event
                 ↓
             PostgreSQL
                 ↓
             Audit Log
                 ↓
          Confirmation message
                 ↓
          Clinic notification
```

For the first portfolio implementation, a simple availability check + immediate booking is acceptable.

Later add a proper temporary slot-hold/locking mechanism to prevent race-condition double bookings.

---

# 16. GOOGLE CALENDAR

Google Calendar is the initial scheduling source.

Responsibilities:
- get events
- determine free time
- create appointment
- update appointment
- cancel appointment

PostgreSQL stores the SalesFixr record and `calendar_event_id`.

Calendar remains the actual scheduling calendar.

---

# 17. OUTBOUND MESSAGE ROUTER

After an action, route the reply based on `channel`.

```text
Switch channel
|
+-- whatsapp → Meta WhatsApp
+-- messenger → Meta Messenger
+-- sms → Twilio
+-- test → Webhook Response
```

This is important because the same AI/booking logic should not be duplicated for every channel.

---

# 18. OWNER NOTIFICATION

For portfolio:

```text
Booking confirmed
↓
Telegram
```

Example:

```text
🦷 New Appointment

Patient: John Smith
Service: Dental Cleaning
Time: Sep 30, 2:00 PM
Channel: WhatsApp

Calendar Event: abc123
```

Do not expose unnecessary sensitive information in real notification channels.

For production dental deployments, design notifications carefully around applicable privacy requirements.

---

# 19. REMINDER WORKFLOW

Separate n8n workflow:

```text
Schedule Trigger
↓
PostgreSQL query
↓
Find appointments due for reminder
↓
IF reminder already sent?
↓
Safety/eligibility check
↓
Send reminder
↓
Update appointment/reminder status
```

Example:

24 hours before:

> "Reminder: you have an appointment with SmileCare Dental tomorrow at 2:00 PM."

For production, messaging consent/channel rules must be respected.

---

# 20. VOICE WORKFLOW

Portfolio architecture:

```text
Voice Provider
↓
Webhook
↓
Speech-to-text / provider transcription
↓
Normalize
↓
AI Agent
↓
Booking tools
↓
Calendar
↓
PostgreSQL
↓
Voice response
```

Start with inbound calls.

Do not start with automated promotional outbound calls.

The voice provider should be replaceable.

---

# 21. DASHBOARD

Do not build the full dashboard first.

After the automation works, build a simple web/PWA dashboard.

Pages:

### Inbox
- conversations
- AI/human status
- takeover

### Bookings
- today
- upcoming
- cancelled
- source

### Contacts
- contact info
- consent
- opt-out
- appointment history

### Analytics
- conversations
- bookings
- conversion
- escalations
- source channel

### Settings
- clinic hours
- services
- appointment duration
- reminder settings
- AI instructions

---

# 22. FREE PORTFOLIO → PAID PRODUCTION SWAPS

Architecture must make these easy:

| Portfolio | Production |
|---|---|
| Ollama | OpenAI/Gemini/Anthropic/etc. |
| Local PostgreSQL | Managed PostgreSQL |
| Meta test resources | Production Meta Business setup |
| Twilio trial/test | Production Twilio |
| Telegram | Email/SMS/dashboard alerts |
| Google Calendar | Calendar/PMS integration |
| Local n8n | Hosted/production n8n/backend |
| Cloudflare Tunnel | Production domain/webhooks |
| Mock/test voice | Production voice provider |

Do not hard-code providers deep inside the business logic.

---

# 23. N8N NODE TYPES TO LEARN

Prioritize these:

1. Webhook
2. Respond to Webhook
3. Set / Edit Fields
4. Code
5. IF
6. Switch
7. PostgreSQL
8. Google Calendar
9. Telegram
10. Gmail
11. HTTP Request
12. Schedule Trigger
13. Wait
14. Execute Workflow
15. AI Agent / model node
16. Error Trigger

Use HTTP Request when a native n8n node is unavailable.

---

# 24. HOW CLAUDE SHOULD HELP ME

Do NOT dump the entire project at once.

Build it incrementally.

For each stage:

1. Explain what we are building.
2. Tell me exactly which n8n node to add.
3. Tell me the node name.
4. Tell me which fields/settings to enter.
5. Tell me which credential/API connection is required.
6. Tell me what input data should look like.
7. Tell me what output should look like.
8. Tell me how to test the node.
9. Wait for my confirmation/error before moving to the next major stage.

I am a developer but I want this project built practically, not theoretically.

When giving n8n expressions, use real n8n expression syntax.

Do not invent node names or settings.

If n8n's current UI has changed, tell me the current equivalent rather than assuming an old interface.

---

# 25. IMPORTANT DEVELOPMENT RULE

Do not connect 5 external APIs at once.

Build:

### Milestone A
Webhook → PostgreSQL

### Milestone B
Webhook → PostgreSQL → Safety

### Milestone C
Safety → Ollama

### Milestone D
Ollama → Switch

### Milestone E
Switch → Google Calendar

### Milestone F
Calendar → PostgreSQL → Telegram

### Milestone G
Replace test webhook with real messaging channel

### Milestone H
Reminders

### Milestone I
Voice

### Milestone J
Dashboard

---

# 26. TEST CASES

The system must eventually handle:

### Booking
"I want to book a cleaning tomorrow."

### Specific time
"Can I come tomorrow at 3 PM?"

### Alternative
"3 doesn't work. What about 5?"

### Reschedule
"Can I move my appointment to Friday?"

### Cancel
"I need to cancel my appointment."

### FAQ
"Are you open Saturday?"

### Pricing
"How much is a cleaning?"

### New patient
"I'm a new patient. Can I book?"

### Human escalation
"Can I speak to someone?"

### Medical question
"My tooth is swollen and painful. What should I do?"

Expected: do not diagnose; escalate appropriately.

### Opt out
"STOP"

Expected: update opt-out state and prevent applicable future messages.

### Unknown
"Do you have the blue thing?"

Expected: ask for clarification rather than hallucinating.

### Double booking
Two requests attempt the same time.

Expected: system prevents two successful bookings.

---

# 27. MULTI-TENANCY

Even though this is one demo clinic, include:

```text
tenant_id
```

in all business tables.

Concept:

```text
SalesFixr
|
+-- Clinic A
|    +-- contacts
|    +-- bookings
|    +-- settings
|
+-- Clinic B
|    +-- contacts
|    +-- bookings
|    +-- settings
```

This is important because the eventual product is SaaS/agency-oriented.

---

# 28. FUTURE DENTAL PMS

Do not implement these initially.

Keep the architecture ready for:

- NexHealth
- Dentrix
- Eaglesoft
- Open Dental

Future architecture:

```text
Booking Service
      |
      +-- Google Calendar
      +-- Cal.com
      +-- NexHealth
      +-- Dentrix
      +-- Other PMS
```

The AI should never care which scheduling backend is used.

---

# 29. FUTURE SPA/SALON EDITION

Later create a separate product configuration:

Clinic Edition:
- SMS
- phone
- web
- stronger privacy/compliance controls

Spa/Salon Edition:
- SMS
- WhatsApp
- Instagram
- web
- voice
- marketing automation

Do not mix these requirements into the first dental MVP.

---

# 30. FIRST CLAUDE SESSION PROMPT

Paste this after giving Claude the entire document:

---

You are helping me build **SalesFixr**, a portfolio-quality AI dental clinic booking automation in n8n.

I have attached/provided the master project context above.

I want you to act as my **n8n implementation engineer and tutor**.

We are building the system incrementally.

Start ONLY with **Milestone A: Webhook → Normalize → PostgreSQL**.

Do not build the entire project yet.

First:
1. Tell me exactly what software I should install.
2. Help me start n8n locally.
3. Help me start PostgreSQL.
4. Create the initial SalesFixr database.
5. Create the `contacts`, `conversations`, `appointments`, `consents`, `audit_logs`, and `clinic_settings` tables.
6. Create the first n8n workflow:
   Webhook → Normalize Data → PostgreSQL Find Contact → IF → Create Contact/Continue → Save Message.
7. Give me the exact n8n node order.
8. Give me exact node configuration.
9. Give me SQL where needed.
10. Give me a test JSON payload.
11. Tell me exactly what output I should see.
12. Do not move to Ollama or Google Calendar until this milestone works.

Use free/local resources whenever possible.

Do not assume paid API access.

When we eventually add external APIs, use their official documentation and tell me exactly where credentials are obtained.

Never invent API keys, credentials, endpoint behavior, or n8n settings.

After each major step, wait for my result/error before continuing.

---

# 31. OFFICIAL DOCUMENTATION BOOKMARKS

n8n:
https://docs.n8n.io/

n8n PostgreSQL:
https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.postgres/

n8n Google Calendar:
https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.googlecalendar/

n8n Telegram:
https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.telegram/

n8n Gmail:
https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.gmail/

n8n Webhook:
https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.webhook/

PostgreSQL:
https://www.postgresql.org/docs/

Ollama:
https://ollama.com/
https://github.com/ollama/ollama

Google Calendar API:
https://developers.google.com/calendar/api

Meta Developers:
https://developers.facebook.com/

Meta WhatsApp:
https://developers.facebook.com/docs/whatsapp/cloud-api/

Meta Messenger:
https://developers.facebook.com/docs/messenger-platform/

Twilio:
https://www.twilio.com/docs

Twilio Voice:
https://www.twilio.com/docs/voice

Telegram Bot API:
https://core.telegram.org/bots/api

Cloudflare Tunnel:
https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/

---

# 32. SUCCESS CONDITION FOR THE FIRST DEMO

A portfolio evaluator should be able to see:

1. Patient sends:
   "Can I book a cleaning tomorrow at 2?"

2. n8n receives it.

3. PostgreSQL finds/creates patient.

4. Safety rules execute.

5. Ollama understands the request.

6. Google Calendar is checked.

7. Appointment is created.

8. PostgreSQL stores the booking.

9. Telegram tells the clinic owner.

10. Patient receives:
   "You're booked for tomorrow at 2 PM."

11. The dashboard/database can show the appointment.

That is the first complete SalesFixr demo.

---

# 33. CORE PRINCIPLE

The final architecture must always preserve:

**Channels are replaceable.**
**AI providers are replaceable.**
**Calendar/PMS providers are replaceable.**
**Notification providers are replaceable.**

The stable core is:

```text
NORMALIZE
→ CONTACT
→ SAFETY
→ AI
→ ACTION
→ BOOKING
→ DATABASE
→ NOTIFICATION
```

This is SalesFixr.
