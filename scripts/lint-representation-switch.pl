#!/usr/bin/perl
# Rule 23: no app-code call reads the legacy shift representation alone.
#
# WHY THIS IS PER-CALL-SITE AND NOT PER-FILE. The first version of this check
# asked "does the file mentioning `entries: allEntries` also mention
# `shiftsAreAuthoritativeForCurrentAccount`". It fails in both directions and
# both failures are on the record:
#
#   - FALSE NEGATIVE: `DeleteAccountSheet` references the predicate for its
#     shift COUNT, which would have silenced the rule on the same file's CSV
#     export three lines away -- and that export omitted every post-conversion
#     shift permanently, the most severe defect the sweep found.
#   - FALSE POSITIVE: `DayDetailSheet` passes `entries:` inside its LEGACY
#     initializer, which is correct; the screen switches properly at `body`.
#
# So the unit of judgement is the call, not the file. This walks each call
# expression's balanced parentheses (calls here span many lines) and asks one
# question of the argument list itself: if it hands over the legacy list, does
# it also hand over the records list?
#
# The compiler is the primary enforcement now -- the combined builders take
# both lists and resolve the representation internally, so a legacy-only call
# does not compile. This rule is the BACKSTOP: it catches a NEW builder added
# later with a legacy-only signature, which the compiler cannot object to
# because there is nothing yet to be missing.

use strict;
use warnings;

# Files where a legacy-only `entries:` call is the sanctioned internal arm of
# a combined builder. Each of these DEFINES the switch; they are the one place
# allowed to invoke a single representation deliberately.
my %ARM_DEFINING_FILES = map { $_ => 1 } qw(
    Payday/Utilities/CSVExporter.swift
    Payday/Views/Calendar/CalendarView.swift
    Payday/Views/Calendar/DayDetailSheet.swift
    Payday/Views/Periods/HistoryEarnings.swift
    Payday/Views/Dashboard/DashboardEarnings.swift
    Payday/Views/Insights/InsightsEarnings.swift
    Payday/Earnings/ShiftDraftPreview.swift
);

my @roots = @ARGV;
die "usage: $0 <root>...\n" unless @roots;

my @files;
for my $root (@roots) {
    open(my $fh, '-|', 'find', $root, '-name', '*.swift') or die $!;
    while (my $p = <$fh>) { chomp $p; push @files, $p; }
    close $fh;
}

my @violations;

for my $path (sort @files) {
    (my $rel = $path) =~ s{^\./}{};
    next if $ARM_DEFINING_FILES{$rel};

    open(my $fh, '<', $path) or next;
    my $src = do { local $/; <$fh> };
    close $fh;

    # The original text is kept because the resolved-upstream marker below
    # lives IN a comment -- searching the blanked copy for it would never
    # match, which is precisely the bug this line fixes.
    my $raw = $src;

    # Comments are blanked, not deleted, so byte offsets and therefore line
    # numbers stay exact. Without this, a doc comment naming a legacy
    # spelling reads as a call:
    # `LegacySnapshotRevision.swift` documents the cost of
    # `LegacySnapshotBridge.snapshot(entries:)` in prose and was reported as
    # a violation. A checker that invents its own positives is the family of
    # false signal this repo has paid for four times.
    $src =~ s{//[^\n]*}{ ' ' x length($&) }ge;
    $src =~ s{/\*.*?\*/}{ $& =~ s/[^\n]/ /gr }ges;

    # Every `entries:` label that is an ARGUMENT (preceded by `(` or `,` or
    # newline-whitespace), not a declaration. Declarations are skipped by
    # requiring the value not to be a type annotation.
    while ($src =~ /\bentries\s*:/g) {
        my $label_at = $-[0];

        # Walk backwards to the opening paren of the enclosing call.
        my $depth = 0;
        my $open = -1;
        for (my $i = $label_at - 1; $i >= 0; $i--) {
            my $c = substr($src, $i, 1);
            if ($c eq ')') { $depth++; }
            elsif ($c eq '(') {
                if ($depth == 0) { $open = $i; last; }
                $depth--;
            }
        }
        next if $open < 0;

        # Walk forward from the opening paren to its match: the argument list.
        $depth = 0;
        my $close = -1;
        for (my $i = $open; $i < length($src); $i++) {
            my $c = substr($src, $i, 1);
            if ($c eq '(') { $depth++; }
            elsif ($c eq ')') {
                $depth--;
                if ($depth == 0) { $close = $i; last; }
            }
        }
        next if $close < 0;

        my $args = substr($src, $open + 1, $close - $open - 1);

        # A function DECLARATION, not a call: `entries: [TipEntry]` names a
        # type. Those are the builders' own parameter lists.
        next if $args =~ /\bentries\s*:\s*\[/;

        # Already switched: the call hands over both lists.
        next if $args =~ /\brecords\s*:/;
        next if $args =~ /\bshiftRecords\s*:/;

        # WidgetKit's `Timeline(entries:policy:)`. Its `entries` are
        # TIMELINE entries -- one rendering per future date -- and have
        # nothing to do with `TipEntry`. Matched on the `policy:` companion
        # label rather than on the type name, because the constructor is
        # sometimes spelled without one.
        next if $args =~ /\bpolicy\s*:\s*\./;

        # A TUPLE literal whose label happens to be `entries`, not a call
        # reading a representation. `LogTipsIntent.targetShiftID` groups
        # today's rows into `(shiftID:entries:)` pairs; it is reached only
        # from the legacy arm and reads no builder. Listed explicitly, with
        # its shape, rather than loosened into a pattern that would also
        # excuse a real builder call.
        next if $args =~ /^\s*shiftID\s*:\s*\w+\s*,\s*entries\s*:\s*\w+\s*$/;

        # An explicit, line-level exemption for a call whose representation
        # was ALREADY resolved by a caller, marked at the call itself.
        #
        # It exists for exactly one shape, and a whole-file exemption would
        # have been wrong for it. `PaydayPushScheduler.spokenFigure` is
        # deliberately `nonisolated` so the suite can exercise the payday rule
        # without a main actor, while adapting a `ShiftRecord` is main-actor
        # work -- so that function CANNOT call a combined builder, and its
        # choice is made upstream in `performReschedule` and handed down as
        # an already-adapted value. Exempting the file would have silenced the
        # rule on anything else added to it later, which is the same
        # false-negative shape that let the CSV export hide behind a predicate
        # three lines away. The marker travels with the call instead.
        # Offsets are identical in both copies (comments were blanked, not
        # removed), so the marker is looked for in the ORIGINAL text in the
        # 400 bytes leading up to the call.
        my $lead_from = $open - 400 < 0 ? 0 : $open - 400;
        my $lead = substr($raw, $lead_from, $open - $lead_from);
        next if $lead =~ /lint:representation-resolved-upstream/;

        my $line = 1 + (() = substr($src, 0, $label_at) =~ /\n/g);
        my $snippet = $args;
        $snippet =~ s/\s+/ /g;
        $snippet = substr($snippet, 0, 90);
        push @violations, "$rel:$line: reads the legacy representation alone: ($snippet)";
    }
}

if (@violations) {
    print "$_\n" for @violations;
    exit 1;
}
exit 0;
