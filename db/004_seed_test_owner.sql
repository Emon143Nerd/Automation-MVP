-- =====================================================================
-- 004 — Test-channel owner (Milestone C)
--
-- Registers a fake phone number as the clinic OWNER on the 'test'
-- channel, so the acceptance test can send the same sentence as a
-- patient (+12125550199) and as the owner (+15550000001) and get two
-- different personas.
--
-- On the test channel, FN Normalize Inbound uses the phone number as
-- external_contact_id, so that's what we match on.
--
-- Safe to re-run. In Milestone G you add your real Messenger PSID as a
-- second owner row; this one can stay for local testing.
-- =====================================================================

INSERT INTO staff_users (tenant_id, full_name, role, channel, external_contact_id, phone_e164)
SELECT t.id, 'Demo Owner', 'owner', 'test', '+15550000001', '+15550000001'
FROM tenants t
WHERE t.slug = 'demo_clinic'
  AND NOT EXISTS (
    SELECT 1 FROM staff_users su
    WHERE su.tenant_id = t.id
      AND su.channel = 'test'
      AND su.external_contact_id = '+15550000001'
  );
