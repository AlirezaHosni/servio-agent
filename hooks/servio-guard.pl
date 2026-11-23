#!/usr/bin/env perl
# servio-guard.pl: the PreToolUse hook for Claude Code's Bash tool (items 39, 43).
#
# It does NOT try to catch every bad command (a 4,300-line classifier elsewhere still had 27
# bypass advisories in a year). It only ALLOWS what it can PROVE, and otherwise asks or denies:
#
#   1. secrets backstop          a private key anywhere, or a .env file in a command that reaches
#                                a server  ->  DENY. The command is read twice: as written, and with
#                                backslashes and quotes removed (r\m, ".e"nv). A wildcard near a
#                                secret (.e*, id_*, .ssh/*) counts too.
#   2. the plugin's own run.sh,  bash <THIS plugin's run.sh> <alias> <script> [args]
#      in its exact form         - a read-only script, or any script with --dry-run  ->  ALLOW
#                                - a change script  ->  ASK (naming the server and the site)
#   3. run.sh in any other form  (chained, piped, another path)  ->  ASK
#   4. other commands that reach a server (ssh, scp, sftp, rsync, mosh)  ->  ASK with a warning
#   5. anything else             no decision: Claude Code's normal permission rules apply
#
# No settings: built for a small team (2-3 servers), where every change simply asks.
#
# Output: Claude Code's JSON ({"hookSpecificOutput": {"permissionDecision": ...}}), exit 0.
# If the input can't be read, it asks (never a silent allow).
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use File::Spec;

my @READ_ONLY = qw(inventory.sh job-status.sh);
my @CHANGES   = qw(provision-server.sh create-site.sh deploy-site.sh issue-certificate.sh delete-site.sh job-stop.sh);
my $MAX_LEN   = 20000;   # longer commands aren't checked: asked instead (and no slow regexes)

sub decide {
    my ($decision, $reason) = @_;
    print encode_json({ hookSpecificOutput => {
        hookEventName => 'PreToolUse',
        permissionDecision => $decision,
        permissionDecisionReason => "servio-agent: $reason",
    } }), "\n";
    exit 0;
}

# ---- read the tool call -------------------------------------------------------------------
my $raw = do { local $/; <STDIN> } // '';
my $input = eval { decode_json($raw) };
decide('ask', "couldn't read this command to check it.") unless ref $input eq 'HASH';
exit 0 unless ($input->{tool_name} // '') eq 'Bash';
my $cmd = $input->{tool_input}{command};
decide('ask', "couldn't read this command to check it.") unless defined $cmd && !ref $cmd;
decide('ask', 'this command is too long to check; please review it yourself.') if length($cmd) > $MAX_LEN;

# ---- 1. secrets backstop ------------------------------------------------------------------
# Reading 2: backslashes and quotes removed, so r\m, ".e"nv and '.env' read as rm, .env, .env.
(my $flat = $cmd) =~ s/[\\'"]//g;
# A command word: at the start, or after a space ; & | ( ` a quote or / (/usr/bin/ssh), and
# followed by a space or the end. So `ssh web1 …` counts, `ls ~/.ssh` does not.
my $remote_re = qr{(?:^|[\s;&|(`'"/])(?:ssh|scp|sftp|rsync|mosh|run\.sh)(?=[\s;&|)`'"]|$)};
my $remote = ($cmd =~ $remote_re || $flat =~ $remote_re);

for my $text ($cmd, $flat) {
    # Private keys, anywhere. Whole file names, so id_ed25519.pub doesn't match.
    while ($text =~ /(?:^|[^A-Za-z0-9_])((?:id_(?:rsa|dsa|ecdsa|ecdsa_sk|ed25519|ed25519_sk)|deploy_[a-z0-9.-]+[a-z]|privkey[0-9]*\.pem|ssh_host_[a-z0-9]+_key|[A-Za-z0-9_-]+\.key)(?:\.pub)?)(?![A-Za-z0-9_.])/g) {
        decide('deny', "this command mentions a private key file ($1). Keys are never read, printed or copied.")
            unless $1 =~ /\.pub$/;
    }
    decide('deny', 'this command mentions a .pem file in .ssh or letsencrypt.')
        if $text =~ m{(?:\.ssh|letsencrypt)/\S*\.pem};
    # A wildcard where a key would be: id_*, id_ed*, privkey*, .ssh/*
    decide('deny', 'this command uses a wildcard where private keys live (id_*, privkey*, .ssh/*).')
        if $text =~ m{(?:^|[^A-Za-z0-9_])id_[a-z0-9_]*[*?\[]|privkey[0-9]*[*?\[]|\.ssh/[^\s]*[*?\[]};
    if ($remote) {
        # .env files on a server (the templates .env.example / .sample / .dist are fine)
        while ($text =~ /(?:^|[^A-Za-z0-9_])\.env(\.[A-Za-z0-9_-]+)?(?![A-Za-z0-9_.-])/g) {
            my $suffix = $1 // '';
            next if $suffix =~ /^\.(?:example|sample|dist)$/;
            decide('deny', 'this command touches a .env file on a server. .env files are never read, printed or edited; inventory.sh shows whether one exists.');
        }
        decide('deny', 'this command uses a wildcard that could match a .env file on a server (.e*, .env*).')
            if $text =~ /(?:^|[^A-Za-z0-9_])\.e(?:n|nv)?[*?\[]/;
    }
}

# ---- 2. the plugin's own run.sh, in its exact form ---------------------------------------
# Where THIS plugin's run.sh is. Only that file is trusted: a run.sh written anywhere else (for
# example by a prompt-injected agent) is never auto-allowed.
my $plugin_root = $ENV{CLAUDE_PLUGIN_ROOT} // File::Spec->catdir(dirname(File::Spec->rel2abs(__FILE__)), '..');
my $windows = ($^O =~ /^(MSWin32|msys|cygwin)$/);
sub norm_path {
    my ($p) = @_;
    $p =~ s{\\}{/}g;                                     # C:\x -> C:/x
    $p =~ s{^([A-Za-z]):/}{'/' . lc($1) . '/'}e;         # C:/x -> /c/x (Git Bash style)
    $p =~ s{/\./}{/}g; $p =~ s{/+}{/}g;
    1 while $p =~ s{/[^/]+/\.\./}{/};                    # a/b/../c -> a/c
    $p = lc $p if $windows;                              # Windows paths ignore case
    return $p;
}
my $our_run = norm_path("$plugin_root/skills/server-ops/scripts/run.sh");

sub parse_exact_run {
    my ($c) = @_;
    # Nothing the shell would treat specially: no chaining, pipes, redirects, substitutions,
    # variables, newlines. (A real path may contain spaces or backslashes: only inside quotes.)
    return undef if $c =~ /[;&|<>`\$(){}\n\r]/;
    my @w;
    while ($c =~ /\G\s*(?:"([^"]*)"|'([^']*)'|([^\s"'\\]+))/gc) {
        push @w, defined $1 ? $1 : defined $2 ? $2 : $3;
    }
    return undef unless ($c =~ /\G\s*$/gc);             # leftovers (a stray quote or backslash)
    return undef unless @w >= 4 && $w[0] eq 'bash';
    return undef unless norm_path($w[1]) eq $our_run;
    return { host => $w[2], script => $w[3], args => [@w[4 .. $#w]] };
}

if (my $r = parse_exact_run($cmd)) {
    my ($host, $script, @args) = ($r->{host}, $r->{script}, @{ $r->{args} });
    # The same checks run.sh makes; run.sh would refuse anyway, but then don't pre-approve it.
    decide('ask', "unusual host alias '$host'.") unless $host =~ /^[A-Za-z0-9_][A-Za-z0-9._-]*(?:@[A-Za-z0-9_][A-Za-z0-9._-]*)?$/;
    for my $a (@args) {
        decide('ask', 'unusual characters in the arguments.') unless $a =~ m{^[A-Za-z0-9._:/@+-]+$};
    }
    my $dry = grep { $_ eq '--dry-run' } @args;
    # The site (most scripts take the domain first), so the prompt says exactly what changes.
    my ($site) = grep { /^[a-z0-9.-]+\.[a-z]{2,}$/ } @args;
    my $where = $site ? "$site on $host" : $host;
    if (grep { $_ eq $script } @READ_ONLY) {
        decide('allow', "read-only: $script on $host.");
    }
    if (grep { $_ eq $script } @CHANGES) {
        decide('allow', "dry run of $script for $where: nothing is changed.") if $dry;
        decide('ask', "$script CHANGES $where. Approve only if you saw its dry run and it's the right server and site.");
    }
    decide('ask', "unknown script '$script' for run.sh.");
}

# ---- 3. run.sh in any other form ----------------------------------------------------------
decide('ask', 'run.sh is used in an unexpected form (chained, piped, or not the plugin\'s own run.sh). Review the whole command.')
    if $cmd =~ /run\.sh/ || $flat =~ /run\.sh/;

# ---- 4. other commands that reach a server ------------------------------------------------
if ($remote) {
    decide('ask', 'this command reaches a server WITHOUT the reviewed scripts (ssh/scp/sftp/rsync). Check exactly what it does before approving.');
}

# ---- 5. anything else: no decision ---------------------------------------------------------
exit 0;
