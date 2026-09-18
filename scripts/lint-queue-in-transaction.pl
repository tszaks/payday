use strict; use warnings; use File::Find;
my @files; my @hits;
find(sub { push @files, $File::Find::name if /\.swift$/ }, "Payday", "PaydayWidget");
for my $f (sort @files) {
  open(my $fh, "<", $f) or next;
  local $/; my $src = <$fh>; close $fh;
  $src =~ s{/\*.*?\*/}{}gs;
  $src =~ s{//[^\n]*}{}g;
  while ($src =~ /\bShiftCommands\.(?:commit|perform)\s*\(/g) {
    my $i = pos($src) - 1; my $len = length($src);
    # balance the argument parens
    my $d = 0;
    while ($i < $len) {
      my $c = substr($src, $i, 1);
      $d++ if $c eq "("; $d-- if $c eq ")";
      last if $d == 0; $i++;
    }
    # find the trailing closure's opening brace
    $i++;
    while ($i < $len && substr($src, $i, 1) =~ /\s/) { $i++ }
    next unless $i < $len && substr($src, $i, 1) eq "{";
    my $bodyStart = $i; $d = 0;
    while ($i < $len) {
      my $c = substr($src, $i, 1);
      $d++ if $c eq "{"; $d-- if $c eq "}";
      last if $d == 0; $i++;
    }
    my $body = substr($src, $bodyStart, $i - $bodyStart + 1);
    # Widened 2026-09-18. The rule originally knew only the TIP queue symbols,
    # and missed the identical bug in `ShiftCommands.delete` and `.restore`,
    # which write the shift and legacy-entry queues inside `perform`. Any
    # PaydaySyncState queue mutation counts: they all land in App Group
    # UserDefaults, which `rollback()` cannot reach, whatever they are called.
    next unless $body =~ /PaydaySyncState\.(?:record|cancel|clear|mark)\w*(?:Deletion|Deletions|Restore|Restores|Tombstone|Tombstones)\w*\s*\(/;
    my $line = 1 + (() = substr($src, 0, $bodyStart) =~ /\n/g);
    push @hits, "$f:$line";
  }
}
print "$_\n" for @hits;
