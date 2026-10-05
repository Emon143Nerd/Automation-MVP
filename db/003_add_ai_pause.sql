-- =====================================================================
-- 003 — Human escalation support
--
-- When a patient asks for a human (or asks a medical question), the AI
-- must stop replying to that thread until staff release it. Without a
-- column to record that, "escalate to a human" is just a notification
-- and the bot keeps talking over the staff member.
--
-- Added in Milestone B because the safety gate reads it; actually set
-- by WF-06 in a later milestone.
-- =====================================================================

ALTER TABLE contacts
  ADD COLUMN IF NOT EXISTS ai_paused_until timestamptz;

COMMENT ON COLUMN contacts.ai_paused_until IS
  'While > now(), the safety gate blocks all AI replies to this contact. '
  'Set by WF-06 on escalation; cleared by staff or by expiry.';

CREATE INDEX IF NOT EXISTS contacts_ai_paused_idx
  ON contacts (tenant_id, ai_paused_until)
  WHERE ai_paused_until IS NOT NULL;
