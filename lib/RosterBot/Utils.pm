package RosterBot::Utils;
use strict;
use warnings;
use 5.020;
use utf8;

binmode(STDERR, ':encoding(UTF-8)');

use Exporter 'import';

our @EXPORT = qw(
    verbose
    debug
    set_debug_flag
    find_user_by_name
    is_known_member
    get_display_name
    get_username
    get_display_name_in_guild
    get_username_in_guild
    normalize_unicode
    get_guilds
    get_user_cache
    get_bot_user
    set_bot_user
    set_notify_only_user
    get_notify_only_user
);

my $debug_enabled = 0;
my %guilds;
my %user_cache;
my $bot_user;
my $NOTIFY_ONLY_USER = undef;

sub set_notify_only_user {
    my ($username) = @_;
    $NOTIFY_ONLY_USER = $username;
    verbose("Notifications will only be sent to: $username") if $username;
}

sub get_notify_only_user {
    return $NOTIFY_ONLY_USER;
}

sub set_debug_flag {
    my ($flag) = @_;
    $debug_enabled = $flag;
}

sub verbose {
    my $msg = join('', @_);
    my $timestamp = scalar(localtime);

    warn "[$timestamp] $msg\n";
}

sub debug {
    verbose(@_) if $debug_enabled;
}

sub get_guilds { return \%guilds; }
sub get_user_cache { return \%user_cache; }
sub get_bot_user { return $bot_user; }
sub set_bot_user { $bot_user = $_[0]; }

sub normalize_unicode {
    my ($content) = @_;
    
    # Normalize Unicode quotes and apostrophes to ASCII
    $content =~ s/[\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}\x{2036}]/"/g;  # Various double quotes
    $content =~ s/[\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}\x{2035}]/'/g;  # Various single quotes/apostrophes
    $content =~ s/[\x{00AB}\x{00BB}]/"/g;  # Guillemets (angle quotes)
    $content =~ s/[\x{2013}\x{2014}\x{2010}\x{2011}\x{2212}]/-/g;  # En dash, em dash, hyphens, minus
    $content =~ s/\x{2026}/.../g;  # Ellipsis
    
    return $content;
}

sub find_user_by_name {
    my ($username) = @_;
    
    my $search_name = lc($username);
    $search_name =~ s/#.*$//;
    
    debug("Searching for user: [$search_name]");
    
    if (exists $user_cache{$search_name}) {
        debug("Found user in cache: [$user_cache{$search_name}]");
        return $user_cache{$search_name};
    }
    
    for my $guild_id (keys %guilds) {
        for my $user_id (keys %{$guilds{$guild_id}{members}}) {
            my $member = $guilds{$guild_id}{members}{$user_id};
            my $member_name = lc($member->{username});
            $member_name =~ s/#.*$//;
            
            my $nick = $member->{nick} ? lc($member->{nick}) : '';
            my $global = $member->{global_name} ? lc($member->{global_name}) : '';
            
            if ($member_name eq $search_name || $nick eq $search_name || $global eq $search_name) {
                debug("Found user: [$user_id]");
                $user_cache{$search_name} = $user_id;
                return $user_id;
            }
        }
    }
    
    debug("User not found: [$search_name]");
    return undef;
}

sub is_known_member {
    my ($user_id) = @_;
    
    for my $guild_id (keys %guilds) {
        return 1 if exists $guilds{$guild_id}{members}{$user_id};
    }
    
    return 0;
}

sub get_display_name {
    my ($user_id) = @_;
    
    for my $guild_id (keys %guilds) {
        if (exists $guilds{$guild_id}{members}{$user_id}) {
            my $member = $guilds{$guild_id}{members}{$user_id};
            
            if ($member->{nick} && $member->{nick} ne '') {
                return $member->{nick};
            }
            if ($member->{global_name} && $member->{global_name} ne '') {
                return $member->{global_name};
            }
            
            my $username = $member->{username};
            $username =~ s/#.*$//;
            return $username;
        }
    }
    
    return "Unknown User";
}

sub get_username {
    my ($user_id) = @_;
    
    for my $guild_id (keys %guilds) {
        if (exists $guilds{$guild_id}{members}{$user_id}) {
            return $guilds{$guild_id}{members}{$user_id}{username};
        }
    }
    
    return "Unknown User";
}

sub get_display_name_in_guild {
    my ($user_id, $guild_id) = @_;
    
    if (exists $guilds{$guild_id}{members}{$user_id}) {
        my $member = $guilds{$guild_id}{members}{$user_id};
        
        if ($member->{nick} && $member->{nick} ne '') {
            return $member->{nick};
        }
        if ($member->{global_name} && $member->{global_name} ne '') {
            return $member->{global_name};
        }
        
        my $username = $member->{username};
        $username =~ s/#.*$//;
        return $username;
    }
    
    return "Unknown User";
}

sub get_username_in_guild {
    my ($user_id, $guild_id) = @_;
    
    if (exists $guilds{$guild_id}{members}{$user_id}) {
        return $guilds{$guild_id}{members}{$user_id}{username};
    }
    
    return "Unknown User";
}

1;
