CREATE TABLE IF NOT EXISTS mailboxes (
  room_id TEXT NOT NULL,
  mailbox TEXT NOT NULL CHECK (mailbox IN ('parent', 'child')),
  envelope TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (room_id, mailbox)
);
CREATE INDEX IF NOT EXISTS mailboxes_expiry ON mailboxes(expires_at);
