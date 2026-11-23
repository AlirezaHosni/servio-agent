#!/usr/bin/env bash
# traffic.sh: who visited a site and what they got, over the last N minutes (item 60).
# READ-ONLY: changes nothing.
#
#   bash run.sh <host> traffic.sh <domain> [minutes]     # default 60, at most 1440 (a day)
#
# From the site's nginx access log: requests by status, 404 and 5xx counts, the top 10 addresses
# and paths, the busiest minute, scanner probes (/wp-login.php, /.env, /.git...) per address and,
# if the log records how long each request took, the slowest pages.
#
# Paths are shown WITHOUT their query string (?token=... stays out) and only when they're made
# of plain URL characters: visitors choose paths, and the output goes to an AI.
#
# Only the current log file is read (not yesterday's rotated .1 file); the window is cut there.
# The parsing is perl (always on Ubuntu) with no modules: Ubuntu's awk (mawk) has no date maths.

NGINX_LOG_DIR="/var/log/nginx"
MAX_MINUTES=1440
READ_LINES=500000

main() {
    local domain="${1:-}" minutes="${2:-60}" log
    [ -n "$domain" ] || die_input "Usage: traffic.sh <domain> [minutes]"
    validate_domain "$domain"
    [[ "$minutes" =~ ^[0-9]{1,5}$ && "$minutes" -ge 1 && "$minutes" -le "$MAX_MINUTES" ]] \
        || die_input "minutes must be from 1 to $MAX_MINUTES."
    require_root
    log="$NGINX_LOG_DIR/$domain-access.log"
    [ ! -L "$log" ] || die_refused "$log is a symlink; not following it."
    [ -f "$log" ] || die_state "No $log (no requests yet, or not a site on this server)."

    step "Traffic of $domain, last $minutes minutes"
    tail -n "$READ_LINES" "$log" | traffic_summary "$(( $(date -u +%s) - minutes * 60 ))"
}

# traffic_summary <since (epoch seconds)>: reads access log lines on stdin.
# Format "combined": ip - user [23/Nov/2026:10:00:00 +0000] "GET /path HTTP/1.1" status bytes
# "referer" "agent", optionally followed by the request time in seconds (e.g. 0.123).
traffic_summary() {
    perl -e '
use strict; use warnings;
my $since = shift @ARGV;
my %mon = (Jan=>1,Feb=>2,Mar=>3,Apr=>4,May=>5,Jun=>6,Jul=>7,Aug=>8,Sep=>9,Oct=>10,Nov=>11,Dec=>12);
# Days since 1970-01-01 for a date (the "days from civil" formula; no module needed).
sub days { my ($y, $m, $d) = @_; $y -= $m <= 2; my $era = int($y / 400);
    my $yoe = $y - $era * 400; my $doy = int((153 * ($m + ($m > 2 ? -3 : 9)) + 2) / 5) + $d - 1;
    my $doe = $yoe * 365 + int($yoe / 4) - int($yoe / 100) + $doy; return $era * 146097 + $doe - 719468; }
my $PROBE = qr{(?:wp-login\.php|wp-admin|xmlrpc\.php|/\.env|/\.git|phpmyadmin|/vendor/phpunit|/cgi-bin/|\.aws/|/actuator|/boaform|/HNAP1)}i;
sub clean_path { my $p = shift; $p =~ s/[?#].*//s; $p = substr($p, 0, 80);
    return $p =~ m{^/[A-Za-z0-9._~/%+:@,;=-]*$} ? $p : "(odd path)"; }
my (%status, %ip, %path, %minute, %probe_ip, %probe_path, @slow);
my ($total, $has_time, $skipped) = (0, 0, 0);
while (my $line = <STDIN>) {
    my ($addr, $dd, $mm, $yy, $hh, $mi, $ss, $tz, $req, $code, $rest) = $line =~
        m{^(\S+) \S+ \S+ \[(\d\d)/(\w{3})/(\d{4}):(\d\d):(\d\d):(\d\d) ([+-]\d{4})\] "([^"]*)" (\d{3}) \S+(.*)$}
        or do { $skipped++; next };
    next unless $mon{$mm};
    my $off = (substr($tz, 1, 2) * 3600 + substr($tz, 3, 2) * 60) * (substr($tz, 0, 1) eq "-" ? -1 : 1);
    my $t = days($yy, $mon{$mm}, $dd) * 86400 + $hh * 3600 + $mi * 60 + $ss - $off;
    next if $t < $since;
    $total++;
    $status{$code}++;
    $addr = "(odd address)" unless $addr =~ /^[0-9a-fA-F.:]{3,45}$/;
    $ip{$addr}++;
    my (undef, $target) = split / /, $req;
    my $p = defined $target ? clean_path($target) : "(no path)";
    $path{$p}++;
    $minute{"$yy-" . sprintf("%02d", $mon{$mm}) . "-$dd $hh:$mi $tz"}++;
    if (defined $target && $target =~ $PROBE) { $probe_ip{$addr}++; $probe_path{$p}++; }
    if ($rest =~ /\s(\d+\.\d{3})\s*$/) { $has_time = 1; push @slow, [$1, $code, $p]; }
}
sub top { my ($h, $n) = @_; my @k = sort { $h->{$b} <=> $h->{$a} || $a cmp $b } keys %$h;
    splice(@k, $n) if @k > $n; return @k; }
print "Requests: $total\n";
if (!$total) { print "No requests in this window.\n"; exit 0; }
my %class; $class{substr($_, 0, 1) . "xx"} += $status{$_} for keys %status;
print "By status: ", join("  ", map { "$_ x$class{$_}" } sort keys %class), "\n";
print "  codes: ", join("  ", map { "$_ x$status{$_}" } top(\%status, 8)), "\n";
my $n404 = $status{404} // 0; my $n5xx = 0; $n5xx += $status{$_} for grep { /^5/ } keys %status;
print "404: $n404   5xx: $n5xx\n";
my ($busy) = top(\%minute, 1); print "Busiest minute: $busy ($minute{$busy} requests)\n";
print "\nTop addresses:\n"; printf "  %7d  %s\n", $ip{$_}, $_ for top(\%ip, 10);
print "\nTop paths (no query strings):\n"; printf "  %7d  %s\n", $path{$_}, $_ for top(\%path, 10);
print "\nScanner probes (paths like /wp-login.php, /.env, /.git):\n";
if (%probe_ip) {
    my $sum = 0; $sum += $_ for values %probe_ip;
    print "  $sum requests. By address:\n"; printf "  %7d  %s\n", $probe_ip{$_}, $_ for top(\%probe_ip, 5);
    print "  Paths tried:\n"; printf "  %7d  %s\n", $probe_path{$_}, $_ for top(\%probe_path, 5);
} else { print "  none\n"; }
print "\nSlowest requests:\n";
if ($has_time) {
    for my $r ((sort { $b->[0] <=> $a->[0] } @slow)[0 .. 9]) { next unless $r; printf "  %7.3fs  %s  %s\n", @$r; }
} else {
    print "  NOT ASSESSED: this log does not record request times (needs the log format of item C-14)\n";
}
print "\n($skipped lines in another log format were skipped)\n" if $skipped;
' "$1"
}

servio_run "$@"
