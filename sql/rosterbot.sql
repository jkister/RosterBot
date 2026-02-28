-- RosterBot Database Schema

-- Servers table
CREATE TABLE IF NOT EXISTS servers (
    server_id TEXT PRIMARY KEY,
    server_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',  -- 'active' or 'deleted'
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Users table
CREATE TABLE IF NOT EXISTS users (
    user_id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    display_name TEXT,  -- global_name from Discord
    contact_status TEXT DEFAULT 'pending',
    last_contact_request TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Memberships table (many-to-many relationship)
CREATE TABLE IF NOT EXISTS memberships (
    membership_id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    nickname TEXT,  -- server-specific nickname
    status TEXT NOT NULL DEFAULT 'member',  -- 'member' or 'left'
    joined_at TIMESTAMP,
    left_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (server_id) REFERENCES servers(server_id),
    FOREIGN KEY (user_id) REFERENCES users(user_id),
    UNIQUE(server_id, user_id)  -- One membership record per user per server
);

-- Add admins table
CREATE TABLE IF NOT EXISTS admins (
    admin_id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL UNIQUE,
    username TEXT NOT NULL,
    granted_by TEXT,  -- user_id of admin who granted this privilege
    granted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id),
    FOREIGN KEY (granted_by) REFERENCES users(user_id)
);

-- Create index for admin lookups
CREATE INDEX IF NOT EXISTS idx_admins_user ON admins(user_id);

-- Insert default admin (jkister)
-- Note: You'll need to update this with jkister's actual user_id from your users table
INSERT OR IGNORE INTO admins (user_id, username, granted_by, granted_at)
SELECT '1388031297036750958', 'jkister', '1388031297036750958', CURRENT_TIMESTAMP
WHERE EXISTS (SELECT 1 FROM users WHERE user_id = '1388031297036750958');

-- Indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_memberships_server ON memberships(server_id);
CREATE INDEX IF NOT EXISTS idx_memberships_user ON memberships(user_id);
CREATE INDEX IF NOT EXISTS idx_memberships_status ON memberships(status);
CREATE INDEX IF NOT EXISTS idx_servers_status ON servers(status);

-- Create index for finding users who need contact requests
CREATE INDEX IF NOT EXISTS idx_users_contact_status ON users(contact_status);
CREATE INDEX IF NOT EXISTS idx_users_last_contact_request ON users(last_contact_request);
