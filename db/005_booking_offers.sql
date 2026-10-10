-- =====================================================================
-- 005 — Booking offers (Milestone F)
--
-- When the availability tool offers a patient one or more times, WF-02
-- stores exactly those slots here. When the patient answers "yes" or
-- "the 1:30 one", the router books ONLY if their choice matches a slot
-- in this row, so a time the model hallucinated can never be booked.
--
-- One open offer per patient at a time: a new offer expires the old one.
-- Offers go stale after 30 minutes; the patient then gets a fresh check.
-- =====================================================================

CREATE TABLE IF NOT EXISTS booking_offers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL REFERENCES tenants(id)  ON DELETE CASCADE,
  contact_id      uuid NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  service_code    text NOT NULL,
  offer_date      date NOT NULL,                      -- clinic-local date of the slots
  day_label       text,                               -- 'Monday 12 October', for replies
  slots           jsonb NOT NULL,                     -- [{start, end, local, label}], start/end UTC
  status          text NOT NULL DEFAULT 'open'
                  CHECK (status IN ('open', 'used', 'expired')),
  correlation_id  text,                               -- the message that produced the offer
  expires_at      timestamptz NOT NULL DEFAULT now() + interval '30 minutes',
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS booking_offers_open_idx
  ON booking_offers (tenant_id, contact_id, created_at DESC)
  WHERE status = 'open';

COMMENT ON TABLE booking_offers IS
  'Slots offered to a patient by check_availability. The router books only a slot listed here.';
