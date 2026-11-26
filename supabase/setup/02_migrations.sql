-- Momentum complete schema upgrade: migrations after the 2026-02-11 baseline.
-- Run 01_baseline.sql first, then this file, then 03_verify.sql.

-- ===== 20260223000000_migrate_points_columns_to_bigint.sql =====
-- ========================================
-- Migrate Points Columns from integer to bigint
-- Date: 2026-02-23
-- Purpose: Fix "integer out of range" errors when points exceed ~2.1 billion
--
-- Root cause: PostgreSQL integer (int4) max = 2,147,483,647.
-- Users with points near this limit trigger overflow in:
--   1. place_task_bet: reward_payout := p_bet_amount * 2
--   2. settle_task_bet: new_points_total := user_current_points + payout_amount
--   3. Various CHECK constraints and INSERT/UPDATE operations
--
-- Solution: Migrate all points-related columns to bigint (int8, max ~9.2e18)
-- and rebuild all PL/pgSQL functions that declare integer variables for points.
-- ========================================

-- ============================================================
-- STEP 1: ALTER TABLE COLUMNS from integer to bigint
-- ============================================================
-- PostgreSQL ALTER COLUMN TYPE bigint is safe for integer -> bigint
-- (no data loss, implicit cast exists). CHECK constraints are preserved.

-- user_points
ALTER TABLE user_points
  ALTER COLUMN total_points TYPE bigint;

-- task_bets
ALTER TABLE task_bets
  ALTER COLUMN bet_amount TYPE bigint,
  ALTER COLUMN points_before TYPE bigint,
  ALTER COLUMN points_after TYPE bigint,
  ALTER COLUMN potential_payout TYPE bigint,
  ALTER COLUMN actual_payout TYPE bigint;

-- point_transactions
ALTER TABLE point_transactions
  ALTER COLUMN points_change TYPE bigint,
  ALTER COLUMN points_before TYPE bigint,
  ALTER COLUMN points_after TYPE bigint;

-- user_settings (bet limits)
ALTER TABLE user_settings
  ALTER COLUMN daily_bet_limit TYPE bigint,
  ALTER COLUMN max_single_bet TYPE bigint;

-- daily_checkins (for consistency)
ALTER TABLE daily_checkins
  ALTER COLUMN points_earned TYPE bigint;


-- ============================================================
-- STEP 2: Rebuild place_task_bet with bigint parameter
-- ============================================================
-- Must DROP old integer-signature function, then CREATE with bigint.

DROP FUNCTION IF EXISTS place_task_bet(uuid, uuid, integer, uuid) CASCADE;
DROP FUNCTION IF EXISTS place_task_bet(uuid, uuid, integer) CASCADE;
DROP FUNCTION IF EXISTS place_task_bet(uuid, uuid, bigint, uuid) CASCADE;
DROP FUNCTION IF EXISTS place_task_bet(uuid, uuid, bigint) CASCADE;

CREATE OR REPLACE FUNCTION place_task_bet(
  p_user_id uuid,
  p_session_id uuid,
  p_bet_amount bigint,
  p_write_session_token uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  user_current_points bigint := 0;
  session_exists boolean := false;
  session_chain_id uuid;
  existing_bet task_bets;
  gambling_enabled boolean := false;
  daily_spent bigint := 0;
  user_daily_limit bigint;
  user_max_bet bigint;
  new_bet_id uuid;
  reward_payout bigint;
  result jsonb;
BEGIN
  -- Log function entry for debugging
  INSERT INTO audit_logs (user_id, action, details, created_at)
  VALUES (
    p_user_id,
    'place_task_bet_v3_bigint_called',
    jsonb_build_object(
      'session_id', p_session_id,
      'bet_amount', p_bet_amount,
      'write_session_token', COALESCE(p_write_session_token::text, 'null'),
      'function_signature', 'place_task_bet(uuid,uuid,bigint,uuid DEFAULT NULL)'
    ),
    now()
  );

  -- Calculate reward payout: 2x bet amount (bet return + equal reward)
  reward_payout := p_bet_amount * 2;

  -- Verify the user exists and is the authenticated user
  IF p_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only place bets for yourself';
  END IF;

  -- Validate bet amount
  IF p_bet_amount <= 0 THEN
    RAISE EXCEPTION 'Bet amount must be greater than 0';
  END IF;

  -- Check if gambling mode is enabled
  SELECT gambling_mode_enabled, daily_bet_limit, max_single_bet
  INTO gambling_enabled, user_daily_limit, user_max_bet
  FROM user_settings
  WHERE user_id = p_user_id;

  IF NOT gambling_enabled THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Gambling mode is not enabled',
      'error_code', 'GAMBLING_DISABLED'
    );
  END IF;

  -- Check single bet limit
  IF user_max_bet IS NOT NULL AND p_bet_amount > user_max_bet THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Bet amount exceeds your maximum single bet limit',
      'error_code', 'BET_LIMIT_EXCEEDED',
      'max_bet', user_max_bet
    );
  END IF;

  -- Check daily betting limit
  IF user_daily_limit IS NOT NULL THEN
    SELECT COALESCE(SUM(bet_amount), 0) INTO daily_spent
    FROM task_bets
    WHERE user_id = p_user_id
      AND DATE(created_at) = CURRENT_DATE
      AND bet_status != 'cancelled'
      AND bet_status != 'refunded';

    IF daily_spent + p_bet_amount > user_daily_limit THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', 'Daily betting limit would be exceeded',
        'error_code', 'DAILY_LIMIT_EXCEEDED',
        'daily_limit', user_daily_limit,
        'daily_spent', daily_spent
      );
    END IF;
  END IF;

  -- Verify session exists and belongs to user
  SELECT EXISTS(
    SELECT 1 FROM active_sessions
    WHERE id = p_session_id AND user_id = p_user_id
  ), chain_id INTO session_exists, session_chain_id
  FROM active_sessions
  WHERE id = p_session_id AND user_id = p_user_id;

  IF NOT session_exists THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Active session not found',
      'error_code', 'SESSION_NOT_FOUND'
    );
  END IF;

  -- Check if bet already exists for this session
  SELECT * INTO existing_bet
  FROM task_bets
  WHERE user_id = p_user_id AND session_id = p_session_id;

  IF existing_bet IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Bet already placed on this session',
      'error_code', 'DUPLICATE_BET',
      'existing_bet_id', existing_bet.id,
      'existing_bet_amount', existing_bet.bet_amount
    );
  END IF;

  -- Get current user points with row locking
  SELECT COALESCE(total_points, 0) INTO user_current_points
  FROM user_points
  WHERE user_id = p_user_id
  FOR UPDATE;

  -- Create user_points record if it doesn't exist
  IF NOT FOUND THEN
    INSERT INTO user_points (user_id, total_points)
    VALUES (p_user_id, 0)
    ON CONFLICT (user_id) DO NOTHING;
    user_current_points := 0;
  END IF;

  -- Check if user has sufficient points
  IF user_current_points < p_bet_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient points for bet',
      'error_code', 'INSUFFICIENT_POINTS',
      'current_points', user_current_points,
      'required_points', p_bet_amount
    );
  END IF;

  -- ATOMIC OPERATIONS: All operations must succeed or fail together

  -- Step 1: Create the bet record first
  INSERT INTO task_bets (
    user_id,
    session_id,
    chain_id,
    bet_amount,
    bet_status,
    points_before,
    potential_payout,
    metadata
  )
  VALUES (
    p_user_id,
    p_session_id,
    session_chain_id,
    p_bet_amount,
    'pending',
    user_current_points,
    reward_payout,
    jsonb_build_object(
      'placed_at', now(),
      'payout_ratio', '2x',
      'original_bet', p_bet_amount,
      'potential_reward', p_bet_amount,
      'function_version', 'v3_bigint',
      'write_session_token', COALESCE(p_write_session_token::text, 'null')
    )
  )
  RETURNING id INTO new_bet_id;

  -- Step 2: Deduct points from user balance
  UPDATE user_points
  SET total_points = total_points - p_bet_amount,
      updated_at = now()
  WHERE user_id = p_user_id;

  -- Step 3: Record the transaction
  INSERT INTO point_transactions (
    user_id,
    transaction_type,
    points_change,
    points_before,
    points_after,
    description,
    reference_id
  )
  VALUES (
    p_user_id,
    'bet_placed',
    -p_bet_amount,
    user_current_points,
    user_current_points - p_bet_amount,
    'Placed bet (2x payout potential): ' || p_bet_amount::text || ' bet + ' || p_bet_amount::text || ' potential reward',
    new_bet_id
  );

  -- Step 4: Create success audit log
  INSERT INTO audit_logs (user_id, action, details, created_at)
  VALUES (
    p_user_id,
    'bet_placed_success_v3_bigint',
    jsonb_build_object(
      'bet_id', new_bet_id,
      'session_id', p_session_id,
      'chain_id', session_chain_id,
      'bet_amount', p_bet_amount,
      'potential_payout', reward_payout,
      'points_before', user_current_points,
      'points_after', user_current_points - p_bet_amount,
      'function_version', 'v3_bigint'
    ),
    NOW()
  );

  -- Build success result
  result := jsonb_build_object(
    'success', true,
    'message', 'Bet placed successfully (2x payout: bet return + equal reward)',
    'bet_id', new_bet_id,
    'bet_amount', p_bet_amount,
    'potential_payout', reward_payout,
    'potential_reward', p_bet_amount,
    'points_before', user_current_points,
    'points_after', user_current_points - p_bet_amount,
    'session_id', p_session_id,
    'chain_id', session_chain_id,
    'payout_explanation', '鎴愬姛鏃惰幏寰? ' || p_bet_amount::text || '(杩旇繕) + ' || p_bet_amount::text || '(濂栧姳) = ' || reward_payout::text || '绉垎'
  );

  RETURN result;

EXCEPTION WHEN OTHERS THEN
  -- Log the error for debugging
  INSERT INTO audit_logs (user_id, action, details, created_at)
  VALUES (
    p_user_id,
    'bet_placement_error_v3_bigint',
    jsonb_build_object(
      'session_id', p_session_id,
      'bet_amount', p_bet_amount,
      'error_message', SQLERRM,
      'error_state', SQLSTATE,
      'function_version', 'v3_bigint'
    ),
    NOW()
  );

  -- Re-raise the exception to ensure transaction rollback
  RAISE EXCEPTION 'Bet placement failed: %', SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION place_task_bet(uuid, uuid, bigint, uuid) TO authenticated;


-- ============================================================
-- STEP 3: Rebuild settle_task_bet with bigint variables
-- ============================================================

CREATE OR REPLACE FUNCTION settle_task_bet(
  bet_id uuid,
  task_successful boolean,
  completion_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  bet_record task_bets;
  user_current_points bigint;
  payout_amount bigint := 0;
  new_points_total bigint;
  result jsonb;
BEGIN
  -- Get the bet record
  SELECT * INTO bet_record
  FROM task_bets
  WHERE id = bet_id;

  IF bet_record IS NULL THEN
    RAISE EXCEPTION 'Bet not found';
  END IF;

  -- Check if bet is already settled
  IF bet_record.bet_status != 'pending' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Bet is already settled',
      'error_code', 'ALREADY_SETTLED',
      'current_status', bet_record.bet_status
    );
  END IF;

  -- Get current user points
  SELECT total_points INTO user_current_points
  FROM user_points
  WHERE user_id = bet_record.user_id;

  -- Calculate payout
  IF task_successful THEN
    payout_amount := bet_record.potential_payout;
    new_points_total := user_current_points + payout_amount;
  ELSE
    payout_amount := 0;
    new_points_total := user_current_points;
  END IF;

  -- Start transaction for atomic operations
  BEGIN
    -- Update bet record
    UPDATE task_bets
    SET bet_status = CASE WHEN task_successful THEN 'won' ELSE 'lost' END,
        points_after = new_points_total,
        actual_payout = payout_amount,
        settled_at = now(),
        metadata = metadata || jsonb_build_object(
          'settled_at', now(),
          'completion_notes', completion_notes,
          'task_successful', task_successful
        )
    WHERE id = bet_id;

    -- If bet won, add points to user balance
    IF task_successful THEN
      UPDATE user_points
      SET total_points = total_points + payout_amount,
          updated_at = now()
      WHERE user_id = bet_record.user_id;

      -- Record the winning transaction
      INSERT INTO point_transactions (
        user_id,
        transaction_type,
        points_change,
        points_before,
        points_after,
        description,
        reference_id
      )
      VALUES (
        bet_record.user_id,
        'bet_won',
        payout_amount,
        user_current_points,
        new_points_total,
        'Won bet on task completion',
        bet_id
      );
    ELSE
      -- Record the losing transaction (no points change, just for audit)
      INSERT INTO point_transactions (
        user_id,
        transaction_type,
        points_change,
        points_before,
        points_after,
        description,
        reference_id
      )
      VALUES (
        bet_record.user_id,
        'bet_lost',
        0,
        user_current_points,
        user_current_points,
        'Lost bet on task failure',
        bet_id
      );
    END IF;

    -- Build result
    result := jsonb_build_object(
      'success', true,
      'message', CASE WHEN task_successful THEN 'Bet won!' ELSE 'Bet lost' END,
      'bet_id', bet_id,
      'bet_amount', bet_record.bet_amount,
      'payout', payout_amount,
      'task_successful', task_successful,
      'points_before', user_current_points,
      'points_after', new_points_total,
      'bet_status', CASE WHEN task_successful THEN 'won' ELSE 'lost' END
    );

    RETURN result;

  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Bet settlement failed: %', SQLERRM;
  END;
END;
$$;


-- ============================================================
-- STEP 4: Rebuild refund_task_bet with bigint variables
-- ============================================================

CREATE OR REPLACE FUNCTION refund_task_bet(bet_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  bet_record task_bets;
  user_current_points bigint;
  refund_amount bigint;
  new_points_total bigint;
  result jsonb;
BEGIN
  -- Get the bet record
  SELECT * INTO bet_record
  FROM task_bets
  WHERE id = bet_id;

  IF bet_record IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Bet not found',
      'bet_id', bet_id
    );
  END IF;

  -- Check if bet is already settled or refunded
  IF bet_record.bet_status != 'pending' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Bet is already settled or refunded',
      'error_code', 'ALREADY_PROCESSED',
      'current_status', bet_record.bet_status
    );
  END IF;

  -- Get current user points
  SELECT total_points INTO user_current_points
  FROM user_points
  WHERE user_id = bet_record.user_id;

  refund_amount := bet_record.bet_amount;
  new_points_total := user_current_points + refund_amount;

  -- Start transaction for atomic operations
  BEGIN
    -- Update bet record as refunded
    UPDATE task_bets
    SET bet_status = 'refunded',
        points_after = new_points_total,
        actual_payout = refund_amount,
        settled_at = now(),
        cancellation_reason = 'Session cancelled - bet refunded',
        metadata = metadata || jsonb_build_object(
          'refunded_at', now(),
          'refund_reason', 'session_cancelled',
          'refund_amount', refund_amount
        )
    WHERE id = bet_id;

    -- Return points to user balance
    UPDATE user_points
    SET total_points = total_points + refund_amount,
        updated_at = now()
    WHERE user_id = bet_record.user_id;

    -- Record the refund transaction
    INSERT INTO point_transactions (
      user_id,
      transaction_type,
      points_change,
      points_before,
      points_after,
      description,
      reference_id
    )
    VALUES (
      bet_record.user_id,
      'bet_refunded',
      refund_amount,
      user_current_points,
      new_points_total,
      'Bet refunded due to session cancellation',
      bet_id
    );

    result := jsonb_build_object(
      'success', true,
      'message', 'Bet refunded successfully',
      'bet_id', bet_id,
      'refund_amount', refund_amount,
      'points_before', user_current_points,
      'points_after', new_points_total
    );

    RETURN result;
  END;
END;
$$;


-- ============================================================
-- STEP 5: Rebuild perform_daily_checkin with bigint variables
-- ============================================================

CREATE OR REPLACE FUNCTION perform_daily_checkin(target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  current_date_local date := CURRENT_DATE;
  existing_checkin daily_checkins;
  last_checkin daily_checkins;
  consecutive_days integer := 1;
  points_to_award bigint := 10;
  user_current_points bigint := 0;
  new_checkin_id uuid;
  result jsonb;
BEGIN
  -- Verify the user exists and is the authenticated user
  IF target_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only check in for yourself';
  END IF;

  -- Check if user already checked in today
  SELECT * INTO existing_checkin
  FROM daily_checkins
  WHERE user_id = target_user_id AND checkin_date = current_date_local;

  IF existing_checkin IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Already checked in today',
      'already_checked_in', true,
      'checkin_date', existing_checkin.checkin_date,
      'points_earned', 0,
      'consecutive_days', existing_checkin.consecutive_days
    );
  END IF;

  -- Get the most recent check-in to calculate consecutive days
  SELECT * INTO last_checkin
  FROM daily_checkins
  WHERE user_id = target_user_id
  ORDER BY checkin_date DESC
  LIMIT 1;

  -- Calculate consecutive days
  IF last_checkin IS NOT NULL THEN
    IF last_checkin.checkin_date = current_date_local - INTERVAL '1 day' THEN
      consecutive_days := last_checkin.consecutive_days + 1;
    ELSE
      consecutive_days := 1;
    END IF;
  END IF;

  -- Get current user points, create record if doesn't exist
  SELECT total_points INTO user_current_points
  FROM user_points
  WHERE user_id = target_user_id;

  IF user_current_points IS NULL THEN
    INSERT INTO user_points (user_id, total_points)
    VALUES (target_user_id, 0)
    ON CONFLICT (user_id) DO NOTHING;
    user_current_points := 0;
  END IF;

  -- Start transaction for atomic operations
  BEGIN
    -- Insert the new check-in record
    INSERT INTO daily_checkins (user_id, checkin_date, points_earned, consecutive_days)
    VALUES (target_user_id, current_date_local, points_to_award, consecutive_days)
    RETURNING id INTO new_checkin_id;

    -- Update user's total points
    UPDATE user_points
    SET total_points = total_points + points_to_award,
        updated_at = now()
    WHERE user_id = target_user_id;

    -- Record the transaction
    INSERT INTO point_transactions (
      user_id,
      transaction_type,
      points_change,
      points_before,
      points_after,
      description,
      reference_id
    )
    VALUES (
      target_user_id,
      'checkin',
      points_to_award,
      user_current_points,
      user_current_points + points_to_award,
      'Daily check-in reward',
      new_checkin_id
    );

    -- Build success result
    result := jsonb_build_object(
      'success', true,
      'message', 'Check-in successful!',
      'already_checked_in', false,
      'checkin_date', current_date_local,
      'points_earned', points_to_award,
      'consecutive_days', consecutive_days,
      'total_points', user_current_points + points_to_award,
      'checkin_id', new_checkin_id
    );

    RETURN result;

  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Check-in failed: %', SQLERRM;
  END;
END;
$$;


-- ============================================================
-- STEP 6: Rebuild get_user_gambling_stats with bigint variables
-- ============================================================

CREATE OR REPLACE FUNCTION get_user_gambling_stats(target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  total_bets bigint := 0;
  total_wagered bigint := 0;
  total_won bigint := 0;
  total_lost bigint := 0;
  net_profit bigint := 0;
  win_rate numeric := 0;
  current_points bigint := 0;
  gambling_enabled boolean := false;
  biggest_win bigint := 0;
  biggest_loss bigint := 0;
  current_streak integer := 0;
  longest_streak integer := 0;
  result jsonb;
BEGIN
  -- Verify access
  IF target_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only view your own gambling stats';
  END IF;

  -- Get current points and gambling settings
  SELECT COALESCE(up.total_points, 0), COALESCE(us.gambling_mode_enabled, false)
  INTO current_points, gambling_enabled
  FROM user_points up
  FULL OUTER JOIN user_settings us ON up.user_id = us.user_id
  WHERE up.user_id = target_user_id OR us.user_id = target_user_id;

  -- Get betting statistics
  SELECT
    COUNT(*),
    COALESCE(SUM(bet_amount), 0),
    COALESCE(SUM(CASE WHEN bet_status = 'won' THEN actual_payout ELSE 0 END), 0),
    COUNT(*) FILTER (WHERE bet_status = 'lost'),
    COALESCE(MAX(CASE WHEN bet_status = 'won' THEN actual_payout ELSE 0 END), 0),
    COALESCE(MAX(CASE WHEN bet_status = 'lost' THEN bet_amount ELSE 0 END), 0)
  INTO total_bets, total_wagered, total_won, total_lost, biggest_win, biggest_loss
  FROM task_bets
  WHERE user_id = target_user_id
    AND bet_status IN ('won', 'lost');

  -- Calculate net profit/loss
  net_profit := total_won - (total_bets * (total_wagered / GREATEST(total_bets, 1)));

  -- Calculate win rate
  IF total_bets > 0 THEN
    win_rate := (total_bets - total_lost) * 100.0 / total_bets;
  END IF;

  -- Calculate current winning/losing streak
  WITH recent_bets AS (
    SELECT bet_status,
           ROW_NUMBER() OVER (ORDER BY settled_at DESC) as rn
    FROM task_bets
    WHERE user_id = target_user_id
      AND bet_status IN ('won', 'lost')
      AND settled_at IS NOT NULL
    ORDER BY settled_at DESC
    LIMIT 50
  ),
  streak_calc AS (
    SELECT bet_status,
           rn,
           rn - ROW_NUMBER() OVER (PARTITION BY bet_status ORDER BY rn) as streak_group
    FROM recent_bets
  )
  SELECT COUNT(*) INTO current_streak
  FROM streak_calc
  WHERE streak_group = (SELECT streak_group FROM streak_calc WHERE rn = 1);

  -- Build result
  result := jsonb_build_object(
    'user_id', target_user_id,
    'gambling_enabled', gambling_enabled,
    'current_points', current_points,
    'total_bets', total_bets,
    'total_wagered', total_wagered,
    'total_won', total_won,
    'total_lost', total_lost,
    'net_profit', net_profit,
    'win_rate', ROUND(win_rate, 2),
    'biggest_win', biggest_win,
    'biggest_loss', biggest_loss,
    'current_streak', current_streak
  );

  RETURN result;
END;
$$;


-- ============================================================
-- STEP 7: Rebuild get_user_checkin_stats with bigint variables
-- ============================================================

CREATE OR REPLACE FUNCTION get_user_checkin_stats(target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  total_points bigint := 0;
  total_checkins integer := 0;
  current_streak integer := 0;
  longest_streak integer := 0;
  last_checkin_date date;
  has_checked_in_today boolean := false;
  result jsonb;
BEGIN
  -- Verify access
  IF target_user_id != auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only view your own stats';
  END IF;

  -- Get total points
  SELECT COALESCE(up.total_points, 0) INTO total_points
  FROM user_points up
  WHERE up.user_id = target_user_id;

  -- Get total check-ins
  SELECT COUNT(*) INTO total_checkins
  FROM daily_checkins dc
  WHERE dc.user_id = target_user_id;

  -- Get current streak
  SELECT consecutive_days, checkin_date INTO current_streak, last_checkin_date
  FROM daily_checkins
  WHERE user_id = target_user_id
  ORDER BY checkin_date DESC
  LIMIT 1;

  -- Check if streak is still active
  IF last_checkin_date IS NOT NULL THEN
    IF last_checkin_date = CURRENT_DATE THEN
      has_checked_in_today := true;
    ELSIF last_checkin_date < CURRENT_DATE - INTERVAL '1 day' THEN
      current_streak := 0;
    END IF;
  END IF;

  -- Get longest streak
  SELECT COALESCE(MAX(consecutive_days), 0) INTO longest_streak
  FROM daily_checkins
  WHERE user_id = target_user_id;

  -- Build result
  result := jsonb_build_object(
    'user_id', target_user_id,
    'total_points', total_points,
    'total_checkins', total_checkins,
    'current_streak', COALESCE(current_streak, 0),
    'longest_streak', longest_streak,
    'last_checkin_date', last_checkin_date,
    'has_checked_in_today', has_checked_in_today
  );

  RETURN result;
END;
$$;


-- ============================================================
-- STEP 8: Re-grant permissions (some may have been lost by CASCADE)
-- ============================================================

GRANT EXECUTE ON FUNCTION place_task_bet(uuid, uuid, bigint, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_gambling_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_betting_history(uuid, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION perform_daily_checkin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_checkin_stats(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION get_user_checkin_history(uuid, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION complete_task_with_betting(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION refund_task_bet(uuid) TO authenticated;


-- ============================================================
-- STEP 9: Verification
-- ============================================================

DO $$
DECLARE
  col_type text;
  func_count integer;
BEGIN
  -- Verify user_points.total_points is bigint
  SELECT data_type INTO col_type
  FROM information_schema.columns
  WHERE table_name = 'user_points' AND column_name = 'total_points';

  IF col_type != 'bigint' THEN
    RAISE EXCEPTION 'user_points.total_points is still %, expected bigint', col_type;
  END IF;

  -- Verify task_bets.bet_amount is bigint
  SELECT data_type INTO col_type
  FROM information_schema.columns
  WHERE table_name = 'task_bets' AND column_name = 'bet_amount';

  IF col_type != 'bigint' THEN
    RAISE EXCEPTION 'task_bets.bet_amount is still %, expected bigint', col_type;
  END IF;

  -- Verify place_task_bet function exists with bigint parameter
  SELECT COUNT(*) INTO func_count
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE p.proname = 'place_task_bet'
    AND n.nspname = 'public';

  IF func_count = 0 THEN
    RAISE EXCEPTION 'place_task_bet function not found after migration';
  END IF;

  RAISE NOTICE '=== Migration Verification Passed ===';
  RAISE NOTICE 'user_points.total_points: bigint';
  RAISE NOTICE 'task_bets.bet_amount: bigint';
  RAISE NOTICE 'place_task_bet functions: %', func_count;
  RAISE NOTICE 'All points columns migrated to bigint successfully';
END $$;


-- ===== 20260225000000_fix_settle_task_bet_loss_noop_transaction.sql =====
-- ========================================
-- Fix settle_task_bet loss settlement (no 0-point transaction)
-- Date: 2026-02-25
--
-- Background:
-- - point_transactions.points_change historically has CHECK (points_change != 0)
-- - settle_task_bet previously inserted a 'bet_lost' point_transactions row with points_change = 0
--   which can cause bet settlement to fail.
-- - When settlement fails, the bet stays 'pending' and may be refunded on active_sessions deletion,
--   making "lost bets" effectively free (no points deducted).
--
-- Fix:
-- - Only write point_transactions rows when there is an actual points delta.
-- - On bet loss, record state on task_bets only.
-- ========================================

CREATE OR REPLACE FUNCTION settle_task_bet(
  bet_id uuid,
  task_successful boolean,
  completion_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  bet_record task_bets;
  user_current_points bigint;
  payout_amount bigint := 0;
  new_points_total bigint;
  result jsonb;
BEGIN
  -- Get the bet record
  SELECT * INTO bet_record
  FROM task_bets
  WHERE id = bet_id;

  IF bet_record IS NULL THEN
    RAISE EXCEPTION 'Bet not found';
  END IF;

  -- Check if bet is already settled
  IF bet_record.bet_status != 'pending' THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Bet is already settled',
      'error_code', 'ALREADY_SETTLED',
      'current_status', bet_record.bet_status
    );
  END IF;

  -- Get current user points
  SELECT total_points INTO user_current_points
  FROM user_points
  WHERE user_id = bet_record.user_id;

  -- Calculate payout
  IF task_successful THEN
    payout_amount := bet_record.potential_payout;
    new_points_total := user_current_points + payout_amount;
  ELSE
    payout_amount := 0;
    new_points_total := user_current_points;
  END IF;

  -- Start transaction for atomic operations
  BEGIN
    -- Update bet record
    UPDATE task_bets
    SET bet_status = CASE WHEN task_successful THEN 'won' ELSE 'lost' END,
        points_after = new_points_total,
        actual_payout = payout_amount,
        settled_at = now(),
        metadata = metadata || jsonb_build_object(
          'settled_at', now(),
          'completion_notes', completion_notes,
          'task_successful', task_successful
        )
    WHERE id = bet_id;

    -- If bet won, add points to user balance and record a transaction
    IF task_successful THEN
      UPDATE user_points
      SET total_points = total_points + payout_amount,
          updated_at = now()
      WHERE user_id = bet_record.user_id;

      INSERT INTO point_transactions (
        user_id,
        transaction_type,
        points_change,
        points_before,
        points_after,
        description,
        reference_id
      )
      VALUES (
        bet_record.user_id,
        'bet_won',
        payout_amount,
        user_current_points,
        new_points_total,
        'Won bet on task completion',
        bet_id
      );
    END IF;

    -- Build result
    result := jsonb_build_object(
      'success', true,
      'message', CASE WHEN task_successful THEN 'Bet won!' ELSE 'Bet lost' END,
      'bet_id', bet_id,
      'bet_amount', bet_record.bet_amount,
      'payout', payout_amount,
      'task_successful', task_successful,
      'points_before', user_current_points,
      'points_after', new_points_total,
      'bet_status', CASE WHEN task_successful THEN 'won' ELSE 'lost' END
    );

    RETURN result;

  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Bet settlement failed: %', SQLERRM;
  END;
END;
$$;



-- ===== 20260716000000_add_atomic_rsip_intents.sql =====
-- Atomic RSIP intents used when one domain action spans multiple tables.
-- Each function has one canonical signature to avoid PostgREST RPC ambiguity.

-- The original single-column foreign keys allow a child/group reference to
-- cross tenant boundaries when a UUID is known. These NOT VALID constraints
-- protect all new writes without making this migration depend on legacy data
-- already satisfying the stronger invariant.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'rsip_nodes_user_id_id_key'
      AND conrelid = 'public.rsip_nodes'::regclass
  ) THEN
    ALTER TABLE public.rsip_nodes
      ADD CONSTRAINT rsip_nodes_user_id_id_key UNIQUE (user_id, id);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'rsip_groups_user_id_id_key'
      AND conrelid = 'public.rsip_groups'::regclass
  ) THEN
    ALTER TABLE public.rsip_groups
      ADD CONSTRAINT rsip_groups_user_id_id_key UNIQUE (user_id, id);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'rsip_nodes_user_parent_fkey'
      AND conrelid = 'public.rsip_nodes'::regclass
  ) THEN
    ALTER TABLE public.rsip_nodes
      ADD CONSTRAINT rsip_nodes_user_parent_fkey
      FOREIGN KEY (user_id, parent_id)
      REFERENCES public.rsip_nodes(user_id, id)
      ON DELETE CASCADE
      NOT VALID;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'rsip_nodes_user_group_fkey'
      AND conrelid = 'public.rsip_nodes'::regclass
  ) THEN
    ALTER TABLE public.rsip_nodes
      ADD CONSTRAINT rsip_nodes_user_group_fkey
      FOREIGN KEY (user_id, group_id)
      REFERENCES public.rsip_groups(user_id, id)
      NOT VALID;
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.rsip_atomic_intents (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  intent_kind text NOT NULL CHECK (
    intent_kind IN ('create_nodes_with_meta', 'archive_nodes')
  ),
  intent_key text NOT NULL,
  request_node_ids uuid[] NOT NULL,
  affected_node_ids uuid[] NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, intent_kind, intent_key)
);

ALTER TABLE public.rsip_atomic_intents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.rsip_atomic_intents FROM PUBLIC;
REVOKE ALL ON TABLE public.rsip_atomic_intents FROM anon, authenticated;

DROP FUNCTION IF EXISTS public.create_rsip_nodes_with_meta(jsonb, jsonb);
DROP FUNCTION IF EXISTS public.create_rsip_nodes_with_meta(text, jsonb, jsonb);

CREATE FUNCTION public.create_rsip_nodes_with_meta(
  p_intent_key text,
  p_nodes jsonb,
  p_meta jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_requested_node_ids uuid[];
  v_recorded_request_ids uuid[];
  v_intent_node_ids uuid[];
  v_nodes_result jsonb;
  v_meta_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '28000';
  END IF;

  IF p_nodes IS NULL OR jsonb_typeof(p_nodes) <> 'array' THEN
    RAISE EXCEPTION 'p_nodes must be a JSON array'
      USING ERRCODE = '22023';
  END IF;
  IF p_intent_key IS NULL OR btrim(p_intent_key) = '' THEN
    RAISE EXCEPTION 'p_intent_key must not be empty'
      USING ERRCODE = '22023';
  END IF;
  IF p_meta IS NULL OR jsonb_typeof(p_meta) <> 'object' THEN
    RAISE EXCEPTION 'p_meta must be a JSON object'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_nodes) AS item
    GROUP BY (item ->> 'id')::uuid
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'p_nodes contains duplicate node ids'
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(
    array_agg(node_id ORDER BY node_id),
    ARRAY[]::uuid[]
  )
  INTO v_requested_node_ids
  FROM (
    SELECT DISTINCT (item ->> 'id')::uuid AS node_id
    FROM jsonb_array_elements(p_nodes) AS item
  ) AS requested;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_user_id::text || ':create_nodes_with_meta:' || p_intent_key,
      0
    )
  );

  SELECT intent.request_node_ids, intent.affected_node_ids
  INTO v_recorded_request_ids, v_intent_node_ids
  FROM public.rsip_atomic_intents AS intent
  WHERE intent.user_id = v_user_id
    AND intent.intent_kind = 'create_nodes_with_meta'
    AND intent.intent_key = p_intent_key;

  IF FOUND THEN
    IF v_recorded_request_ids <> v_requested_node_ids THEN
      RAISE EXCEPTION 'RSIP creation intent key was reused for another request'
        USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(
      jsonb_agg(to_jsonb(node) ORDER BY node.sort_order, node.id),
      '[]'::jsonb
    )
    INTO v_nodes_result
    FROM public.rsip_nodes AS node
    WHERE node.user_id = v_user_id
      AND node.id = ANY(v_intent_node_ids);

    SELECT COALESCE(to_jsonb(meta), '{}'::jsonb)
    INTO v_meta_result
    FROM public.rsip_meta AS meta
    WHERE meta.user_id = v_user_id;

    RETURN jsonb_build_object(
      'nodes', v_nodes_result,
      'meta', COALESCE(v_meta_result, '{}'::jsonb)
    );
  END IF;

  -- Keep referenced rows stable until this transaction has inserted and
  -- verified the batch. Missing parents/groups are rejected by their FKs.
  PERFORM parent.id
  FROM public.rsip_nodes AS parent
  JOIN jsonb_array_elements(p_nodes) AS item
    ON parent.id = NULLIF(item ->> 'parent_id', '')::uuid
  ORDER BY parent.id
  FOR KEY SHARE OF parent;

  PERFORM node_group.id
  FROM public.rsip_groups AS node_group
  JOIN jsonb_array_elements(p_nodes) AS item
    ON node_group.id = NULLIF(item ->> 'group_id', '')::uuid
  ORDER BY node_group.id
  FOR KEY SHARE OF node_group;

  -- SECURITY DEFINER must not permit an id collision to overwrite another user.
  IF EXISTS (
    SELECT 1
    FROM public.rsip_nodes AS existing
    JOIN jsonb_array_elements(p_nodes) AS item
      ON existing.id = (item ->> 'id')::uuid
    WHERE existing.user_id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'RSIP node id belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  -- A supplied parent may be pre-existing or part of this batch, but it may
  -- never point into another user's tree.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_nodes) AS item
    JOIN public.rsip_nodes AS parent
      ON parent.id = NULLIF(item ->> 'parent_id', '')::uuid
    WHERE parent.user_id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'RSIP parent node belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_nodes) AS item
    JOIN public.rsip_groups AS node_group
      ON node_group.id = NULLIF(item ->> 'group_id', '')::uuid
    WHERE node_group.user_id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'RSIP group belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.rsip_nodes AS existing (
    id,
    user_id,
    parent_id,
    title,
    rule,
    sort_order,
    use_timer,
    timer_minutes,
    created_at,
    emoji,
    type,
    group_id,
    reinforcement_level,
    max_reinforcement_level,
    cumulative_execution_days,
    is_passive,
    split_from_goal,
    stability_phase,
    phase_started_at,
    last_executed_at,
    last_violated_at,
    consecutive_executions,
    consecutive_violations,
    total_executions,
    total_violations
  )
  SELECT
    (item ->> 'id')::uuid,
    v_user_id,
    NULLIF(item ->> 'parent_id', '')::uuid,
    item ->> 'title',
    item ->> 'rule',
    COALESCE((item ->> 'sort_order')::integer, 0),
    COALESCE((item ->> 'use_timer')::boolean, false),
    NULLIF(item ->> 'timer_minutes', '')::integer,
    COALESCE((item ->> 'created_at')::timestamptz, now()),
    NULLIF(item ->> 'emoji', ''),
    NULLIF(item ->> 'type', ''),
    NULLIF(item ->> 'group_id', '')::uuid,
    COALESCE((item ->> 'reinforcement_level')::integer, 0),
    COALESCE((item ->> 'max_reinforcement_level')::integer, 0),
    COALESCE((item ->> 'cumulative_execution_days')::integer, 0),
    COALESCE((item ->> 'is_passive')::boolean, false),
    NULLIF(item ->> 'split_from_goal', ''),
    COALESCE(NULLIF(item ->> 'stability_phase', ''), 'E0'),
    NULLIF(item ->> 'phase_started_at', '')::timestamptz,
    NULLIF(item ->> 'last_executed_at', '')::timestamptz,
    NULLIF(item ->> 'last_violated_at', '')::timestamptz,
    COALESCE((item ->> 'consecutive_executions')::integer, 0),
    COALESCE((item ->> 'consecutive_violations')::integer, 0),
    COALESCE((item ->> 'total_executions')::integer, 0),
    COALESCE((item ->> 'total_violations')::integer, 0)
  FROM jsonb_array_elements(p_nodes) AS item
  ON CONFLICT (id) DO NOTHING;

  -- ON CONFLICT may have waited for a concurrent transaction. Re-read on a
  -- fresh statement snapshot and fail the whole transaction unless every id
  -- now resolves to this user with tenant-safe persisted references.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_nodes) AS item
    LEFT JOIN public.rsip_nodes AS persisted
      ON persisted.id = (item ->> 'id')::uuid
    LEFT JOIN public.rsip_nodes AS persisted_parent
      ON persisted_parent.id = persisted.parent_id
    LEFT JOIN public.rsip_groups AS persisted_group
      ON persisted_group.id = persisted.group_id
    WHERE persisted.id IS NULL
      OR persisted.user_id <> v_user_id
      OR (
        persisted.parent_id IS NOT NULL
        AND persisted_parent.user_id IS DISTINCT FROM v_user_id
      )
      OR (
        persisted.group_id IS NOT NULL
        AND persisted_group.user_id IS DISTINCT FROM v_user_id
      )
  ) THEN
    RAISE EXCEPTION 'RSIP node batch failed tenant ownership verification'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.rsip_meta AS existing (
    user_id,
    last_added_at,
    allow_multiple_per_day,
    last_tree_opened_at,
    daily_tree_open_required,
    tree_open_streak,
    current_run_number,
    current_run_started_at
  )
  VALUES (
    v_user_id,
    NULLIF(p_meta ->> 'last_added_at', '')::timestamptz,
    COALESCE((p_meta ->> 'allow_multiple_per_day')::boolean, false),
    NULLIF(p_meta ->> 'last_tree_opened_at', '')::timestamptz,
    COALESCE((p_meta ->> 'daily_tree_open_required')::boolean, false),
    COALESCE((p_meta ->> 'tree_open_streak')::integer, 0),
    NULLIF(p_meta ->> 'current_run_number', '')::integer,
    NULLIF(p_meta ->> 'current_run_started_at', '')::timestamptz
  )
  ON CONFLICT (user_id) DO UPDATE SET
    last_added_at = CASE
      WHEN existing.last_added_at IS NULL THEN EXCLUDED.last_added_at
      WHEN EXCLUDED.last_added_at IS NULL THEN existing.last_added_at
      ELSE GREATEST(existing.last_added_at, EXCLUDED.last_added_at)
    END,
    current_run_number = COALESCE(
      existing.current_run_number,
      EXCLUDED.current_run_number
    ),
    current_run_started_at = COALESCE(
      existing.current_run_started_at,
      EXCLUDED.current_run_started_at
    );

  v_intent_node_ids := v_requested_node_ids;
  INSERT INTO public.rsip_atomic_intents (
    user_id,
    intent_kind,
    intent_key,
    request_node_ids,
    affected_node_ids
  )
  VALUES (
    v_user_id,
    'create_nodes_with_meta',
    p_intent_key,
    v_requested_node_ids,
    v_intent_node_ids
  );

  SELECT COALESCE(
    jsonb_agg(to_jsonb(node) ORDER BY node.sort_order, node.id),
    '[]'::jsonb
  )
  INTO v_nodes_result
  FROM public.rsip_nodes AS node
  WHERE node.user_id = v_user_id
    AND node.id = ANY(v_intent_node_ids);

  SELECT COALESCE(to_jsonb(meta), '{}'::jsonb)
  INTO v_meta_result
  FROM public.rsip_meta AS meta
  WHERE meta.user_id = v_user_id;

  RETURN jsonb_build_object(
    'nodes', v_nodes_result,
    'meta', COALESCE(v_meta_result, '{}'::jsonb)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_rsip_nodes_with_meta(text, jsonb, jsonb)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_rsip_nodes_with_meta(text, jsonb, jsonb)
  TO authenticated;

DROP FUNCTION IF EXISTS public.archive_rsip_nodes_and_remove(uuid[], jsonb);
DROP FUNCTION IF EXISTS public.archive_rsip_nodes_and_remove(uuid[]);
DROP FUNCTION IF EXISTS public.archive_rsip_nodes_and_remove(text, uuid[]);

CREATE FUNCTION public.archive_rsip_nodes_and_remove(
  p_intent_key text,
  p_node_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_requested_node_ids uuid[];
  v_recorded_request_ids uuid[];
  v_intent_node_ids uuid[];
  v_live_node_ids uuid[];
  v_frontier_ids uuid[];
  v_child_ids uuid[];
  v_archived_at timestamptz := now();
  v_library_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '28000';
  END IF;

  IF p_intent_key IS NULL OR btrim(p_intent_key) = '' THEN
    RAISE EXCEPTION 'p_intent_key must not be empty'
      USING ERRCODE = '22023';
  END IF;

  IF p_node_ids IS NULL OR cardinality(p_node_ids) = 0 THEN
    RETURN jsonb_build_object(
      'removed_node_ids', '[]'::jsonb,
      'library_entries', '[]'::jsonb
    );
  END IF;

  SELECT array_agg(node_id ORDER BY node_id)
  INTO v_requested_node_ids
  FROM (
    SELECT DISTINCT unnest(p_node_ids) AS node_id
  ) AS requested;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_user_id::text || ':archive_nodes:' || p_intent_key,
      0
    )
  );

  SELECT intent.request_node_ids, intent.affected_node_ids
  INTO v_recorded_request_ids, v_intent_node_ids
  FROM public.rsip_atomic_intents AS intent
  WHERE intent.user_id = v_user_id
    AND intent.intent_kind = 'archive_nodes'
    AND intent.intent_key = p_intent_key;

  IF FOUND THEN
    IF v_recorded_request_ids <> v_requested_node_ids THEN
      RAISE EXCEPTION 'RSIP archive intent key was reused for another request'
        USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(
      jsonb_agg(to_jsonb(entry) ORDER BY entry.updated_at DESC, entry.id),
      '[]'::jsonb
    )
    INTO v_library_result
    FROM public.rsip_policy_library AS entry
    WHERE entry.user_id = v_user_id
      AND entry.id = ANY(v_intent_node_ids);

    RETURN jsonb_build_object(
      'removed_node_ids', to_jsonb(v_intent_node_ids),
      'library_entries', v_library_result
    );
  END IF;

  -- Lock roots first. FK checks take a conflicting KEY SHARE lock, so after
  -- this succeeds no concurrent transaction can attach a new direct child.
  SELECT COALESCE(
    array_agg(locked_node.id ORDER BY locked_node.id),
    ARRAY[]::uuid[]
  )
  INTO v_live_node_ids
  FROM (
    SELECT node.id, node.user_id
    FROM public.rsip_nodes AS node
    WHERE node.id = ANY(p_node_ids)
    ORDER BY node.id
    FOR UPDATE
  ) AS locked_node;

  IF cardinality(v_live_node_ids) = 0 THEN
    v_intent_node_ids := v_requested_node_ids;
    INSERT INTO public.rsip_atomic_intents (
      user_id,
      intent_kind,
      intent_key,
      request_node_ids,
      affected_node_ids
    )
    VALUES (
      v_user_id,
      'archive_nodes',
      p_intent_key,
      v_requested_node_ids,
      v_intent_node_ids
    );

    SELECT COALESCE(
      jsonb_agg(to_jsonb(entry) ORDER BY entry.updated_at DESC, entry.id),
      '[]'::jsonb
    )
    INTO v_library_result
    FROM public.rsip_policy_library AS entry
    WHERE entry.user_id = v_user_id
      AND entry.id = ANY(v_intent_node_ids);

    RETURN jsonb_build_object(
      'removed_node_ids', to_jsonb(v_intent_node_ids),
      'library_entries', v_library_result
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.rsip_nodes AS root_node
    WHERE root_node.id = ANY(v_live_node_ids)
      AND root_node.user_id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'RSIP node belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  -- Walk one locked frontier at a time. Every parent in a frontier is already
  -- FOR UPDATE locked before its children are read, closing the cascade race
  -- at every depth instead of only for the requested roots.
  v_frontier_ids := v_live_node_ids;
  LOOP
    SELECT COALESCE(
      array_agg(locked_child.id ORDER BY locked_child.id),
      ARRAY[]::uuid[]
    )
    INTO v_child_ids
    FROM (
      SELECT child.id
      FROM public.rsip_nodes AS child
      WHERE child.parent_id = ANY(v_frontier_ids)
        AND NOT child.id = ANY(v_live_node_ids)
      ORDER BY child.id
      FOR UPDATE
    ) AS locked_child;

    EXIT WHEN cardinality(v_child_ids) = 0;

    v_live_node_ids := v_live_node_ids || v_child_ids;
    v_frontier_ids := v_child_ids;
  END LOOP;

  -- Legacy rows may predate the composite tenant FK above. Never let a root
  -- delete cascade into another user's row; abort the transaction instead.
  IF EXISTS (
    SELECT 1
    FROM public.rsip_nodes AS descendant
    WHERE descendant.id = ANY(v_live_node_ids)
      AND descendant.user_id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'RSIP tree contains a node owned by another user'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.rsip_policy_library AS existing (
    id,
    user_id,
    title,
    rule,
    type,
    emoji,
    cumulative_execution_days,
    internalization_progress,
    last_active_at,
    times_used,
    use_timer,
    timer_minutes,
    is_passive,
    updated_at
  )
  SELECT
    node.id,
    v_user_id,
    node.title,
    node.rule,
    node.type,
    node.emoji,
    GREATEST(
      COALESCE(node.cumulative_execution_days, 0),
      COALESCE(node.total_executions, 0),
      0
    ),
    LEAST(
      100::numeric,
      GREATEST(
        COALESCE(node.cumulative_execution_days, 0),
        COALESCE(node.total_executions, 0),
        0
      ) * 100.0 / 60.0
    ),
    v_archived_at,
    1,
    node.use_timer,
    node.timer_minutes,
    node.is_passive,
    v_archived_at
  FROM public.rsip_nodes AS node
  WHERE node.user_id = v_user_id
    AND node.id = ANY(v_live_node_ids)
  ON CONFLICT (user_id, id) DO UPDATE SET
    title = EXCLUDED.title,
    rule = EXCLUDED.rule,
    type = COALESCE(EXCLUDED.type, existing.type),
    emoji = COALESCE(EXCLUDED.emoji, existing.emoji),
    cumulative_execution_days = GREATEST(
      existing.cumulative_execution_days,
      EXCLUDED.cumulative_execution_days
    ),
    internalization_progress = GREATEST(
      existing.internalization_progress,
      EXCLUDED.internalization_progress
    ),
    last_active_at = GREATEST(
      existing.last_active_at,
      EXCLUDED.last_active_at
    ),
    times_used = existing.times_used,
    use_timer = EXCLUDED.use_timer,
    timer_minutes = COALESCE(
      EXCLUDED.timer_minutes,
      existing.timer_minutes
    ),
    is_passive = EXCLUDED.is_passive,
    updated_at = now();

  DELETE FROM public.rsip_nodes
  WHERE user_id = v_user_id
    AND id = ANY(v_live_node_ids);

  SELECT array_agg(node_id ORDER BY node_id)
  INTO v_intent_node_ids
  FROM (
    SELECT DISTINCT unnest(v_requested_node_ids || v_live_node_ids) AS node_id
  ) AS affected;

  INSERT INTO public.rsip_atomic_intents (
    user_id,
    intent_kind,
    intent_key,
    request_node_ids,
    affected_node_ids
  )
  VALUES (
    v_user_id,
    'archive_nodes',
    p_intent_key,
    v_requested_node_ids,
    v_intent_node_ids
  );

  SELECT COALESCE(
    jsonb_agg(to_jsonb(entry) ORDER BY entry.updated_at DESC, entry.id),
    '[]'::jsonb
  )
  INTO v_library_result
  FROM public.rsip_policy_library AS entry
  WHERE entry.user_id = v_user_id
    AND entry.id = ANY(v_intent_node_ids);

  RETURN jsonb_build_object(
    'removed_node_ids', to_jsonb(v_intent_node_ids),
    'library_entries', v_library_result
  );
END;
$$;

REVOKE ALL ON FUNCTION public.archive_rsip_nodes_and_remove(text, uuid[])
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.archive_rsip_nodes_and_remove(text, uuid[])
  TO authenticated;


-- ===== 20260907000000_add_rsip_group_tolerance_usage.sql =====
ALTER TABLE public.rsip_groups
  ADD COLUMN IF NOT EXISTS fault_tolerance_used integer NOT NULL DEFAULT 0
  CHECK (fault_tolerance_used >= 0);


-- ===== 20260920000000_harden_points_rpc_authorization.sql =====
-- Points are writable only through authorized, serialized RPCs.
-- Keep historical migration bytes unchanged; apply this after 20260907000000.
BEGIN;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;
-- RLS controls row DML, not TRUNCATE or trigger/constraint administration.
-- Historical Supabase ALL grants must not expose those table-wide privileges.
REVOKE TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public
  FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE TRUNCATE, REFERENCES, TRIGGER ON TABLES FROM PUBLIC, anon, authenticated;

-- Session UUIDs remain as immutable audit references after cancellation/completion.
-- New bets validate and lock the live session; clients cannot insert bets directly.
ALTER TABLE public.task_bets DROP CONSTRAINT IF EXISTS task_bets_session_id_fkey;
ALTER TABLE public.completion_history
  ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON public.user_points, public.task_bets, public.point_transactions,
     public.daily_checkins, public.audit_logs, public.write_sessions
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.user_points, public.task_bets, public.point_transactions,
  public.daily_checkins, public.audit_logs, public.write_sessions TO authenticated;
ALTER TABLE public.write_sessions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users read own write sessions" ON public.write_sessions;
CREATE POLICY "Users read own write sessions" ON public.write_sessions
  FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
DROP POLICY IF EXISTS "Service can insert audit logs" ON public.audit_logs;
CREATE POLICY "Service can insert audit logs" ON public.audit_logs
  FOR INSERT TO service_role WITH CHECK (true);

CREATE OR REPLACE FUNCTION public.place_task_bet(
  p_user_id uuid,
  p_session_id uuid,
  p_bet_amount bigint,
  p_write_session_token uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  user_current_points bigint := 0;
  session_exists boolean := false;
  session_chain_id uuid;
  existing_bet task_bets;
  gambling_enabled boolean := false;
  daily_spent bigint := 0;
  user_daily_limit bigint;
  user_max_bet bigint;
  new_bet_id uuid;
  reward_payout bigint;
  result jsonb;
BEGIN
  IF auth.uid() IS NULL OR p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  IF p_bet_amount IS NULL OR p_bet_amount <= 0 OR p_bet_amount > 4611686018427387903 THEN
    RAISE EXCEPTION 'Invalid bet amount' USING ERRCODE = '22023';
  END IF;
  reward_payout := p_bet_amount * 2;
  -- Lock live session before wallet; completion and cancellation use this order.
  SELECT chain_id INTO session_chain_id FROM public.active_sessions
  WHERE id = p_session_id AND user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error_code', 'SESSION_NOT_FOUND', 'message', 'Active session not found');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chains WHERE id = session_chain_id AND user_id = p_user_id) THEN
    RAISE EXCEPTION 'Session chain ownership mismatch' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.user_points(user_id, total_points) VALUES(p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;
  SELECT total_points INTO user_current_points FROM public.user_points
  WHERE user_id = p_user_id FOR UPDATE;
  -- Wallet lock serializes limits and duplicate requests for this user.
  SELECT * INTO existing_bet FROM public.task_bets
  WHERE user_id = p_user_id AND session_id = p_session_id;
  IF FOUND THEN
    IF existing_bet.bet_amount IS DISTINCT FROM p_bet_amount THEN
      RAISE EXCEPTION 'Bet request conflicts with existing bet' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object('success', true, 'message', 'Bet already placed', 'replayed', true,
      'bet_id', existing_bet.id, 'bet_amount', existing_bet.bet_amount,
      'potential_payout', existing_bet.potential_payout,
      'points_before', existing_bet.points_before,
      'points_after', existing_bet.points_before - existing_bet.bet_amount,
      'session_id', p_session_id, 'chain_id', session_chain_id);
  END IF;
  -- Validate bet amount
  IF p_bet_amount <= 0 THEN
    RAISE EXCEPTION 'Bet amount must be greater than 0';
  END IF;

  -- Check if gambling mode is enabled
  SELECT gambling_mode_enabled, daily_bet_limit, max_single_bet
  INTO gambling_enabled, user_daily_limit, user_max_bet
  FROM user_settings
  WHERE user_id = p_user_id;

  IF gambling_enabled IS DISTINCT FROM true THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Gambling mode is not enabled',
      'error_code', 'GAMBLING_DISABLED'
    );
  END IF;

  -- Check single bet limit
  IF user_max_bet IS NOT NULL AND p_bet_amount > user_max_bet THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Bet amount exceeds your maximum single bet limit',
      'error_code', 'BET_LIMIT_EXCEEDED',
      'max_bet', user_max_bet
    );
  END IF;

  -- Check daily betting limit
  IF user_daily_limit IS NOT NULL THEN
    SELECT COALESCE(SUM(bet_amount), 0) INTO daily_spent
    FROM task_bets
    WHERE user_id = p_user_id
      AND DATE(created_at) = CURRENT_DATE
      AND bet_status != 'cancelled'
      AND bet_status != 'refunded';

    IF daily_spent + p_bet_amount > user_daily_limit THEN
      RETURN jsonb_build_object(
        'success', false,
        'message', 'Daily betting limit would be exceeded',
        'error_code', 'DAILY_LIMIT_EXCEEDED',
        'daily_limit', user_daily_limit,
        'daily_spent', daily_spent
      );
    END IF;
  END IF;

  -- Check if user has sufficient points
  IF user_current_points < p_bet_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient points for bet',
      'error_code', 'INSUFFICIENT_POINTS',
      'current_points', user_current_points,
      'required_points', p_bet_amount
    );
  END IF;

  -- ATOMIC OPERATIONS: All operations must succeed or fail together

  -- Step 1: Create the bet record first
  INSERT INTO task_bets (
    user_id,
    session_id,
    chain_id,
    bet_amount,
    bet_status,
    points_before,
    potential_payout,
    metadata
  )
  VALUES (
    p_user_id,
    p_session_id,
    session_chain_id,
    p_bet_amount,
    'pending',
    user_current_points,
    reward_payout,
    jsonb_build_object(
      'placed_at', now(),
      'payout_ratio', '2x',
      'original_bet', p_bet_amount,
      'potential_reward', p_bet_amount,
      'function_version', 'v3_bigint',
      'write_session_token', COALESCE(p_write_session_token::text, 'null')
    )
  )
  RETURNING id INTO new_bet_id;

  -- Step 2: Deduct points from user balance
  UPDATE user_points
  SET total_points = total_points - p_bet_amount,
      updated_at = now()
  WHERE user_id = p_user_id;

  -- Step 3: Record the transaction
  INSERT INTO point_transactions (
    user_id,
    transaction_type,
    points_change,
    points_before,
    points_after,
    description,
    reference_id
  )
  VALUES (
    p_user_id,
    'bet_placed',
    -p_bet_amount,
    user_current_points,
    user_current_points - p_bet_amount,
    'Placed bet (2x payout potential): ' || p_bet_amount::text || ' bet + ' || p_bet_amount::text || ' potential reward',
    new_bet_id
  );

  -- Step 4: Create success audit log
  INSERT INTO audit_logs (user_id, action, details, created_at)
  VALUES (
    p_user_id,
    'bet_placed_success_v3_bigint',
    jsonb_build_object(
      'bet_id', new_bet_id,
      'session_id', p_session_id,
      'chain_id', session_chain_id,
      'bet_amount', p_bet_amount,
      'potential_payout', reward_payout,
      'points_before', user_current_points,
      'points_after', user_current_points - p_bet_amount,
      'function_version', 'v3_bigint'
    ),
    NOW()
  );

  -- Build success result
  result := jsonb_build_object(
    'success', true,
    'message', 'Bet placed successfully (2x payout: bet return + equal reward)',
    'bet_id', new_bet_id,
    'bet_amount', p_bet_amount,
    'potential_payout', reward_payout,
    'potential_reward', p_bet_amount,
    'points_before', user_current_points,
    'points_after', user_current_points - p_bet_amount,
    'session_id', p_session_id,
    'chain_id', session_chain_id,
    'payout_explanation', '鎴愬姛鏃惰幏寰? ' || p_bet_amount::text || '(杩旇繕) + ' || p_bet_amount::text || '(濂栧姳) = ' || reward_payout::text || '绉垎'
  );

  RETURN result;

END;
$$;

CREATE OR REPLACE FUNCTION public.perform_daily_checkin(target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  current_date_local date := CURRENT_DATE;
  existing_checkin daily_checkins;
  last_checkin daily_checkins;
  consecutive_days integer := 1;
  points_to_award bigint := 10;
  user_current_points bigint := 0;
  new_checkin_id uuid;
  result jsonb;
BEGIN
  -- Verify the user exists and is the authenticated user
  IF auth.uid() IS NULL OR target_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only check in for yourself';
  END IF;

  INSERT INTO public.user_points(user_id, total_points) VALUES(target_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;
  SELECT total_points INTO user_current_points FROM public.user_points
  WHERE user_id = target_user_id FOR UPDATE;

  -- Check if user already checked in today
  SELECT * INTO existing_checkin
  FROM daily_checkins
  WHERE user_id = target_user_id AND checkin_date = current_date_local;

  IF existing_checkin.id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Already checked in today',
      'already_checked_in', true,
      'checkin_date', existing_checkin.checkin_date,
      'points_earned', 0,
      'consecutive_days', existing_checkin.consecutive_days
    );
  END IF;

  -- Get the most recent check-in to calculate consecutive days
  SELECT * INTO last_checkin
  FROM daily_checkins
  WHERE user_id = target_user_id
  ORDER BY checkin_date DESC
  LIMIT 1;

  -- Calculate consecutive days
  IF last_checkin.id IS NOT NULL THEN
    IF last_checkin.checkin_date = current_date_local - INTERVAL '1 day' THEN
      consecutive_days := last_checkin.consecutive_days + 1;
    ELSE
      consecutive_days := 1;
    END IF;
  END IF;

  -- Start transaction for atomic operations
  BEGIN
    -- Insert the new check-in record
    INSERT INTO daily_checkins (user_id, checkin_date, points_earned, consecutive_days)
    VALUES (target_user_id, current_date_local, points_to_award, consecutive_days)
    RETURNING id INTO new_checkin_id;

    -- Update user's total points
    UPDATE user_points
    SET total_points = total_points + points_to_award,
        updated_at = now()
    WHERE user_id = target_user_id;

    -- Record the transaction
    INSERT INTO point_transactions (
      user_id,
      transaction_type,
      points_change,
      points_before,
      points_after,
      description,
      reference_id
    )
    VALUES (
      target_user_id,
      'checkin',
      points_to_award,
      user_current_points,
      user_current_points + points_to_award,
      'Daily check-in reward',
      new_checkin_id
    );

    -- Build success result
    result := jsonb_build_object(
      'success', true,
      'message', 'Check-in successful!',
      'already_checked_in', false,
      'checkin_date', current_date_local,
      'points_earned', points_to_award,
      'consecutive_days', consecutive_days,
      'total_points', user_current_points + points_to_award,
      'checkin_id', new_checkin_id
    );

    RETURN result;

  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Check-in failed: %', SQLERRM;
  END;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_gambling_stats(target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  total_bets bigint := 0;
  total_wagered bigint := 0;
  total_won bigint := 0;
  total_lost bigint := 0;
  net_profit bigint := 0;
  win_rate numeric := 0;
  current_points bigint := 0;
  gambling_enabled boolean := false;
  biggest_win bigint := 0;
  biggest_loss bigint := 0;
  current_streak integer := 0;
  longest_streak integer := 0;
  result jsonb;
BEGIN
  -- Verify access
  IF auth.uid() IS NULL OR target_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only view your own gambling stats';
  END IF;

  -- Get current points and gambling settings
  SELECT COALESCE(up.total_points, 0), COALESCE(us.gambling_mode_enabled, false)
  INTO current_points, gambling_enabled
  FROM user_points up
  FULL OUTER JOIN user_settings us ON up.user_id = us.user_id
  WHERE up.user_id = target_user_id OR us.user_id = target_user_id;

  -- Get betting statistics
  SELECT
    COUNT(*),
    COALESCE(SUM(bet_amount), 0),
    COALESCE(SUM(CASE WHEN bet_status = 'won' THEN actual_payout ELSE 0 END), 0),
    COUNT(*) FILTER (WHERE bet_status = 'lost'),
    COALESCE(MAX(CASE WHEN bet_status = 'won' THEN actual_payout ELSE 0 END), 0),
    COALESCE(MAX(CASE WHEN bet_status = 'lost' THEN bet_amount ELSE 0 END), 0)
  INTO total_bets, total_wagered, total_won, total_lost, biggest_win, biggest_loss
  FROM task_bets
  WHERE user_id = target_user_id
    AND bet_status IN ('won', 'lost');

  -- Calculate net profit/loss
  net_profit := total_won - (total_bets * (total_wagered / GREATEST(total_bets, 1)));

  -- Calculate win rate
  IF total_bets > 0 THEN
    win_rate := (total_bets - total_lost) * 100.0 / total_bets;
  END IF;

  -- Calculate current winning/losing streak
  WITH recent_bets AS (
    SELECT bet_status,
           ROW_NUMBER() OVER (ORDER BY settled_at DESC) as rn
    FROM task_bets
    WHERE user_id = target_user_id
      AND bet_status IN ('won', 'lost')
      AND settled_at IS NOT NULL
    ORDER BY settled_at DESC
    LIMIT 50
  ),
  streak_calc AS (
    SELECT bet_status,
           rn,
           rn - ROW_NUMBER() OVER (PARTITION BY bet_status ORDER BY rn) as streak_group
    FROM recent_bets
  )
  SELECT COUNT(*) INTO current_streak
  FROM streak_calc
  WHERE streak_group = (SELECT streak_group FROM streak_calc WHERE rn = 1);

  -- Build result
  result := jsonb_build_object(
    'user_id', target_user_id,
    'gambling_enabled', gambling_enabled,
    'current_points', current_points,
    'total_bets', total_bets,
    'total_wagered', total_wagered,
    'total_won', total_won,
    'total_lost', total_lost,
    'net_profit', net_profit,
    'win_rate', ROUND(win_rate, 2),
    'biggest_win', biggest_win,
    'biggest_loss', biggest_loss,
    'current_streak', current_streak
  );

  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_checkin_stats(target_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  total_points bigint := 0;
  total_checkins integer := 0;
  current_streak integer := 0;
  longest_streak integer := 0;
  last_checkin_date date;
  has_checked_in_today boolean := false;
  result jsonb;
BEGIN
  -- Verify access
  IF auth.uid() IS NULL OR target_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only view your own stats';
  END IF;

  -- Get total points
  SELECT COALESCE(up.total_points, 0) INTO total_points
  FROM user_points up
  WHERE up.user_id = target_user_id;

  -- Get total check-ins
  SELECT COUNT(*) INTO total_checkins
  FROM daily_checkins dc
  WHERE dc.user_id = target_user_id;

  -- Get current streak
  SELECT consecutive_days, checkin_date INTO current_streak, last_checkin_date
  FROM daily_checkins
  WHERE user_id = target_user_id
  ORDER BY checkin_date DESC
  LIMIT 1;

  -- Check if streak is still active
  IF last_checkin_date IS NOT NULL THEN
    IF last_checkin_date = CURRENT_DATE THEN
      has_checked_in_today := true;
    ELSIF last_checkin_date < CURRENT_DATE - INTERVAL '1 day' THEN
      current_streak := 0;
    END IF;
  END IF;

  -- Get longest streak
  SELECT COALESCE(MAX(consecutive_days), 0) INTO longest_streak
  FROM daily_checkins
  WHERE user_id = target_user_id;

  -- Build result
  result := jsonb_build_object(
    'user_id', target_user_id,
    'total_points', total_points,
    'total_checkins', total_checkins,
    'current_streak', COALESCE(current_streak, 0),
    'longest_streak', longest_streak,
    'last_checkin_date', last_checkin_date,
    'has_checked_in_today', has_checked_in_today
  );

  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_checkin_history(
  target_user_id uuid,
  page_size integer DEFAULT 20,
  page_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  checkins jsonb;
  total_count integer;
  result jsonb;
BEGIN
  -- Verify access
  IF auth.uid() IS NULL OR target_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only view your own history';
  END IF;

  -- Validate pagination parameters
  IF page_size IS NULL OR page_size <= 0 OR page_size > 100 THEN
    page_size := 20;
  END IF;

  IF page_offset IS NULL OR page_offset < 0 THEN
    page_offset := 0;
  END IF;

  -- Get total count
  SELECT COUNT(*) INTO total_count
  FROM daily_checkins
  WHERE user_id = target_user_id;

  -- Get paginated checkins
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', dc.id,
      'checkin_date', dc.checkin_date,
      'points_earned', dc.points_earned,
      'consecutive_days', dc.consecutive_days,
      'created_at', dc.created_at
    )
    ORDER BY dc.checkin_date DESC, dc.id DESC
  ) INTO checkins
  FROM (
    SELECT * FROM public.daily_checkins
    WHERE user_id = target_user_id
    ORDER BY checkin_date DESC, id DESC
    LIMIT page_size OFFSET page_offset
  ) dc;

  -- Build result
  result := jsonb_build_object(
    'checkins', COALESCE(checkins, '[]'::jsonb),
    'total_count', total_count,
    'page_size', page_size,
    'page_offset', page_offset,
    'has_more', (page_offset + page_size) < total_count
  );

  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_user_betting_history(
  target_user_id uuid,
  page_size integer DEFAULT 20,
  page_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  bets jsonb;
  total_count integer;
  result jsonb;
BEGIN
  -- Verify access
  IF auth.uid() IS NULL OR target_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied: can only view your own betting history';
  END IF;

  -- Validate pagination parameters
  IF page_size IS NULL OR page_size <= 0 OR page_size > 100 THEN
    page_size := 20;
  END IF;

  IF page_offset IS NULL OR page_offset < 0 THEN
    page_offset := 0;
  END IF;

  -- Get total count
  SELECT COUNT(*) INTO total_count
  FROM task_bets
  WHERE user_id = target_user_id;

  -- Get paginated bets with chain info
  SELECT jsonb_agg(
    jsonb_build_object(
      'id', tb.id,
      'session_id', tb.session_id,
      'chain_id', tb.chain_id,
      'chain_name', tb.chain_name,
      'bet_amount', tb.bet_amount,
      'bet_status', tb.bet_status,
      'potential_payout', tb.potential_payout,
      'actual_payout', tb.actual_payout,
      'points_before', tb.points_before,
      'points_after', tb.points_after,
      'created_at', tb.created_at,
      'settled_at', tb.settled_at,
      'metadata', tb.metadata
    )
    ORDER BY tb.created_at DESC, tb.id DESC
  ) INTO bets
  FROM (
    SELECT t.*, c.name AS chain_name
    FROM public.task_bets t
    LEFT JOIN public.chains c ON t.chain_id = c.id AND c.user_id = target_user_id
    WHERE t.user_id = target_user_id
    ORDER BY t.created_at DESC, t.id DESC
    LIMIT page_size OFFSET page_offset
  ) tb;

  -- Build result
  result := jsonb_build_object(
    'bets', COALESCE(bets, '[]'::jsonb),
    'total_count', total_count,
    'page_size', page_size,
    'page_offset', page_offset,
    'has_more', (page_offset + page_size) < total_count
  );

  RETURN result;
END;
$$;

-- This internal function is reachable only from trusted functions/triggers.
CREATE OR REPLACE FUNCTION public.settle_task_bet(
  bet_id uuid, task_successful boolean, completion_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  bet_record public.task_bets;
  wallet_before bigint;
  payout bigint;
BEGIN
  SELECT * INTO bet_record FROM public.task_bets WHERE id = bet_id;
  IF auth.uid() IS NULL OR bet_record.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  IF task_successful IS NULL THEN
    RAISE EXCEPTION 'Task outcome is required' USING ERRCODE = '22023';
  END IF;
  SELECT total_points INTO STRICT wallet_before FROM public.user_points
    WHERE user_id = bet_record.user_id FOR UPDATE;
  SELECT * INTO STRICT bet_record FROM public.task_bets WHERE id = bet_id FOR UPDATE;
  IF bet_record.bet_status <> 'pending' THEN
    RETURN jsonb_build_object('success', true, 'replayed', true, 'bet_id', bet_id,
      'bet_status', bet_record.bet_status, 'points_after', bet_record.points_after);
  END IF;
  payout := CASE WHEN task_successful THEN bet_record.potential_payout ELSE 0 END;
  UPDATE public.task_bets SET
    bet_status = CASE WHEN task_successful THEN 'won' ELSE 'lost' END,
    actual_payout = payout, points_after = wallet_before + payout, settled_at = now(),
    metadata = metadata || jsonb_build_object('completion_notes', completion_notes,
      'task_successful', task_successful)
  WHERE id = bet_id AND bet_status = 'pending';
  IF payout > 0 THEN
    UPDATE public.user_points SET total_points = wallet_before + payout WHERE user_id = bet_record.user_id;
    INSERT INTO public.point_transactions(user_id, transaction_type, points_change,
      points_before, points_after, reference_id, description)
    VALUES (bet_record.user_id, 'bet_won', payout, wallet_before, wallet_before + payout,
      bet_id, 'Won bet on task completion');
  END IF;
  -- Losses are recorded on task_bets; zero-value ledger entries are forbidden.
  RETURN jsonb_build_object('success', true, 'bet_id', bet_id, 'payout', payout,
    'bet_amount', bet_record.bet_amount, 'points_before', wallet_before,
    'points_after', wallet_before + payout, 'task_successful', task_successful,
    'bet_status', CASE WHEN task_successful THEN 'won' ELSE 'lost' END);
END;
$$;

CREATE OR REPLACE FUNCTION public.refund_task_bet(bet_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  bet_record public.task_bets;
  wallet_before bigint;
BEGIN
  -- A live pending bet cannot be refunded through a client RPC.
  IF pg_trigger_depth() = 0 THEN
    RAISE EXCEPTION 'Refund requires session cancellation' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO bet_record FROM public.task_bets WHERE id = bet_id;
  IF auth.uid() IS NULL OR bet_record.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  SELECT total_points INTO STRICT wallet_before FROM public.user_points
    WHERE user_id = bet_record.user_id FOR UPDATE;
  SELECT * INTO STRICT bet_record FROM public.task_bets WHERE id = bet_id FOR UPDATE;
  IF bet_record.bet_status <> 'pending' THEN
    RETURN jsonb_build_object('success', true, 'replayed', true, 'bet_id', bet_id);
  END IF;
  UPDATE public.task_bets SET bet_status = 'refunded', actual_payout = bet_amount,
    points_after = wallet_before + bet_amount, settled_at = now(),
    cancellation_reason = 'Session cancelled - bet refunded'
  WHERE id = bet_id AND bet_status = 'pending';
  UPDATE public.user_points SET total_points = wallet_before + bet_record.bet_amount
    WHERE user_id = bet_record.user_id;
  INSERT INTO public.point_transactions(user_id, transaction_type, points_change,
    points_before, points_after, reference_id, description)
  VALUES(bet_record.user_id, 'bet_refunded', bet_record.bet_amount, wallet_before,
    wallet_before + bet_record.bet_amount, bet_id, 'Session cancellation refund');
  RETURN jsonb_build_object('success', true, 'bet_id', bet_id,
    'refund_amount', bet_record.bet_amount, 'points_before', wallet_before,
    'points_after', wallet_before + bet_record.bet_amount);
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_session_end_betting()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE pending_bet record;
BEGIN
  -- Account deletion cascades remove the entire wallet and audit history too.
  -- There is no remaining account to refund; do not block auth.users cleanup.
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = OLD.user_id) THEN RETURN OLD; END IF;
  FOR pending_bet IN SELECT id FROM public.task_bets
    WHERE session_id = OLD.id AND bet_status = 'pending' ORDER BY id
  LOOP
    -- Any failed refund aborts session deletion as well.
    PERFORM public.refund_task_bet(pending_bet.id);
  END LOOP;
  RETURN OLD;
END;
$$;

-- Immutable completion tombstones survive history edits/deletion and close the
-- lost-response -> stale pause/upsert resurrection window.
CREATE TABLE public.completed_session_receipts (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id uuid NOT NULL,
  chain_id uuid NOT NULL,
  started_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, session_id)
);
CREATE INDEX completed_session_receipts_identity
  ON public.completed_session_receipts(user_id, chain_id, started_at);
ALTER TABLE public.completed_session_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.completed_session_receipts FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.reject_consumed_active_session()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.completed_session_receipts r WHERE r.user_id = NEW.user_id
      AND (r.session_id = NEW.id OR (r.chain_id = NEW.chain_id
        AND date_trunc('milliseconds', r.started_at) = date_trunc('milliseconds', NEW.started_at)))
  ) OR EXISTS (
    -- Compatibility for explicit completion metadata predating the tombstone.
    -- Imported history without a session link is never used to infer identity.
    SELECT 1 FROM public.completion_history h WHERE h.user_id = NEW.user_id
      AND (h.metadata ->> 'session_id' = NEW.id::text
        OR (h.chain_id = NEW.chain_id AND h.metadata ->> 'session_id' IS NOT NULL
          AND date_trunc('milliseconds', CASE
            WHEN pg_input_is_valid(h.metadata ->> 'session_started_at', 'timestamptz')
            THEN (h.metadata ->> 'session_started_at')::timestamptz END)
              = date_trunc('milliseconds', NEW.started_at)))
  ) THEN
    RAISE EXCEPTION 'Session already completed; reload before starting a new session' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER reject_consumed_active_session
  BEFORE INSERT OR UPDATE ON public.active_sessions
  FOR EACH ROW EXECUTE FUNCTION public.reject_consumed_active_session();

CREATE OR REPLACE FUNCTION public.auto_settle_session_bets()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  target_session public.active_sessions;
  pending_bet record;
BEGIN
  -- Imported/legacy history must never settle an unrelated active session.
  IF NEW.metadata ->> 'session_id' IS NULL THEN RETURN NEW; END IF;
  IF auth.uid() IS NULL OR NEW.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  -- Serialize completion with stale INSERT/UPDATE requests using a new UUID.
  LOCK TABLE public.active_sessions IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO target_session FROM public.active_sessions
    WHERE id = (NEW.metadata ->> 'session_id')::uuid FOR UPDATE;
  IF NOT FOUND OR target_session.user_id IS DISTINCT FROM NEW.user_id
    OR target_session.chain_id IS DISTINCT FROM NEW.chain_id THEN
    RAISE EXCEPTION 'Completion session ownership mismatch' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.completed_session_receipts(user_id, session_id, chain_id, started_at)
    VALUES(target_session.user_id, target_session.id, target_session.chain_id, target_session.started_at);
  -- Store the authoritative session time, never an unverified client value.
  UPDATE public.completion_history SET metadata = NEW.metadata ||
    jsonb_build_object('session_started_at', target_session.started_at)
    WHERE id = NEW.id;
  FOR pending_bet IN SELECT id FROM public.task_bets
    WHERE session_id = target_session.id AND bet_status = 'pending' ORDER BY id
  LOOP
    PERFORM public.settle_task_bet(pending_bet.id, NEW.was_successful, NEW.reason_for_failure);
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS public.betting_completion_operations (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  session_id uuid NOT NULL,
  was_successful boolean NOT NULL,
  completion_notes text,
  result jsonb NOT NULL,
  PRIMARY KEY(user_id, session_id)
);
ALTER TABLE public.betting_completion_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.betting_completion_operations FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.complete_task_with_betting(
  p_session_id uuid, p_was_successful boolean DEFAULT true, p_completion_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  session_record public.active_sessions;
  prior public.betting_completion_operations;
  completion_id uuid;
  settled_count integer;
  result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501'; END IF;
  IF p_was_successful IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'Session and outcome required' USING ERRCODE = '22023';
  END IF;
  -- Serialize retries even after active_sessions has been deleted.
  PERFORM pg_advisory_xact_lock(hashtextextended('betting-completion:' || p_session_id::text, 0));
  SELECT * INTO prior FROM public.betting_completion_operations
    WHERE user_id = auth.uid() AND session_id = p_session_id;
  IF FOUND THEN
    IF prior.was_successful IS DISTINCT FROM p_was_successful
      OR prior.completion_notes IS DISTINCT FROM p_completion_notes THEN
      RAISE EXCEPTION 'Completion retry has a different outcome' USING ERRCODE = '22023';
    END IF;
    RETURN prior.result;
  END IF;
  -- Match the storage-operation table lock order (history before sessions).
  LOCK TABLE public.completion_history, public.active_sessions IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO session_record FROM public.active_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR session_record.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Session not found or access denied' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chains WHERE id = session_record.chain_id AND user_id = auth.uid()) THEN
    RAISE EXCEPTION 'Session chain ownership mismatch' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO settled_count FROM public.task_bets
    WHERE session_id = p_session_id AND bet_status = 'pending';
  INSERT INTO public.completion_history(chain_id, user_id, duration, was_successful,
    reason_for_failure, metadata)
  VALUES(session_record.chain_id, session_record.user_id, session_record.duration,
    p_was_successful, CASE WHEN NOT p_was_successful THEN p_completion_notes ELSE NULL END,
    jsonb_build_object('session_id', p_session_id, 'session_started_at', session_record.started_at,
      'completion_method', 'explicit_api_call'))
  RETURNING id INTO completion_id;
  DELETE FROM public.active_sessions WHERE user_id = session_record.user_id
    AND chain_id = session_record.chain_id
    AND date_trunc('milliseconds', started_at) = date_trunc('milliseconds', session_record.started_at);
  result := jsonb_build_object('success', true, 'session_id', p_session_id,
    'completion_history_id', completion_id, 'task_successful', p_was_successful,
    'settled_bets_count', settled_count, 'message', 'Task completed and bets settled');
  INSERT INTO public.betting_completion_operations VALUES
    (auth.uid(), p_session_id, p_was_successful, p_completion_notes, result);
  RETURN result;
END;
$$;

-- Harden existing SECURITY DEFINER entry points; maintenance functions remain
-- callable by the owner, never implicitly by PUBLIC.
DO $$
DECLARE fn record;
BEGIN
  FOR fn IN SELECT p.oid::regprocedure AS signature, p.proname
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prosecdef
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = pg_catalog, public, pg_temp', fn.signature);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', fn.signature);
    IF fn.proname = ANY(ARRAY[
      'place_task_bet', 'perform_daily_checkin', 'get_user_checkin_stats',
      'get_user_checkin_history', 'get_user_gambling_stats', 'get_user_betting_history',
      'create_write_session', 'complete_write_session', 'create_import_session',
      'get_write_session_status', 'complete_task_with_betting',
      'create_rsip_nodes_with_meta', 'archive_rsip_nodes_and_remove'
    ]) THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', fn.signature);
    END IF;
  END LOOP;
END;
$$;
COMMIT;


-- ===== 20260920001000_add_storage_operation_commit.sql =====
-- A compare-and-swap transaction for bounded user collections. No HTTP delete/insert gap.
BEGIN;
CREATE TABLE public.storage_operation_commits (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id text NOT NULL,
  payload_hash text NOT NULL CHECK (length(payload_hash) = 64),
  committed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, operation_id),
  CHECK (length(operation_id) BETWEEN 1 AND 200)
);
ALTER TABLE public.storage_operation_commits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.storage_operation_commits FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.commit_storage_operation(p_operation_id text, p_changes jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
  allowed_tables text[] := ARRAY['chains', 'rsip_groups', 'rsip_nodes', 'rsip_meta',
    'rsip_policy_library', 'rsip_run_history', 'rsip_execution_records', 'rsip_task_links',
    'completion_history', 'active_sessions'];
  table_name text;
  change jsonb;
  prior_hash text;
  request_hash text;
  actual_rows jsonb;
  expected_rows jsonb;
  column_names text;
  update_columns text;
  primary_columns text;
  key_match text;
  primary_names text[];
  keys text[];
  grouped_rows jsonb;
  changed_columns text;
  incoming_key_match text;
  fk_match text;
  foreign_key record;
  invalid_reference boolean;
BEGIN
  IF caller IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501'; END IF;
  IF p_operation_id IS NULL OR length(p_operation_id) NOT BETWEEN 1 AND 200
    OR jsonb_typeof(p_changes) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_changes) NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'Invalid storage operation' USING ERRCODE = '22023';
  END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_changes) c
    WHERE jsonb_typeof(c) <> 'object' OR NOT (c ->> 'table' = ANY(allowed_tables))
      OR c ->> 'table' IS NULL OR jsonb_typeof(c -> 'before') IS DISTINCT FROM 'array'
      OR jsonb_typeof(c -> 'after') IS DISTINCT FROM 'array')
    OR (SELECT count(DISTINCT c ->> 'table') FROM jsonb_array_elements(p_changes) c)
      <> jsonb_array_length(p_changes) THEN
    RAISE EXCEPTION 'Invalid or duplicate collection' USING ERRCODE = '22023';
  END IF;
  -- This lock also makes concurrent identical operation IDs wait for their receipt.
  PERFORM pg_advisory_xact_lock(hashtextextended('storage-operation:' || caller::text || ':' || p_operation_id, 0));
  request_hash := encode(sha256(convert_to(p_changes::text, 'UTF8')), 'hex');
  SELECT payload_hash INTO prior_hash FROM public.storage_operation_commits
    WHERE user_id = caller AND operation_id = p_operation_id;
  IF FOUND THEN
    IF prior_hash IS DISTINCT FROM request_hash THEN
      RAISE EXCEPTION 'Operation ID reused with different content' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object('success', true, 'operation_id', p_operation_id, 'replayed', true);
  END IF;
  -- A fixed global order prevents deadlocks between collection transactions.
  -- Lock all affected FK parent/child collections, including those omitted by a
  -- caller, so cascades and ordinary table writes cannot interleave with the CAS.
  FOREACH table_name IN ARRAY allowed_tables LOOP
    EXECUTE format('LOCK TABLE public.%I IN SHARE ROW EXCLUSIVE MODE', table_name);
  END LOOP;
  FOR change IN SELECT value FROM jsonb_array_elements(p_changes) LOOP
    table_name := change ->> 'table';
    IF EXISTS(SELECT 1 FROM jsonb_array_elements((change -> 'before') || (change -> 'after')) r
      WHERE jsonb_typeof(r) <> 'object' OR (r ->> 'user_id') IS DISTINCT FROM caller::text) THEN
      RAISE EXCEPTION 'Collection ownership mismatch' USING ERRCODE = '42501';
    END IF;
    EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), ''[]''::jsonb)
      FROM public.%I t WHERE user_id = $1', table_name) INTO actual_rows USING caller;
    SELECT coalesce(jsonb_agg(r ORDER BY r::text), '[]'::jsonb) INTO expected_rows
      FROM jsonb_array_elements(change -> 'before') r;
    IF actual_rows IS DISTINCT FROM expected_rows THEN
      RAISE EXCEPTION 'Collection changed: %', table_name USING ERRCODE = '40001';
    END IF;
  END LOOP;

  -- Upsert parents before children. Group rows by supplied fields so omitted
  -- fields on new rows retain PostgreSQL DEFAULT values.
  FOREACH table_name IN ARRAY allowed_tables LOOP
    SELECT value INTO change FROM jsonb_array_elements(p_changes) WHERE value ->> 'table' = table_name;
    IF NOT FOUND THEN CONTINUE; END IF;
    SELECT array_agg(a.attname ORDER BY k.ord), string_agg(format('%I', a.attname), ', ' ORDER BY k.ord)
    INTO primary_names, primary_columns
    FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    WHERE i.indrelid = format('public.%I', table_name)::regclass AND i.indisprimary;
    IF primary_names IS NULL THEN RAISE EXCEPTION 'Collection lacks primary key'; END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(change -> 'after') r,
      unnest(primary_names) pk WHERE r ->> pk IS NULL) THEN
      RAISE EXCEPTION 'Stable collection primary key is required' USING ERRCODE = '22023';
    END IF;
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM jsonb_populate_recordset(NULL::public.%I, $1)
      GROUP BY %s HAVING count(*) > 1)', table_name, primary_columns)
    INTO invalid_reference USING change -> 'after';
    IF invalid_reference THEN RAISE EXCEPTION 'Duplicate collection primary key' USING ERRCODE = '22023'; END IF;
    FOR keys, grouped_rows IN
      SELECT fields, jsonb_agg(row_value) FROM (
        SELECT r AS row_value, ARRAY(SELECT jsonb_object_keys(r) ORDER BY 1) AS fields
        FROM jsonb_array_elements(change -> 'after') r
      ) grouped GROUP BY fields
    LOOP
      IF EXISTS(SELECT 1 FROM unnest(keys) field WHERE NOT EXISTS(
        SELECT 1 FROM pg_attribute WHERE attrelid = format('public.%I', table_name)::regclass
          AND attname = field AND attnum > 0 AND NOT attisdropped)) THEN
        RAISE EXCEPTION 'Unknown collection field' USING ERRCODE = '22023';
      END IF;
      SELECT string_agg(format('%I', field), ', '),
        string_agg(format('%I = EXCLUDED.%I', field, field), ', ')
        FILTER (WHERE NOT(field = ANY(primary_names)))
      INTO column_names, update_columns FROM unnest(keys) field;
      SELECT string_agg(format('target.%1$I = incoming.%1$I', field), ' AND ')
      INTO incoming_key_match FROM unnest(primary_names) field;
      EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.%1$I target
        JOIN jsonb_populate_recordset(NULL::public.%1$I, $1) incoming ON %2$s
        WHERE target.user_id IS DISTINCT FROM $2)', table_name, incoming_key_match)
      INTO invalid_reference USING grouped_rows, caller;
      IF invalid_reference THEN
        RAISE EXCEPTION 'Row belongs to another user' USING ERRCODE = '42501';
      END IF;
      SELECT string_agg(format('target.%1$I IS DISTINCT FROM EXCLUDED.%1$I', field), ' OR ')
      INTO changed_columns FROM unnest(keys) field;
      update_columns := coalesce(update_columns, 'user_id = EXCLUDED.user_id');
      EXECUTE format('INSERT INTO public.%1$I AS target (%2$s)
        SELECT %2$s FROM jsonb_populate_recordset(NULL::public.%1$I, $1)
        ON CONFLICT (%3$s) DO UPDATE SET %4$s
        WHERE target.user_id = $2 AND (%5$s)',
        table_name, column_names, primary_columns, update_columns, changed_columns)
      USING grouped_rows, caller;
    END LOOP;
  END LOOP;

  -- SECURITY DEFINER bypasses RLS: validate ownership across each actual FK too.
  FOR foreign_key IN
    SELECT c.conrelid::regclass AS source_table, c.confrelid::regclass AS target_table,
      string_agg(format('s.%I = t.%I', a.attname, b.attname), ' AND ' ORDER BY x.ord) AS predicate
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY x(src, dst, ord)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.src
    JOIN pg_attribute b ON b.attrelid = c.confrelid AND b.attnum = x.dst
    WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
      AND c.conrelid IN (SELECT format('public.%I', value ->> 'table')::regclass FROM jsonb_array_elements(p_changes))
      AND EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid = c.confrelid AND attname = 'user_id')
    GROUP BY c.oid, c.conrelid, c.confrelid
  LOOP
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM %s s JOIN %s t ON %s
      WHERE s.user_id = $1 AND t.user_id IS DISTINCT FROM $1)',
      foreign_key.source_table, foreign_key.target_table, foreign_key.predicate)
    INTO invalid_reference USING caller;
    IF invalid_reference THEN RAISE EXCEPTION 'Cross-user relation' USING ERRCODE = '42501'; END IF;
  END LOOP;

  -- Remove children before parents; active_sessions is always last so a new
  -- completion has settled its bet before cancellation/refund triggers can run.
  FOREACH table_name IN ARRAY ARRAY['rsip_task_links', 'rsip_execution_records',
    'rsip_nodes', 'rsip_groups', 'rsip_meta', 'rsip_policy_library', 'rsip_run_history',
    'completion_history', 'chains', 'active_sessions'] LOOP
    SELECT value INTO change FROM jsonb_array_elements(p_changes) WHERE value ->> 'table' = table_name;
    IF NOT FOUND THEN CONTINUE; END IF;
    SELECT string_agg(format('to_jsonb(t.%1$I) = r -> %2$L', a.attname, a.attname), ' AND ')
    INTO key_match FROM pg_index i
    CROSS JOIN LATERAL unnest(i.indkey) k(attnum)
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    WHERE i.indrelid = format('public.%I', table_name)::regclass AND i.indisprimary;
    -- Do not silently cascade into a collection absent from this operation.
    FOR foreign_key IN
      SELECT c.conrelid::regclass AS source_table,
        string_agg(format('s.%I = t.%I', a.attname, b.attname), ' AND ' ORDER BY x.ord) AS predicate
      FROM pg_constraint c
      CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY x(src, dst, ord)
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.src
      JOIN pg_attribute b ON b.attrelid = c.confrelid AND b.attnum = x.dst
      WHERE c.contype = 'f' AND c.confrelid = format('public.%I', table_name)::regclass
        AND c.conrelid NOT IN (SELECT format('public.%I', value ->> 'table')::regclass
          FROM jsonb_array_elements(p_changes))
      GROUP BY c.oid, c.conrelid
    LOOP
      EXECUTE format('SELECT EXISTS(SELECT 1 FROM public.%I t JOIN %s s ON %s
        WHERE t.user_id = $1 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements($2) r WHERE %s))',
        table_name, foreign_key.source_table, foreign_key.predicate, key_match)
      INTO invalid_reference USING caller, change -> 'after';
      IF invalid_reference THEN
        RAISE EXCEPTION 'Deletion affects an omitted collection: %', foreign_key.source_table
          USING ERRCODE = '23000';
      END IF;
    END LOOP;
    EXECUTE format('DELETE FROM public.%I t WHERE t.user_id = $1
      AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements($2) r WHERE %s)', table_name, key_match)
      USING caller, change -> 'after';
  END LOOP;
  -- Cascades within included collections must preserve every requested row
  -- and relation. A vanished child or implicit SET NULL aborts the transaction.
  FOR change IN SELECT value FROM jsonb_array_elements(p_changes) LOOP
    table_name := change ->> 'table';
    SELECT string_agg(format('t.%1$I = r.%1$I', a.attname), ' AND ')
    INTO key_match FROM pg_index i CROSS JOIN LATERAL unnest(i.indkey) k(attnum)
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    WHERE i.indrelid = format('public.%I', table_name)::regclass AND i.indisprimary;
    SELECT string_agg(format('(NOT (input ? %2$L) OR t.%1$I IS NOT DISTINCT FROM r.%1$I)', a.attname, a.attname), ' AND ')
    INTO fk_match FROM pg_attribute a WHERE a.attrelid = format('public.%I', table_name)::regclass
      AND a.attnum IN (SELECT unnest(c.conkey) FROM pg_constraint c
        WHERE c.conrelid = a.attrelid AND c.contype = 'f');
    EXECUTE format('SELECT EXISTS(SELECT 1 FROM jsonb_array_elements($1) input
      CROSS JOIN LATERAL jsonb_populate_record(NULL::public.%1$I, input) r
      WHERE NOT EXISTS(SELECT 1 FROM public.%1$I t WHERE t.user_id = $2 AND %2$s AND %3$s))',
      table_name, key_match, coalesce(fk_match, 'true'))
    INTO invalid_reference USING change -> 'after', caller;
    IF invalid_reference THEN
      RAISE EXCEPTION 'Deletion changed a retained row or relation in %', table_name USING ERRCODE = '23000';
    END IF;
  END LOOP;
  INSERT INTO public.storage_operation_commits(user_id, operation_id, payload_hash)
    VALUES(caller, p_operation_id, request_hash);
  RETURN jsonb_build_object('success', true, 'operation_id', p_operation_id, 'replayed', false);
END;
$$;
REVOKE ALL ON FUNCTION public.commit_storage_operation(text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.commit_storage_operation(text, jsonb) TO authenticated;
COMMIT;


-- ===== 20261119000000_serialize_completion_timestamps.sql =====
-- complete_task_with_betting inserted completion_history.completed_at from the
-- column default now(), the transaction start time. Two completions of the same
-- chain whose transactions started in the same microsecond collided on
-- idx_completion_history_user_chain_completed_unique and the RPC failed.
-- clock_timestamp() is read after the table lock, which serializes completions,
-- so each completion gets a later timestamp than the one committed before it.
-- CREATE OR REPLACE keeps the function's owner and grants.
BEGIN;
CREATE OR REPLACE FUNCTION public.complete_task_with_betting(
  p_session_id uuid, p_was_successful boolean DEFAULT true, p_completion_notes text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  session_record public.active_sessions;
  prior public.betting_completion_operations;
  completion_id uuid;
  settled_count integer;
  result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501'; END IF;
  IF p_was_successful IS NULL OR p_session_id IS NULL THEN
    RAISE EXCEPTION 'Session and outcome required' USING ERRCODE = '22023';
  END IF;
  -- Serialize retries even after active_sessions has been deleted.
  PERFORM pg_advisory_xact_lock(hashtextextended('betting-completion:' || p_session_id::text, 0));
  SELECT * INTO prior FROM public.betting_completion_operations
    WHERE user_id = auth.uid() AND session_id = p_session_id;
  IF FOUND THEN
    IF prior.was_successful IS DISTINCT FROM p_was_successful
      OR prior.completion_notes IS DISTINCT FROM p_completion_notes THEN
      RAISE EXCEPTION 'Completion retry has a different outcome' USING ERRCODE = '22023';
    END IF;
    RETURN prior.result;
  END IF;
  -- Match the storage-operation table lock order (history before sessions).
  LOCK TABLE public.completion_history, public.active_sessions IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO session_record FROM public.active_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR session_record.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Session not found or access denied' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chains WHERE id = session_record.chain_id AND user_id = auth.uid()) THEN
    RAISE EXCEPTION 'Session chain ownership mismatch' USING ERRCODE = '42501';
  END IF;
  SELECT count(*) INTO settled_count FROM public.task_bets
    WHERE session_id = p_session_id AND bet_status = 'pending';
  INSERT INTO public.completion_history(chain_id, user_id, completed_at, duration,
    was_successful, reason_for_failure, metadata)
  VALUES(session_record.chain_id, session_record.user_id, clock_timestamp(), session_record.duration,
    p_was_successful, CASE WHEN NOT p_was_successful THEN p_completion_notes ELSE NULL END,
    jsonb_build_object('session_id', p_session_id, 'session_started_at', session_record.started_at,
      'completion_method', 'explicit_api_call'))
  RETURNING id INTO completion_id;
  DELETE FROM public.active_sessions WHERE user_id = session_record.user_id
    AND chain_id = session_record.chain_id
    AND date_trunc('milliseconds', started_at) = date_trunc('milliseconds', session_record.started_at);
  result := jsonb_build_object('success', true, 'session_id', p_session_id,
    'completion_history_id', completion_id, 'task_successful', p_was_successful,
    'settled_bets_count', settled_count, 'message', 'Task completed and bets settled');
  INSERT INTO public.betting_completion_operations VALUES
    (auth.uid(), p_session_id, p_was_successful, p_completion_notes, result);
  RETURN result;
END;
$$;
COMMIT;


-- ===== 20261124000000_add_delete_my_account.sql =====
-- Lets a signed-in user permanently delete their own account.
--
-- Every user-owned public table references auth.users ON DELETE CASCADE, so
-- removing the auth row removes all of the caller's cloud data in this single
-- transaction (the database tests assert that no table is left without the
-- cascade). Supabase's own auth tables (identities, sessions, refresh tokens)
-- also cascade from auth.users. The function owner must be able to delete from
-- auth.users, which the Supabase migration role (postgres) can.
BEGIN;

CREATE OR REPLACE FUNCTION public.delete_my_account()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  caller uuid := auth.uid();
BEGIN
  IF caller IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  DELETE FROM auth.users WHERE id = caller;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Account not found' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_my_account() TO authenticated;

COMMIT;


-- ===== 20261124010000_add_exception_rule_sets.sql =====
-- Exception rules and their usage records, synced per user.
--
-- The client's RuleStore replaces each list as a whole, so each user has one
-- row holding both lists as JSON arrays. `revision` is a compare-and-swap
-- token: a write must name the revision it read and advance it by exactly one,
-- so a device holding stale rules cannot overwrite another device's edit.
BEGIN;

CREATE TABLE public.exception_rule_sets (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  rules jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(rules) = 'array'),
  usage_records jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(usage_records) = 'array'),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.exception_rule_sets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exception_rule_sets FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.exception_rule_sets TO authenticated;

CREATE POLICY exception_rule_sets_select ON public.exception_rule_sets
  FOR SELECT TO authenticated USING ((SELECT auth.uid()) = user_id);
CREATE POLICY exception_rule_sets_insert ON public.exception_rule_sets
  FOR INSERT TO authenticated WITH CHECK ((SELECT auth.uid()) = user_id);
CREATE POLICY exception_rule_sets_update ON public.exception_rule_sets
  FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE FUNCTION public.exception_rule_sets_advance_revision()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.revision <> 1 THEN
    RAISE EXCEPTION 'A new rule set starts at revision 1' USING ERRCODE = '22023';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
      RAISE EXCEPTION 'Rule sets cannot change owner' USING ERRCODE = '42501';
    END IF;
    IF NEW.revision <> OLD.revision + 1 THEN
      RAISE EXCEPTION 'Stale exception rule revision' USING ERRCODE = '40001';
    END IF;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.exception_rule_sets_advance_revision()
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER exception_rule_sets_advance_revision
  BEFORE INSERT OR UPDATE ON public.exception_rule_sets
  FOR EACH ROW EXECUTE FUNCTION public.exception_rule_sets_advance_revision();

COMMIT;


-- ===== 20261124020000_add_sync_fingerprint.sql =====
-- A short digest of everything the app loads for the caller. A client reads it
-- when it goes to the background and again when it returns; a different value
-- means another device changed the data meanwhile, so the client offers a
-- reload instead of writing over the newer rows.
--
-- SECURITY INVOKER: RLS limits every table to the caller's rows. Append-only
-- history is summarised by count and latest timestamp to keep the call cheap.
BEGIN;

CREATE FUNCTION public.get_sync_fingerprint()
RETURNS text LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT md5(concat_ws('|',
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.chains t WHERE t.user_id = auth.uid()),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.active_sessions t WHERE t.user_id = auth.uid()),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.scheduled_sessions t WHERE t.user_id = auth.uid()),
    (SELECT count(*) || ':' || coalesce(max(t.completed_at)::text, '')
       FROM public.completion_history t WHERE t.user_id = auth.uid()),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.rsip_nodes t WHERE t.user_id = auth.uid()),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.rsip_meta t WHERE t.user_id = auth.uid()),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.rsip_groups t WHERE t.user_id = auth.uid()),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.rsip_policy_library t WHERE t.user_id = auth.uid()),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.rsip_run_history t WHERE t.user_id = auth.uid()),
    (SELECT md5(coalesce(string_agg(t::text, ',' ORDER BY t::text), ''))
       FROM public.rsip_task_links t WHERE t.user_id = auth.uid()),
    (SELECT count(*) || ':' || coalesce(max(t.created_at)::text, '')
       FROM public.rsip_execution_records t WHERE t.user_id = auth.uid()),
    (SELECT t.revision::text
       FROM public.exception_rule_sets t WHERE t.user_id = auth.uid())
  ))
$$;

REVOKE ALL ON FUNCTION public.get_sync_fingerprint() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_sync_fingerprint() TO authenticated;

COMMIT;


-- ===== 20261126000000_add_pet_state.sql =====
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


-- ===== 20261126001000_fix_rsip_meta_mode_update.sql =====
-- Keep the stored daily-limit mode aligned with the creation request. The
-- original function inserted allow_multiple_per_day but ignored it on conflict,
-- so a mode switch could silently revert after reload.
BEGIN;
CREATE OR REPLACE FUNCTION public.create_rsip_nodes_with_meta(
  p_intent_key text,
  p_nodes jsonb,
  p_meta jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_requested_node_ids uuid[];
  v_recorded_request_ids uuid[];
  v_intent_node_ids uuid[];
  v_nodes_result jsonb;
  v_meta_result jsonb;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '28000';
  END IF;

  IF p_nodes IS NULL OR jsonb_typeof(p_nodes) <> 'array' THEN
    RAISE EXCEPTION 'p_nodes must be a JSON array'
      USING ERRCODE = '22023';
  END IF;
  IF p_intent_key IS NULL OR btrim(p_intent_key) = '' THEN
    RAISE EXCEPTION 'p_intent_key must not be empty'
      USING ERRCODE = '22023';
  END IF;
  IF p_meta IS NULL OR jsonb_typeof(p_meta) <> 'object' THEN
    RAISE EXCEPTION 'p_meta must be a JSON object'
      USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_nodes) AS item
    GROUP BY (item ->> 'id')::uuid
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'p_nodes contains duplicate node ids'
      USING ERRCODE = '22023';
  END IF;

  SELECT COALESCE(
    array_agg(node_id ORDER BY node_id),
    ARRAY[]::uuid[]
  )
  INTO v_requested_node_ids
  FROM (
    SELECT DISTINCT (item ->> 'id')::uuid AS node_id
    FROM jsonb_array_elements(p_nodes) AS item
  ) AS requested;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_user_id::text || ':create_nodes_with_meta:' || p_intent_key,
      0
    )
  );

  SELECT intent.request_node_ids, intent.affected_node_ids
  INTO v_recorded_request_ids, v_intent_node_ids
  FROM public.rsip_atomic_intents AS intent
  WHERE intent.user_id = v_user_id
    AND intent.intent_kind = 'create_nodes_with_meta'
    AND intent.intent_key = p_intent_key;

  IF FOUND THEN
    IF v_recorded_request_ids <> v_requested_node_ids THEN
      RAISE EXCEPTION 'RSIP creation intent key was reused for another request'
        USING ERRCODE = '22023';
    END IF;

    SELECT COALESCE(
      jsonb_agg(to_jsonb(node) ORDER BY node.sort_order, node.id),
      '[]'::jsonb
    )
    INTO v_nodes_result
    FROM public.rsip_nodes AS node
    WHERE node.user_id = v_user_id
      AND node.id = ANY(v_intent_node_ids);

    SELECT COALESCE(to_jsonb(meta), '{}'::jsonb)
    INTO v_meta_result
    FROM public.rsip_meta AS meta
    WHERE meta.user_id = v_user_id;

    RETURN jsonb_build_object(
      'nodes', v_nodes_result,
      'meta', COALESCE(v_meta_result, '{}'::jsonb)
    );
  END IF;

  -- Keep referenced rows stable until this transaction has inserted and
  -- verified the batch. Missing parents/groups are rejected by their FKs.
  PERFORM parent.id
  FROM public.rsip_nodes AS parent
  JOIN jsonb_array_elements(p_nodes) AS item
    ON parent.id = NULLIF(item ->> 'parent_id', '')::uuid
  ORDER BY parent.id
  FOR KEY SHARE OF parent;

  PERFORM node_group.id
  FROM public.rsip_groups AS node_group
  JOIN jsonb_array_elements(p_nodes) AS item
    ON node_group.id = NULLIF(item ->> 'group_id', '')::uuid
  ORDER BY node_group.id
  FOR KEY SHARE OF node_group;

  -- SECURITY DEFINER must not permit an id collision to overwrite another user.
  IF EXISTS (
    SELECT 1
    FROM public.rsip_nodes AS existing
    JOIN jsonb_array_elements(p_nodes) AS item
      ON existing.id = (item ->> 'id')::uuid
    WHERE existing.user_id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'RSIP node id belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  -- A supplied parent may be pre-existing or part of this batch, but it may
  -- never point into another user's tree.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_nodes) AS item
    JOIN public.rsip_nodes AS parent
      ON parent.id = NULLIF(item ->> 'parent_id', '')::uuid
    WHERE parent.user_id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'RSIP parent node belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_nodes) AS item
    JOIN public.rsip_groups AS node_group
      ON node_group.id = NULLIF(item ->> 'group_id', '')::uuid
    WHERE node_group.user_id <> v_user_id
  ) THEN
    RAISE EXCEPTION 'RSIP group belongs to another user'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.rsip_nodes AS existing (
    id,
    user_id,
    parent_id,
    title,
    rule,
    sort_order,
    use_timer,
    timer_minutes,
    created_at,
    emoji,
    type,
    group_id,
    reinforcement_level,
    max_reinforcement_level,
    cumulative_execution_days,
    is_passive,
    split_from_goal,
    stability_phase,
    phase_started_at,
    last_executed_at,
    last_violated_at,
    consecutive_executions,
    consecutive_violations,
    total_executions,
    total_violations
  )
  SELECT
    (item ->> 'id')::uuid,
    v_user_id,
    NULLIF(item ->> 'parent_id', '')::uuid,
    item ->> 'title',
    item ->> 'rule',
    COALESCE((item ->> 'sort_order')::integer, 0),
    COALESCE((item ->> 'use_timer')::boolean, false),
    NULLIF(item ->> 'timer_minutes', '')::integer,
    COALESCE((item ->> 'created_at')::timestamptz, now()),
    NULLIF(item ->> 'emoji', ''),
    NULLIF(item ->> 'type', ''),
    NULLIF(item ->> 'group_id', '')::uuid,
    COALESCE((item ->> 'reinforcement_level')::integer, 0),
    COALESCE((item ->> 'max_reinforcement_level')::integer, 0),
    COALESCE((item ->> 'cumulative_execution_days')::integer, 0),
    COALESCE((item ->> 'is_passive')::boolean, false),
    NULLIF(item ->> 'split_from_goal', ''),
    COALESCE(NULLIF(item ->> 'stability_phase', ''), 'E0'),
    NULLIF(item ->> 'phase_started_at', '')::timestamptz,
    NULLIF(item ->> 'last_executed_at', '')::timestamptz,
    NULLIF(item ->> 'last_violated_at', '')::timestamptz,
    COALESCE((item ->> 'consecutive_executions')::integer, 0),
    COALESCE((item ->> 'consecutive_violations')::integer, 0),
    COALESCE((item ->> 'total_executions')::integer, 0),
    COALESCE((item ->> 'total_violations')::integer, 0)
  FROM jsonb_array_elements(p_nodes) AS item
  ON CONFLICT (id) DO NOTHING;

  -- ON CONFLICT may have waited for a concurrent transaction. Re-read on a
  -- fresh statement snapshot and fail the whole transaction unless every id
  -- now resolves to this user with tenant-safe persisted references.
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_nodes) AS item
    LEFT JOIN public.rsip_nodes AS persisted
      ON persisted.id = (item ->> 'id')::uuid
    LEFT JOIN public.rsip_nodes AS persisted_parent
      ON persisted_parent.id = persisted.parent_id
    LEFT JOIN public.rsip_groups AS persisted_group
      ON persisted_group.id = persisted.group_id
    WHERE persisted.id IS NULL
      OR persisted.user_id <> v_user_id
      OR (
        persisted.parent_id IS NOT NULL
        AND persisted_parent.user_id IS DISTINCT FROM v_user_id
      )
      OR (
        persisted.group_id IS NOT NULL
        AND persisted_group.user_id IS DISTINCT FROM v_user_id
      )
  ) THEN
    RAISE EXCEPTION 'RSIP node batch failed tenant ownership verification'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.rsip_meta AS existing (
    user_id,
    last_added_at,
    allow_multiple_per_day,
    last_tree_opened_at,
    daily_tree_open_required,
    tree_open_streak,
    current_run_number,
    current_run_started_at
  )
  VALUES (
    v_user_id,
    NULLIF(p_meta ->> 'last_added_at', '')::timestamptz,
    COALESCE((p_meta ->> 'allow_multiple_per_day')::boolean, false),
    NULLIF(p_meta ->> 'last_tree_opened_at', '')::timestamptz,
    COALESCE((p_meta ->> 'daily_tree_open_required')::boolean, false),
    COALESCE((p_meta ->> 'tree_open_streak')::integer, 0),
    NULLIF(p_meta ->> 'current_run_number', '')::integer,
    NULLIF(p_meta ->> 'current_run_started_at', '')::timestamptz
  )
  ON CONFLICT (user_id) DO UPDATE SET
    last_added_at = CASE
      WHEN existing.last_added_at IS NULL THEN EXCLUDED.last_added_at
      WHEN EXCLUDED.last_added_at IS NULL THEN existing.last_added_at
      ELSE GREATEST(existing.last_added_at, EXCLUDED.last_added_at)
    END,
    allow_multiple_per_day = EXCLUDED.allow_multiple_per_day,
    current_run_number = COALESCE(
      existing.current_run_number,
      EXCLUDED.current_run_number
    ),
    current_run_started_at = COALESCE(
      existing.current_run_started_at,
      EXCLUDED.current_run_started_at
    );

  v_intent_node_ids := v_requested_node_ids;
  INSERT INTO public.rsip_atomic_intents (
    user_id,
    intent_kind,
    intent_key,
    request_node_ids,
    affected_node_ids
  )
  VALUES (
    v_user_id,
    'create_nodes_with_meta',
    p_intent_key,
    v_requested_node_ids,
    v_intent_node_ids
  );

  SELECT COALESCE(
    jsonb_agg(to_jsonb(node) ORDER BY node.sort_order, node.id),
    '[]'::jsonb
  )
  INTO v_nodes_result
  FROM public.rsip_nodes AS node
  WHERE node.user_id = v_user_id
    AND node.id = ANY(v_intent_node_ids);

  SELECT COALESCE(to_jsonb(meta), '{}'::jsonb)
  INTO v_meta_result
  FROM public.rsip_meta AS meta
  WHERE meta.user_id = v_user_id;

  RETURN jsonb_build_object(
    'nodes', v_nodes_result,
    'meta', COALESCE(v_meta_result, '{}'::jsonb)
  );
END;
$$;
COMMIT;

