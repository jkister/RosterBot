package RosterBot::Database;
use strict;
use warnings;
use 5.020;

use DBI;
use Exporter 'import';

# contact_status values
use constant STATUS_PENDING   => 'pending';
use constant STATUS_CONTACTED => 'contacted';
use constant STATUS_PROVIDED  => 'provided';
use constant STATUS_STOPPED   => 'stopped';
use constant STATUS_BANNED    => 'banned';

# approval_status values
use constant APPROVAL_PENDING  => 'pending';
use constant APPROVAL_APPROVED => 'approved';

our @EXPORT = qw(
    db_init
    db_upsert_server
    db_upsert_user
    db_update_user_contact
    db_update_contact_status
    db_update_last_contact_request
    db_get_user_contact_info
    db_get_users_needing_contact_request
    db_get_users_needing_scammer_warning
    db_get_all_users_with_contact
    db_upsert_membership
    db_mark_member_left
    db_mark_server_deleted
    db_get_servers
    db_get_members
    db_is_admin
    db_add_admin
    db_remove_admin
    db_get_admins
    db_get_all_active_members
    db_get_active_members_in_server
    db_get_admin_user_ids
    db_delete_user_email
    db_delete_user_phone
    db_reset_user_on_rejoin
    db_set_scammer_ack
    db_set_user_approved
    db_update_last_scammer_warning
    db_disconnect
    STATUS_PENDING
    STATUS_CONTACTED
    STATUS_PROVIDED
    STATUS_STOPPED
    STATUS_BANNED
    APPROVAL_PENDING
    APPROVAL_APPROVED
);

my $dbh;

sub db_init {
    my ($db_path) = @_;
    
    $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", "", "", {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        sqlite_unicode => 1,
    }) or die "Cannot connect to database: $DBI::errstr\n";
    
    return $dbh;
}

sub db_disconnect {
    $dbh->disconnect() if $dbh;
}

sub db_upsert_server {
    my ($server_id, $server_name, $status) = @_;
    $status //= 'active';
    
    my $sth = $dbh->prepare(q{
        INSERT INTO servers (server_id, server_name, status, updated_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(server_id) DO UPDATE SET
            server_name = excluded.server_name,
            status = excluded.status,
            updated_at = CURRENT_TIMESTAMP
    });
    $sth->execute($server_id, $server_name, $status);
}

sub db_upsert_user {
    my ($user_id, $username, $display_name) = @_;

    $display_name //= '';

    my $sth = $dbh->prepare(q{
        INSERT INTO users (user_id, username, display_name, contact_status, approval_status, scammer_ack, updated_at)
        VALUES (?, ?, ?, 'pending', 'pending', 0, CURRENT_TIMESTAMP)
        ON CONFLICT(user_id) DO UPDATE SET
            username = excluded.username,
            display_name = excluded.display_name,
            updated_at = CURRENT_TIMESTAMP
    });
    $sth->execute($user_id, $username, $display_name);
}

sub db_update_user_contact {
    my ($user_id, $email, $phone) = @_;
    
    my @fields;
    my @values;
    
    if (defined $email) {
        push @fields, "email = ?";
        push @values, $email;
    }
    
    if (defined $phone) {
        push @fields, "phone = ?";
        push @values, $phone;
    }
    
    if (@fields) {
        push @fields, "contact_status = '" . STATUS_PROVIDED . "'";
    }
    
    push @fields, "updated_at = CURRENT_TIMESTAMP";
    push @values, $user_id;
    
    my $sql = "UPDATE users SET " . join(", ", @fields) . " WHERE user_id = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute(@values);
}

sub db_delete_user_email {
    my ($user_id) = @_;

    my $pending = STATUS_PENDING;
    my $sth = $dbh->prepare(qq{
        UPDATE users
        SET email = NULL,
            contact_status = CASE WHEN phone IS NULL THEN '$pending' ELSE contact_status END,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = ?
    });
    $sth->execute($user_id);
}

sub db_delete_user_phone {
    my ($user_id) = @_;

    my $pending = STATUS_PENDING;
    my $sth = $dbh->prepare(qq{
        UPDATE users
        SET phone = NULL,
            contact_status = CASE WHEN email IS NULL THEN '$pending' ELSE contact_status END,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = ?
    });
    $sth->execute($user_id);
}

sub db_update_contact_status {
    my ($user_id, $status) = @_;

    my $sth = $dbh->prepare(q{
        SELECT contact_status FROM users WHERE user_id = ?
    });
    $sth->execute($user_id);
    my ($old_status) = $sth->fetchrow_array();

    $sth = $dbh->prepare(q{
        UPDATE users
        SET contact_status = ?,
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = ?
    });
    $sth->execute($status, $user_id);

    if (defined $old_status && $old_status ne $status) {
        warn "[" . scalar(localtime) . "] Contact status [$user_id]: $old_status -> $status\n";
    }
}

sub db_update_last_contact_request {
    my ($user_id) = @_;

    my $sth = $dbh->prepare(q{
        UPDATE users
        SET last_contact_request = CURRENT_TIMESTAMP,
            contact_count = contact_count + 1
        WHERE user_id = ?
    });
    $sth->execute($user_id);
}

sub db_get_user_contact_info {
    my ($user_id) = @_;

    my $sth = $dbh->prepare(q{
        SELECT email, phone, contact_status, last_contact_request,
               approval_status, scammer_ack, last_scammer_warning
        FROM users
        WHERE user_id = ?
    });
    $sth->execute($user_id);

    return $sth->fetchrow_hashref();
}

sub db_get_users_needing_contact_request {
    my ($interval, $max_count) = @_;

    my $sth = $dbh->prepare(q{
        SELECT user_id, username, display_name
        FROM users
        WHERE contact_status IN ('pending', 'contacted')
          AND approval_status = 'approved'
          AND (last_contact_request IS NULL
               OR last_contact_request < datetime('now', '-' || ? || ' seconds'))
        LIMIT ?
    });
    $sth->execute($interval, $max_count);

    my @users;
    while (my $row = $sth->fetchrow_hashref) {
        push @users, $row;
    }
    return @users;
}

sub db_get_users_needing_scammer_warning {
    my ($interval, $max_count) = @_;

    my $sth = $dbh->prepare(q{
        SELECT user_id, username, display_name
        FROM users
        WHERE scammer_ack = 0
          AND contact_status != 'stopped'
          AND contact_status != 'banned'
          AND (last_scammer_warning IS NULL
               OR last_scammer_warning < datetime('now', '-' || ? || ' seconds'))
        LIMIT ?
    });
    $sth->execute($interval, $max_count);

    my @users;
    while (my $row = $sth->fetchrow_hashref) {
        push @users, $row;
    }
    return @users;
}

sub db_get_all_users_with_contact {
    my ($status_filter) = @_;
    
    my $sql = q{
        SELECT user_id, username, display_name, email, phone, contact_status, last_contact_request, contact_count
        FROM users
    };
    
    if ($status_filter) {
        $sql .= " WHERE contact_status = ?";
    }
    
    $sql .= " ORDER BY username";
    
    my $sth = $dbh->prepare($sql);
    
    if ($status_filter) {
        $sth->execute($status_filter);
    } else {
        $sth->execute();
    }
    
    my @users;
    while (my $row = $sth->fetchrow_hashref) {
        push @users, $row;
    }
    return @users;
}

sub db_upsert_membership {
    my ($server_id, $user_id, $nickname, $status, $joined_at) = @_;
    $status //= 'member';
    
    my $sth = $dbh->prepare(q{
        INSERT INTO memberships (server_id, user_id, nickname, status, joined_at, updated_at)
        VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(server_id, user_id) DO UPDATE SET
            nickname = excluded.nickname,
            status = excluded.status,
            joined_at = COALESCE(memberships.joined_at, excluded.joined_at),
            updated_at = CURRENT_TIMESTAMP
    });
    $sth->execute($server_id, $user_id, $nickname, $status, $joined_at);
}

sub db_mark_member_left {
    my ($server_id, $user_id) = @_;
    
    my $sth = $dbh->prepare(q{
        UPDATE memberships
        SET status = 'left',
            left_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
        WHERE server_id = ? AND user_id = ?
    });
    $sth->execute($server_id, $user_id);
}

sub db_mark_server_deleted {
    my ($server_id) = @_;
    
    my $sth = $dbh->prepare(q{
        UPDATE servers
        SET status = 'deleted',
            updated_at = CURRENT_TIMESTAMP
        WHERE server_id = ?
    });
    $sth->execute($server_id);
}

sub db_get_servers {
    my $sth = $dbh->prepare(q{
        SELECT server_id, server_name, status
        FROM servers
        ORDER BY server_name
    });
    $sth->execute();
    
    my @servers;
    while (my $row = $sth->fetchrow_hashref) {
        push @servers, $row;
    }
    return @servers;
}

sub db_get_members {
    my ($server_id) = @_;
    
    my $sth = $dbh->prepare(q{
        SELECT u.user_id, u.username, u.display_name, m.nickname, m.status, m.joined_at, m.left_at
        FROM memberships m
        JOIN users u ON m.user_id = u.user_id
        WHERE m.server_id = ?
        ORDER BY u.username
    });
    $sth->execute($server_id);
    
    my @members;
    while (my $row = $sth->fetchrow_hashref) {
        push @members, $row;
    }
    return @members;
}

sub db_is_admin {
    my ($user_id) = @_;
    
    my $sth = $dbh->prepare(q{
        SELECT COUNT(*) FROM admins WHERE user_id = ?
    });
    $sth->execute($user_id);
    my ($count) = $sth->fetchrow_array();
    
    return $count > 0;
}

sub db_add_admin {
    my ($user_id, $username, $granted_by) = @_;
    
    my $sth = $dbh->prepare(q{
        INSERT OR IGNORE INTO admins (user_id, username, granted_by, granted_at)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
    });
    $sth->execute($user_id, $username, $granted_by);
    
    return $sth->rows > 0;
}

sub db_remove_admin {
    my ($user_id) = @_;
    
    my $sth = $dbh->prepare(q{
        DELETE FROM admins WHERE user_id = ?
    });
    $sth->execute($user_id);
    
    return $sth->rows > 0;
}

sub db_get_admins {
    my $sth = $dbh->prepare(q{
        SELECT user_id, username, granted_at
        FROM admins
        ORDER BY username
    });
    $sth->execute();
    
    my @admins;
    while (my $row = $sth->fetchrow_hashref) {
        push @admins, $row;
    }
    return @admins;
}

sub db_get_all_active_members {
    my $sth = $dbh->prepare(q{
        SELECT DISTINCT u.user_id, u.username, u.display_name
        FROM users u
        JOIN memberships m ON u.user_id = m.user_id
        WHERE m.status = 'member'
        ORDER BY u.username
    });
    $sth->execute();
    
    my @members;
    while (my $row = $sth->fetchrow_hashref) {
        push @members, $row;
    }
    return @members;
}

sub db_get_active_members_in_server {
    my ($server_id) = @_;
    
    my $sth = $dbh->prepare(q{
        SELECT u.user_id, u.username, u.display_name
        FROM users u
        JOIN memberships m ON u.user_id = m.user_id
        WHERE m.server_id = ? AND m.status = 'member'
        ORDER BY u.username
    });
    $sth->execute($server_id);
    
    my @members;
    while (my $row = $sth->fetchrow_hashref) {
        push @members, $row;
    }
    return @members;
}

sub db_get_admin_user_ids {
    my $sth = $dbh->prepare(q{
        SELECT user_id FROM admins
    });
    $sth->execute();

    my @admin_ids;
    while (my ($user_id) = $sth->fetchrow_array()) {
        push @admin_ids, $user_id;
    }
    return @admin_ids;
}

sub db_reset_user_on_rejoin {
    my ($user_id) = @_;

    my $sth = $dbh->prepare(q{
        UPDATE users
        SET scammer_ack = 0,
            approval_status = 'pending',
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = ?
    });
    $sth->execute($user_id);
}

sub db_set_scammer_ack {
    my ($user_id) = @_;

    my $sth = $dbh->prepare(q{
        UPDATE users
        SET scammer_ack = 1, updated_at = CURRENT_TIMESTAMP
        WHERE user_id = ?
    });
    $sth->execute($user_id);
}

sub db_update_last_scammer_warning {
    my ($user_id) = @_;

    my $sth = $dbh->prepare(q{
        UPDATE users
        SET last_scammer_warning = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE user_id = ?
    });
    $sth->execute($user_id);
}

sub db_set_user_approved {
    my ($user_id) = @_;

    my $sth = $dbh->prepare(q{
        UPDATE users
        SET approval_status = 'approved', updated_at = CURRENT_TIMESTAMP
        WHERE user_id = ?
    });
    $sth->execute($user_id);
}

1;
