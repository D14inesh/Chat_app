-- Vesper Chat — PostgreSQL schema
-- Requires PostgreSQL 13+ (gen_random_uuid() ships in pgcrypto / core since 13).

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ─────────────────────────────────────────────────────────────
-- users
-- ─────────────────────────────────────────────────────────────
-- public_key       : the user's ECDH P-256 public key (JWK). Public by design —
--                    every peer needs it to derive a shared secret.
-- enc_private_key  : the matching private key, AES-GCM encrypted client-side with
--                    a key derived from the user's password via PBKDF2. The server
--                    stores it only so the user can log in from a second device;
--                    it can never decrypt it (it never sees the password, only a
--                    bcrypt hash of it).
-- photo_path : an uploaded profile photo, stored and served in the clear —
--              unlike everything else in this app, it is NOT end-to-end
--              encrypted. There's no shared key with a stranger who hasn't
--              messaged you yet, and a profile photo needs to be visible in
--              search before any relationship exists — same trust tier as
--              username/display_name, which are already stored in plaintext.
CREATE TABLE IF NOT EXISTS users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username        text        NOT NULL,
  username_lower  text        NOT NULL UNIQUE,
  display_name    text        NOT NULL,
  password_hash   text        NOT NULL,
  avatar_color    text        NOT NULL DEFAULT '#6C5CE7',
  about           text        NOT NULL DEFAULT 'Available',
  photo_path      text,
  public_key      jsonb,
  enc_private_key jsonb,
  last_seen       timestamptz NOT NULL DEFAULT now(),
  created_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE users ADD COLUMN IF NOT EXISTS photo_path text;

-- appearance : the user's theme choice, applied on every device they log in from.
--   { palette: aurora|obsidian|nord|cyber, mode: dark|light, structure: floating|boxed }
--   Validated in src/routes/users.js before it's written.
ALTER TABLE users ADD COLUMN IF NOT EXISTS appearance jsonb NOT NULL
  DEFAULT '{"palette":"aurora","mode":"dark","structure":"floating"}'::jsonb;

-- ─────────────────────────────────────────────────────────────
-- conversations
-- ─────────────────────────────────────────────────────────────
-- Only 'direct' (1:1) is implemented. The table carries a `kind` column so group
-- chats can be added without a migration — see README "What's not built yet".
-- direct_key   : for 1:1 chats, the two member ids sorted and joined ('<uuid>:<uuid>').
--                UNIQUE on it means A→B and B→A can only ever create one conversation,
--                no matter who opens it first or whether both click at the same moment.
--                NULL for group chats, and Postgres lets NULLs repeat under UNIQUE.
-- avatar_color : group avatars reuse the same colored-initials pattern as users;
--                unused for 'direct' conversations (they show the peer's own color).
-- status       : 'direct' conversations start 'pending' until the non-requester
--                accepts — see requested_by. Groups are always 'accepted' (no
--                request flow for owner-added members).
-- requested_by : who initiated a direct conversation. ON DELETE SET NULL, not a
--                bare reference — deleting a user account shouldn't leave other
--                people's conversation rows FK-broken (same reasoning as
--                group_keys.wrapped_by below).
CREATE TABLE IF NOT EXISTS conversations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind         text        NOT NULL DEFAULT 'direct' CHECK (kind IN ('direct', 'group')),
  title        text,
  avatar_color text        NOT NULL DEFAULT '#6C5CE7',
  direct_key   text UNIQUE,
  status       text        NOT NULL DEFAULT 'accepted' CHECK (status IN ('pending', 'accepted')),
  requested_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- CREATE TABLE IF NOT EXISTS is a no-op on a table that already existed from
-- an earlier install — it does NOT add new columns to it. These ALTERs are
-- what actually bring an existing database up to date; they're also safe (and
-- cheap) to run against a brand-new one, since the column/constraint will
-- already be exactly right and each statement is idempotent.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS avatar_color text NOT NULL DEFAULT '#6C5CE7';
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'accepted';
ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_status_check;
ALTER TABLE conversations ADD CONSTRAINT conversations_status_check
  CHECK (status IN ('pending', 'accepted'));
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS requested_by uuid REFERENCES users(id) ON DELETE SET NULL;

-- role : only meaningful for kind='group' — the owner can add/remove members.
--        Direct conversations leave every row at the 'member' default.
CREATE TABLE IF NOT EXISTS conversation_members (
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
  role            text NOT NULL DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  joined_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (conversation_id, user_id)
);

ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'member';
ALTER TABLE conversation_members DROP CONSTRAINT IF EXISTS conversation_members_role_check;
ALTER TABLE conversation_members ADD CONSTRAINT conversation_members_role_check
  CHECK (role IN ('owner', 'member'));

-- Per-user "favourite" star on a chat — sidebar filter tab, not a shared
-- property of the conversation (each member stars it independently).
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS favorite boolean NOT NULL DEFAULT false;

-- Per-user chat wallpaper — a preset key (see WALLPAPER_PRESETS in app.js),
-- the literal string 'photo' for a custom uploaded background, or NULL
-- meaning "use the default background". Also per-member, not shared:
-- picking a wallpaper for a chat only changes how it looks on your screen.
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS wallpaper text;

-- A custom wallpaper photo, stored and served in the clear — same trust
-- tier as users.photo_path above (a personal background image, not
-- conversation content, so there's no shared key to encrypt it with
-- anyway). Set alongside wallpaper = 'photo'. Left in place if the user
-- switches to a preset instead, so switching back doesn't need a
-- re-upload; only overwritten (and the old file deleted) by a new upload.
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS wallpaper_photo_path text;

-- How a wallpaper photo is fitted to the chat panel — only meaningful
-- alongside wallpaper = 'photo' (ignored for presets/default, which are
-- CSS gradients with nothing to fit). See applyWallpaper in app.js for
-- what each value actually does to background-size/repeat.
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS wallpaper_fit text NOT NULL DEFAULT 'cover';
ALTER TABLE conversation_members DROP CONSTRAINT IF EXISTS conversation_members_wallpaper_fit_check;
ALTER TABLE conversation_members ADD CONSTRAINT conversation_members_wallpaper_fit_check
  CHECK (wallpaper_fit IN ('cover', 'contain', 'fill', 'tile'));

-- Per-user mute — same "not shared" model as favorite/wallpaper above.
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS muted boolean NOT NULL DEFAULT false;

-- "Clear chat" / "Delete chat" — both per-user, both cutoff timestamps rather
-- than actually touching the shared `messages` rows (which the other side
-- still needs intact). A cutoff means "hide everything up to/through this
-- point, from my view only":
--   cleared_at : GET .../messages filters out anything at or before this —
--                clearing history without leaving or affecting the other side.
--   hidden_at  : GET /api/conversations filters this conversation out of MY
--                list entirely, UNLESS a message has arrived since — i.e.
--                "delete chat" hides it until they message me again, instead
--                of a dead end that would need an explicit "unhide" no one
--                would ever find. (Deleting the membership row instead would
--                also revoke the ability to ever send/receive here again —
--                see requireAuth-style membership checks in onSend/onCallOffer
--                — which is far more destructive than what "delete chat" is
--                supposed to mean.)
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS cleared_at timestamptz;
ALTER TABLE conversation_members ADD COLUMN IF NOT EXISTS hidden_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_members_user ON conversation_members(user_id);

-- ─────────────────────────────────────────────────────────────
-- group_keys  (envelope encryption for group chats)
-- ─────────────────────────────────────────────────────────────
-- One random AES key per group, generated client-side, wrapped once per member
-- using the same pairwise ECDH derivation as 1:1 chat (deriveWrapKey in
-- public/js/crypto.js — NOT the same derivation used for message content,
-- deliberately, so a bug in one path can't expose the other). Every member
-- decrypts every group message with their own unwrapped copy of this one key.
--
-- wrapped_by : whose pairwise key was used to wrap it, so the unwrapper knows
--              which peer's public key to derive against. ON DELETE SET NULL,
--              not CASCADE — deleting the wrapper's account must not also wipe
--              every OTHER member's access to the group.
CREATE TABLE IF NOT EXISTS group_keys (
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
  wrapped_key     text NOT NULL,
  wrapped_iv      text NOT NULL,
  wrapped_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  PRIMARY KEY (conversation_id, user_id)
);

-- ─────────────────────────────────────────────────────────────
-- messages
-- ─────────────────────────────────────────────────────────────
-- The server never stores plaintext. `ciphertext` is base64 AES-GCM output and
-- `iv` is the base64 nonce; both are produced in the browser. For attachments the
-- file bytes are encrypted the same way before upload, so `file_name` / `file_mime`
-- are also ciphertext — only `file_size` and the storage path are readable.
-- edited_at   : set when a text message is edited in place (re-encrypted
--               client-side, ciphertext/iv overwritten). Editing is text-only.
-- reply_to_id : optional quote-reply target, same conversation only (checked
--               in application code, not a DB constraint). ON DELETE SET NULL
--               — deleting the original shouldn't cascade-delete every reply
--               to it, just orphan the reference; the UI falls back to a
--               generic "Original message" when it can't resolve one.
CREATE TABLE IF NOT EXISTS messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id       uuid NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
  kind            text NOT NULL DEFAULT 'text'
                    CHECK (kind IN ('text', 'file', 'voice', 'location', 'contact')),
  ciphertext      text NOT NULL,
  iv              text NOT NULL,
  file_path       text,
  file_size       bigint,
  created_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  edited_at       timestamptz,
  reply_to_id     uuid REFERENCES messages(id) ON DELETE SET NULL
);

-- Same idempotent-migration note as above: this widens the CHECK constraint
-- on an existing 'text'/'file'-only messages table to also allow the new
-- kinds. Postgres auto-names an inline column CHECK "<table>_<column>_check",
-- which is what's being dropped and recreated here.
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check;
ALTER TABLE messages ADD CONSTRAINT messages_kind_check
  CHECK (kind IN ('text', 'file', 'voice', 'location', 'contact'));

ALTER TABLE messages ADD COLUMN IF NOT EXISTS edited_at timestamptz;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS reply_to_id uuid REFERENCES messages(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_messages_convo
  ON messages(conversation_id, created_at DESC);

-- ─────────────────────────────────────────────────────────────
-- message_reactions
-- ─────────────────────────────────────────────────────────────
-- One reaction per (message, user) — setting a new one replaces the old,
-- matching WhatsApp's single-reaction-per-person behavior. The emoji itself
-- is encrypted with the same conversation key as the message it's on — the
-- server never learns which emoji was used, same as message content.
CREATE TABLE IF NOT EXISTS message_reactions (
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  ciphertext text NOT NULL,
  iv         text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

-- ─────────────────────────────────────────────────────────────
-- receipts  (drives the ✓ / ✓✓ / blue ✓✓ ticks)
-- ─────────────────────────────────────────────────────────────
-- One row per (message, recipient). Absent read_at = delivered but unread.
CREATE TABLE IF NOT EXISTS message_receipts (
  message_id   uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  delivered_at timestamptz,
  read_at      timestamptz,
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_receipts_unread
  ON message_receipts(user_id) WHERE read_at IS NULL;

-- ─────────────────────────────────────────────────────────────
-- statuses  (24-hour stories)
-- ─────────────────────────────────────────────────────────────
-- "Contacts" = everyone the poster has an existing direct conversation with —
-- there's no separate contacts feature, so this is the natural mapping.
-- Same envelope-encryption pattern as group_keys below: a random per-status
-- AES key, wrapped once per contact using the same pairwise ECDH derivation
-- already used for 1:1 messages (see public/js/crypto.js: deriveWrapKey).
-- A status is only ever wrapped by its own poster, so — unlike group_keys —
-- there's no wrapped_by column to track.
-- audio_* : an optional song/voice attachment on ANY status (text or image),
--           encrypted with the SAME content key as the main ciphertext — one
--           set of wrapped keys already covers both, no new key-wrapping
--           needed. All four null together when no audio is attached.
CREATE TABLE IF NOT EXISTS statuses (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind            text NOT NULL CHECK (kind IN ('text', 'image', 'video')),
  ciphertext      text NOT NULL,
  iv              text NOT NULL,
  file_path       text,                        -- only set when kind = 'image' or 'video'
  file_size       bigint,
  audio_ciphertext text,
  audio_iv         text,
  audio_file_path  text,
  audio_file_size  bigint,
  -- 'contacts': visible to everyone the poster has an accepted direct
  -- conversation with (the historical/default behaviour — status_keys
  -- rows get created for all of them). 'selected': only the specific
  -- people picked at post time got a status_keys row — this column is
  -- purely a display flag (so the poster's own view can show a lock icon)
  -- since GET /api/status's actual visibility is already 100% governed by
  -- status_keys row presence either way.
  audience        text NOT NULL DEFAULT 'contacts',
  created_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL DEFAULT (now() + interval '24 hours')
);

ALTER TABLE statuses ADD COLUMN IF NOT EXISTS audio_ciphertext text;
ALTER TABLE statuses ADD COLUMN IF NOT EXISTS audio_iv text;
ALTER TABLE statuses ADD COLUMN IF NOT EXISTS audio_file_path text;
ALTER TABLE statuses ADD COLUMN IF NOT EXISTS audio_file_size bigint;
ALTER TABLE statuses ADD COLUMN IF NOT EXISTS audience text NOT NULL DEFAULT 'contacts';

ALTER TABLE statuses DROP CONSTRAINT IF EXISTS statuses_kind_check;
ALTER TABLE statuses ADD CONSTRAINT statuses_kind_check
  CHECK (kind IN ('text', 'image', 'video'));
ALTER TABLE statuses DROP CONSTRAINT IF EXISTS statuses_audience_check;
ALTER TABLE statuses ADD CONSTRAINT statuses_audience_check
  CHECK (audience IN ('contacts', 'selected'));

CREATE INDEX IF NOT EXISTS idx_statuses_user ON statuses(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_statuses_expiry ON statuses(expires_at);

CREATE TABLE IF NOT EXISTS status_keys (
  status_id   uuid NOT NULL REFERENCES statuses(id) ON DELETE CASCADE,
  viewer_id   uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  wrapped_key text NOT NULL,
  wrapped_iv  text NOT NULL,
  PRIMARY KEY (status_id, viewer_id)
);

CREATE TABLE IF NOT EXISTS status_views (
  status_id uuid NOT NULL REFERENCES statuses(id) ON DELETE CASCADE,
  viewer_id uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  viewed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (status_id, viewer_id)
);

-- Tags a specific contact on a status, WhatsApp/Instagram "mention"-style
-- — purely metadata (who the poster tagged), unencrypted since it's only
-- ever a user id, not content. A mentioned viewer sees a "mentioned you"
-- badge; it does NOT by itself grant visibility (still gated by
-- status_keys, same as anyone else).
CREATE TABLE IF NOT EXISTS status_mentions (
  status_id         uuid NOT NULL REFERENCES statuses(id) ON DELETE CASCADE,
  mentioned_user_id uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  PRIMARY KEY (status_id, mentioned_user_id)
);
CREATE INDEX IF NOT EXISTS idx_status_mentions_user ON status_mentions(mentioned_user_id);

-- ─────────────────────────────────────────────────────────────
-- ai_messages  (AI Chat — Ollama-backed)
-- ─────────────────────────────────────────────────────────────
-- Deliberately its OWN table, not folded into `messages`. Talking to the AI
-- cannot be end-to-end encrypted — the server has to read the content to
-- forward it to Ollama — so keeping it structurally separate means there is
-- no shared code path where that plaintext-by-design exception could ever
-- weaken the real invariant that every row in `messages` is always
-- ciphertext+iv.
CREATE TABLE IF NOT EXISTS ai_messages (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('user', 'assistant')),
  content    text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_messages_user ON ai_messages(user_id, created_at);

-- ─────────────────────────────────────────────────────────────
-- reminders
-- ─────────────────────────────────────────────────────────────
-- Deliberately plaintext, same reasoning as ai_messages above: the server
-- has to read `content` on its own, unprompted, when `remind_at` arrives
-- (there's no browser action to piggyback a decrypt on), so it can never be
-- end-to-end encrypted.
-- category   : picked by the user at creation time — drives which flavor of
--              notification message gets generated (see CATEGORY_TEMPLATES
--              in src/reminders-scheduler.js). 'general' is a plain nudge.
-- notified_at: set once the scheduler has attempted delivery (pushed to
--              every device subscribed at that moment, or found none to
--              push to) — NULL means still due/pending.
CREATE TABLE IF NOT EXISTS reminders (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  content     text NOT NULL,
  category    text NOT NULL DEFAULT 'general'
                CHECK (category IN ('birthday', 'happy', 'love', 'sad', 'breakup', 'general')),
  remind_at   timestamptz NOT NULL,
  notified_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reminders_due ON reminders(remind_at) WHERE notified_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reminders_user ON reminders(user_id, remind_at);

-- ─────────────────────────────────────────────────────────────
-- push_subscriptions  (Web Push — one row per browser/device the user
-- opted in on; a person can have several)
-- ─────────────────────────────────────────────────────────────
-- endpoint/p256dh/auth are exactly the fields the browser's PushManager
-- hands back from subscribe() — see public/js/app.js. UNIQUE on endpoint:
-- re-subscribing the same browser (e.g. after clearing permission and
-- re-granting it) replaces its row instead of accumulating duplicates.
CREATE TABLE IF NOT EXISTS push_subscriptions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  endpoint   text NOT NULL UNIQUE,
  p256dh     text NOT NULL,
  auth       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_push_subs_user ON push_subscriptions(user_id);

-- ─────────────────────────────────────────────────────────────
-- scheduled_messages
-- ─────────────────────────────────────────────────────────────
-- Unlike reminders (necessarily plaintext — see above), a scheduled message
-- stays fully end-to-end encrypted: the browser encrypts it with the
-- conversation's key at SCHEDULING time, not at delivery time, so the
-- server only ever holds ciphertext it can't read, exactly like a normal
-- message. This works because the 1:1 conversation key is deterministically
-- re-derivable from the two accounts' keypairs (static-static ECDH — see
-- deriveSharedKey in public/js/crypto.js), so it's still valid whenever
-- send_at eventually arrives, with nobody needing to be online in between.
-- sent_at : set once src/scheduled-messages-scheduler.js has delivered it
--           (inserted a real row into `messages`) — NULL means still pending.
CREATE TABLE IF NOT EXISTS scheduled_messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  ciphertext      text NOT NULL,
  iv              text NOT NULL,
  send_at         timestamptz NOT NULL,
  sent_at         timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_scheduled_messages_due ON scheduled_messages(send_at) WHERE sent_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_scheduled_messages_convo ON scheduled_messages(conversation_id, sender_id);

-- ─────────────────────────────────────────────────────────────
-- message_stars  ("Starred messages")
-- ─────────────────────────────────────────────────────────────
-- Per-user, like a reaction but with no content of its own — just marks
-- that this user starred this message, so it can show up in their
-- cross-conversation "Starred messages" list. ciphertext/iv aren't
-- duplicated here; the starred-messages view re-fetches and decrypts from
-- `messages` itself, same as any other read.
CREATE TABLE IF NOT EXISTS message_stars (
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_message_stars_user ON message_stars(user_id, created_at DESC);

-- ─────────────────────────────────────────────────────────────
-- message_hides  ("Delete for me")
-- ─────────────────────────────────────────────────────────────
-- The OTHER of WhatsApp's two delete options — messages.deleted_at (see
-- above) is "delete for everyone" (global, sender-only, broadcast live to
-- both sides). This is purely local: a row here just means THIS user no
-- longer wants to see this message, and the message list query excludes
-- anything with a row here for the requesting user. No fan-out needed —
-- the other participant's copy is completely unaffected, so unlike
-- deleted_at this never goes out over the WebSocket.
CREATE TABLE IF NOT EXISTS message_hides (
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_message_hides_user ON message_hides(user_id);

-- ─────────────────────────────────────────────────────────────
-- blocked_users
-- ─────────────────────────────────────────────────────────────
-- One-directional (blocker_id blocked blocked_id), but every enforcement
-- check (onSend, onCallOffer, starting a new direct conversation) treats
-- a row in EITHER direction as blocking — simpler and safer than reasoning
-- about "well *I* didn't block *them*" edge cases, and matches the
-- practical behavior users expect once either side has blocked the other.
CREATE TABLE IF NOT EXISTS blocked_users (
  blocker_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (blocker_id, blocked_id)
);

CREATE INDEX IF NOT EXISTS idx_blocked_blocker ON blocked_users(blocker_id);
CREATE INDEX IF NOT EXISTS idx_blocked_blocked ON blocked_users(blocked_id);

-- ─────────────────────────────────────────────────────────────
-- chat_labels  (custom lists/folders, per user)
-- ─────────────────────────────────────────────────────────────
-- A label belongs to one user (your "Work"/"Family" labels are invisible
-- to everyone else, same trust tier as a favorite star or a wallpaper
-- choice) and can be attached to any number of that user's conversations;
-- a conversation can carry more than one label at once, hence the
-- separate link table rather than a single label_id column.
CREATE TABLE IF NOT EXISTS chat_labels (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  color      text NOT NULL DEFAULT '#A76BC9',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_labels_user ON chat_labels(user_id, created_at);

CREATE TABLE IF NOT EXISTS conversation_label_links (
  conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  label_id        uuid NOT NULL REFERENCES chat_labels(id)   ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id)         ON DELETE CASCADE,
  PRIMARY KEY (conversation_id, label_id)
);

CREATE INDEX IF NOT EXISTS idx_convo_label_links_user ON conversation_label_links(user_id, label_id);

-- ─────────────────────────────────────────────────────────────
-- link_requests  (Linked Devices — QR sign-in without a password)
-- ─────────────────────────────────────────────────────────────
-- A logged-out device generates a throwaway ECDH keypair, posts the PUBLIC
-- half here plus a random device_secret (only its bcrypt hash is stored),
-- and shows `code` in a QR. An already-signed-in device scans it, seals its
-- own identity private key to that ephemeral public key (see
-- sealIdentityForLink in public/js/crypto.js), and writes the ciphertext to
-- wrapped_key/wrapped_iv along with its user_id. The server never sees a
-- key it can open — same trust model as `messages`. The new device then
-- polls with the raw device_secret, gets the ciphertext + a session cookie,
-- and decrypts locally. Rows are single-use and expire in minutes.
CREATE TABLE IF NOT EXISTS link_requests (
  code                 text PRIMARY KEY,
  device_secret_hash   text NOT NULL,
  ephemeral_public_key jsonb NOT NULL,
  user_id              uuid REFERENCES users(id) ON DELETE CASCADE,
  wrapped_key          text,
  wrapped_iv           text,
  status               text NOT NULL DEFAULT 'pending'
                         CHECK (status IN ('pending', 'ready', 'used')),
  created_at           timestamptz NOT NULL DEFAULT now(),
  expires_at           timestamptz NOT NULL DEFAULT (now() + interval '3 minutes')
);

CREATE INDEX IF NOT EXISTS idx_link_requests_expiry ON link_requests(expires_at);

-- ═════════════════════════════════════════════════════════════
-- Polls, pinned messages, disappearing messages, view-once media,
-- login alerts, quick replies, broadcast lists, business profiles.
-- Everything below is idempotent and also runs at every backend start
-- (main.py applies this whole file), so an update needs no manual step.
-- ═════════════════════════════════════════════════════════════

-- 'poll' messages: the question and options are encrypted like any text;
-- only the votes (option numbers) are visible to the server, see poll_votes.
ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check;
ALTER TABLE messages ADD CONSTRAINT messages_kind_check
  CHECK (kind IN ('text', 'file', 'voice', 'location', 'contact', 'poll'));

-- view_once  : a photo/video the recipient can open a single time (see
--              message_opens; the blob download is refused after that).
-- expires_at : set at send time when the chat has disappearing messages on;
--              reads filter it out and a sweeper deletes it for good.
ALTER TABLE messages ADD COLUMN IF NOT EXISTS view_once boolean NOT NULL DEFAULT false;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS expires_at timestamptz;
CREATE INDEX IF NOT EXISTS idx_messages_expiry ON messages(expires_at) WHERE expires_at IS NOT NULL;

-- Shared per conversation (everyone sees the same pinned message and the
-- same disappearing-messages timer), unlike the per-member settings above.
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS pinned_message_id uuid REFERENCES messages(id) ON DELETE SET NULL;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS pinned_by uuid REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS disappear_seconds integer NOT NULL DEFAULT 0;

-- One row per voter; choices are option indexes into the (encrypted) poll.
CREATE TABLE IF NOT EXISTS poll_votes (
  message_id uuid       NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    uuid       NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  choices    smallint[] NOT NULL,
  voted_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

-- Who has already opened a view-once message.
CREATE TABLE IF NOT EXISTS message_opens (
  message_id uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id)    ON DELETE CASCADE,
  opened_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, user_id)
);

-- session_epoch: "Log out all other devices" bumps it; a session token
-- carrying an older epoch stops working everywhere at once.
ALTER TABLE users ADD COLUMN IF NOT EXISTS session_epoch integer NOT NULL DEFAULT 0;

-- Business profile — public profile info, same trust tier as `about`.
--   { enabled, category, description, address, hours, email, website }
ALTER TABLE users ADD COLUMN IF NOT EXISTS business jsonb;

-- Every sign-in, for "new login" alerts and the Devices list.
CREATE TABLE IF NOT EXISTS login_events (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device     text NOT NULL,
  ip         text,
  method     text NOT NULL DEFAULT 'password',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_login_events_user ON login_events(user_id, created_at DESC);

-- Saved answers inserted with "/shortcut" in the composer. The user's own
-- templates, stored so they follow them to every device (not chat content).
CREATE TABLE IF NOT EXISTS quick_replies (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  shortcut   text NOT NULL,
  body       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_quick_replies_shortcut ON quick_replies(user_id, lower(shortcut));

-- Broadcast lists: one message goes to each member as a normal, separately
-- encrypted 1:1 message — the list itself is just who to send to.
CREATE TABLE IF NOT EXISTS broadcast_lists (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_broadcast_lists_user ON broadcast_lists(user_id, created_at);

-- One account per device: the first account to sign in or register on a
-- phone/computer owns it; any other account is refused there until the
-- owner releases the device (Security & logins) or an admin does
-- (backend/release_device.py). device_id is the phone's Android ID
-- ("android:…") or a long-lived browser cookie ("web:…").
CREATE TABLE IF NOT EXISTS device_bindings (
  device_id  text PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  label      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_device_bindings_user ON device_bindings(user_id);

CREATE TABLE IF NOT EXISTS broadcast_list_members (
  list_id   uuid NOT NULL REFERENCES broadcast_lists(id) ON DELETE CASCADE,
  member_id uuid NOT NULL REFERENCES users(id)           ON DELETE CASCADE,
  PRIMARY KEY (list_id, member_id)
);

-- Verified contact: every account has a mobile number and an email
-- (Gmail), each usable by only one account. The email is proven with a
-- one-time code sent to it; see email_otps.
ALTER TABLE users ADD COLUMN IF NOT EXISTS phone text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS email text;
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS users_phone_key ON users(phone) WHERE phone IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS users_email_key ON users(lower(email)) WHERE email IS NOT NULL;

-- 6-digit codes emailed for sign-up / adding a number+email to an existing
-- account. Only a hash is kept; 10 minutes, 5 tries, single use.
CREATE TABLE IF NOT EXISTS email_otps (
  id         bigserial PRIMARY KEY,
  email      text NOT NULL,
  phone      text NOT NULL,
  purpose    text NOT NULL,
  code_hash  text NOT NULL,
  attempts   int  NOT NULL DEFAULT 0,
  expires_at timestamptz NOT NULL,
  used_at    timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_email_otps_email ON email_otps(lower(email), created_at DESC);

-- ─────────────────────────────────────────────────────────────
-- Account recovery, admin, announcements
-- ─────────────────────────────────────────────────────────────
-- enc_private_key_recovery : the same private key, wrapped with the user's
--   recovery key (shown to them once) instead of their password — lets a
--   "forgot password" reset keep their old messages readable.
ALTER TABLE users ADD COLUMN IF NOT EXISTS enc_private_key_recovery jsonb;
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_admin boolean NOT NULL DEFAULT false;
-- Suspended by an admin: can't sign in, every session is ended.
ALTER TABLE users ADD COLUMN IF NOT EXISTS disabled_at timestamptz;
ALTER TABLE users ADD COLUMN IF NOT EXISTS announcements_seen_at timestamptz NOT NULL DEFAULT now();

-- Notices from the admin to everyone (plain text — not a chat message).
CREATE TABLE IF NOT EXISTS announcements (
  id         bigserial PRIMARY KEY,
  title      text NOT NULL,
  body       text NOT NULL,
  created_by uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
