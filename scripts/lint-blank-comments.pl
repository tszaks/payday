#!/usr/bin/perl
# Emits `path:line:text` for every line of every Swift file under the given
# roots, with COMMENTS BLANKED (replaced by spaces, so column offsets and line
# numbers are untouched).
#
# Why design-lint needs this. Every `run_check` rule is of the form "this
# spelling must not appear outside these files", and grep cannot tell a CALL
# from a MENTION. So a rule fired on a comment that merely NAMED the banned
# spelling -- `StatsRecordAdapter`'s header explains why it must not re-derive
# the v1 split, quotes `voluntaryTipsCents(` to say so, and was reported as a
# violation for explaining itself.
#
# That is the repo's most expensive recurring bug class, in its own words: a
# check that invents its own answer. It has been paid for in a gate doc's grep
# matching a comment in the wrong directory, in an inline perl that printed
# [PASS] while erroring, and here. Blanking comments once, centrally, removes
# the whole class from all rules at once rather than rewording each comment
# that trips one.
use strict; use warnings;
my @roots = @ARGV;
for my $root (@roots) {
    next unless -d $root;
    open(my $fh, '-|', 'find', $root, '-name', '*.swift') or next;
    while (my $path = <$fh>) {
        chomp $path;
        open(my $in, '<', $path) or next;
        my $src = do { local $/; <$in> };
        close $in;
        # Comments ONLY. String contents are deliberately left intact: some
        # rules legitimately match inside a literal (a SQL fragment, a DSN),
        # and blanking strings would have silently disarmed them while every
        # rule still printed [PASS]. That is the same false-signal shape this
        # file exists to remove, so the fix stays no wider than the defect.
        $src =~ s{//[^\n]*}{ ' ' x length($&) }ge;
        $src =~ s{/\*.*?\*/}{ $& =~ s/[^\n]/ /gr }ges;
        my $n = 0;
        for my $line (split /\n/, $src, -1) {
            $n++;
            print "$path:$n:$line\n";
        }
    }
    close $fh;
}
