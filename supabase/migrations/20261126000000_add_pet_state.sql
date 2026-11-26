-- Cross-device pet stats. The pet's on-screen position and visibility remain
-- device-local in the client; only growth/health state is stored here.
BEGIN;
CREATE TABLE IF NOT EXISTS public.pet_state (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  state jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.pet_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage their own pet state" ON public.pet_state;
CREATE POLICY "Users manage their own pet state"
  ON public.pet_state
  FOR ALL
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

REVOKE ALL ON public.pet_state FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pet_state TO authenticated;
COMMIT;
