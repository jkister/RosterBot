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
    approval_status TEXT DEFAULT 'pending',  -- 'pending' or 'approved'; set to 'approved' by GUILD_MEMBER_UPDATE when Discord server admin approves the user
    scammer_ack BOOLEAN NOT NULL DEFAULT 0,           -- 1 once user has acknowledged the scammer warning message
    last_scammer_warning TIMESTAMP,
    last_contact_request TIMESTAMP,
    contact_count INTEGER NOT NULL DEFAULT 0,
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

-- Indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_memberships_server ON memberships(server_id);
CREATE INDEX IF NOT EXISTS idx_memberships_user ON memberships(user_id);
CREATE INDEX IF NOT EXISTS idx_memberships_status ON memberships(status);
CREATE INDEX IF NOT EXISTS idx_servers_status ON servers(status);

-- Create index for finding users who need contact requests
CREATE INDEX IF NOT EXISTS idx_users_contact_status ON users(contact_status);
CREATE INDEX IF NOT EXISTS idx_users_last_contact_request ON users(last_contact_request);
CREATE INDEX IF NOT EXISTS idx_users_approval_status ON users(approval_status);
CREATE INDEX IF NOT EXISTS idx_users_scammer_ack ON users(scammer_ack);
