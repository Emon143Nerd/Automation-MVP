# SalesFixr

AI booking automation for a dental clinic, built in n8n.
A patient messages the clinic's Facebook Page; the system understands them, checks
real availability, books the appointment, and tells the owner — with every decision
that matters made by deterministic code, not by the model.

**Status:** MVP build in progress. Currently at **Milestone A**.

---

## Read these in order

| File | What it is |
|---|---|
| [docs/00-MASTER-PLAN.md](docs/00-MASTER-PLAN.md) | **Start here.** Stack, milestones, hard rules |
| [docs/01-ACCOUNTS-AND-FREE-TIERS.md](docs/01-ACCOUNTS-AND-FREE-TIERS.md) | Click-by-click account setup, all free |
| [docs/02-NAMING-CONVENTIONS.md](docs/02-NAMING-CONVENTIONS.md) | Node names, webhook paths, DB naming |
| [docs/03-AI-ROLES-AND-PERSONAS.md](docs/03-AI-ROLES-AND-PERSONAS.md) | How owner vs customer awareness works |
| [docs/04-TOOL-API.md](docs/04-TOOL-API.md) | The tool endpoint contract (chat + voice share it) |
| [docs/05-MILESTONE-A.md](docs/05-MILESTONE-A.md) | **Current task.** Step-by-step build of the first milestone |
| [docs/ORIGINAL-CONTEXT.md](docs/ORIGINAL-CONTEXT.md) | The original brief, kept for reference |

## Layout

```
db/         numbered SQL migrations, run in order
docs/       the plan
infra/      docker-compose + .env.example
workflows/exports/   n8n workflow JSON, committed after each milestone
assets/     architecture diagrams
```

## Quick start

```bash
# 1. database
#    run db/001_schema.sql then db/002_seed_demo_clinic.sql in the Neon SQL editor

# 2. n8n
cd infra
cp .env.example .env     # then edit it
docker compose up -d
# open http://localhost:5678
```

## The one rule

**The AI decides what to say. The workflow decides what is allowed.**

The model never writes to the database, never judges consent, never invents
availability, and never announces a booking the database hasn't confirmed.
