-- Momentum schema verification. Every row should show ok = true.
SELECT check_name, ok, detail
FROM (
  SELECT 'function commit_storage_operation' AS check_name,
         to_regprocedure('public.commit_storage_operation(text, jsonb)') IS NOT NULL AS ok,
         coalesce(to_regprocedure('public.commit_storage_operation(text, jsonb)')::text, 'missing') AS detail
  UNION ALL
  SELECT 'function create_rsip_nodes_with_meta',
         to_regprocedure('public.create_rsip_nodes_with_meta(text, jsonb, jsonb)') IS NOT NULL,
         coalesce(to_regprocedure('public.create_rsip_nodes_with_meta(text, jsonb, jsonb)')::text, 'missing')
  UNION ALL
  SELECT 'function complete_task_with_betting',
         to_regprocedure('public.complete_task_with_betting(uuid, boolean, text)') IS NOT NULL,
         coalesce(to_regprocedure('public.complete_task_with_betting(uuid, boolean, text)')::text, 'missing')
  UNION ALL
  SELECT 'function get_sync_fingerprint',
         to_regprocedure('public.get_sync_fingerprint()') IS NOT NULL,
         coalesce(to_regprocedure('public.get_sync_fingerprint()')::text, 'missing')
  UNION ALL
  SELECT 'table rsip_atomic_intents',
         to_regclass('public.rsip_atomic_intents') IS NOT NULL,
         coalesce(to_regclass('public.rsip_atomic_intents')::text, 'missing')
  UNION ALL
  SELECT 'table storage_operation_commits',
         to_regclass('public.storage_operation_commits') IS NOT NULL,
         coalesce(to_regclass('public.storage_operation_commits')::text, 'missing')
  UNION ALL
  SELECT 'table completed_session_receipts',
         to_regclass('public.completed_session_receipts') IS NOT NULL,
         coalesce(to_regclass('public.completed_session_receipts')::text, 'missing')
  UNION ALL
  SELECT 'table exception_rule_sets',
         to_regclass('public.exception_rule_sets') IS NOT NULL,
         coalesce(to_regclass('public.exception_rule_sets')::text, 'missing')
  UNION ALL
  SELECT 'table pet_state',
         to_regclass('public.pet_state') IS NOT NULL,
         coalesce(to_regclass('public.pet_state')::text, 'missing')
  UNION ALL
  SELECT 'column completion_history.metadata',
         EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'completion_history'
             AND column_name = 'metadata'
         ),
         'completion_history.metadata'
  UNION ALL
  SELECT 'pet_state RLS policy',
         EXISTS (
           SELECT 1 FROM pg_policies
           WHERE schemaname = 'public'
             AND tablename = 'pet_state'
             AND policyname = 'Users manage their own pet state'
         ),
         'Users manage their own pet state'
) checks
ORDER BY check_name;
