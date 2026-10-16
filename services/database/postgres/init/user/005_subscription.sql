-- ============================================================================
-- 005_subscription.sql
-- app.subscription (current state) + app.subscription_event (audit trail).
-- ============================================================================

BEGIN;

CREATE TABLE app.subscription (
  subscription_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                   uuid REFERENCES app.account(user_id) ON DELETE SET NULL,
  plan                      text NOT NULL,
  status                    text NOT NULL CHECK (status IN
                              ('active','past_due','canceled','expired','trialing')),
  provider                  text NOT NULL CHECK (provider IN
                              ('app_store','play_store','stripe')),
  provider_customer_id      text,
  provider_subscription_id  text,
  current_period_start      timestamptz,
  current_period_end        timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX app_subscription_user_idx   ON app.subscription (user_id);
CREATE INDEX app_subscription_active_idx ON app.subscription (user_id) WHERE status = 'active';
CREATE UNIQUE INDEX app_subscription_provider_sub_uidx
  ON app.subscription (provider, provider_subscription_id)
  WHERE provider_subscription_id IS NOT NULL;

CREATE TRIGGER trg_subscription_touch BEFORE UPDATE ON app.subscription
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.subscription_event (
  event_id           bigserial PRIMARY KEY,
  subscription_id    uuid NOT NULL REFERENCES app.subscription(subscription_id) ON DELETE RESTRICT,
  provider           text NOT NULL CHECK (provider IN ('app_store','play_store','stripe')),
  provider_event_id  text NOT NULL,
  event_type         text NOT NULL,
  payload            jsonb NOT NULL,
  occurred_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_event_id)
);

CREATE INDEX app_subscription_event_sub_idx
  ON app.subscription_event (subscription_id, occurred_at DESC);

-- Pro check. Wrapped in a function so call sites never change when
-- business accounts are added later (they'll extend this function body).
CREATE OR REPLACE FUNCTION app.is_pro(p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM app.subscription
    WHERE user_id = p_user_id AND status IN ('active','trialing')
  );
$$;

COMMENT ON FUNCTION app.is_pro(uuid) IS
  'Canonical Pro check. Update this function when business accounts arrive.';

COMMIT;