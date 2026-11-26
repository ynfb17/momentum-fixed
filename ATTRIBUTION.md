# Attribution / 来源与修改说明

## Original project

- Name: **Momentum - 心理学驱动的专注力应用**
- Repository: <https://github.com/KenXiao1/momentum>
- Author: **KenXiao1**
- Initial code used here: branch `new-feature-branch`,
  commit [`fa8aa9703d4c51c7ccce49a62f33ad345fec674c`](https://github.com/KenXiao1/momentum/commit/fa8aa9703d4c51c7ccce49a62f33ad345fec674c)
  (2026-11-25), snapshot downloaded on 2026-11-26.
- License: **GNU General Public License v3.0**; the original `LICENSE` file is
  preserved in this repository.

The original project implements CTDP task chains and the RSIP policy tree.

## Modifications in this repository

Modified by **Han Bao (@ynfb17)** on 2026-11-26, with assistance from
DeepSeek Harness.

Changes:

- Added a complete Supabase setup path: 2026-02-11 baseline, all later
  migrations, a verification query, and `scripts/database/verify-supabase.mjs`.
- Fixed task completion failures: missing-migration errors are surfaced,
  stale pending snapshots are cleared, and a failed chain re-read after a
  confirmed commit no longer reports the task as unsaved.
- Fixed RSIP creation: errors are shown instead of swallowed, strict/free mode
  is explained, a day rollover refreshes the daily limit, and the creation RPC
  keeps the stored mode in sync.
- Added cloud pet-stat sync through `pet_state`; on-screen position and
  visibility remain device-local.
- Fixed cloud imports generating `chain_<uuid>` IDs (PostgreSQL expects bare
  UUIDs).
- Added `scripts/migrate/account-counters.mjs` for account-level points,
  check-ins, and point transactions that the task export does not include.
- Added migration/deployment notes and tests for the changed behavior.

These modifications are distributed under **GPL-3.0**, the same license as the
original project. The original copyright notices and license text are
preserved.

## Notices

- This repository is a modified copy, not the original project. It is not
  affiliated with or endorsed by the original author.
- No warranty is provided; use at your own risk.
- Third-party libraries and assets remain under their respective licenses.
- Do not commit credentials, database passwords, service-role keys, personal
  exports, or `.env.local` files.
