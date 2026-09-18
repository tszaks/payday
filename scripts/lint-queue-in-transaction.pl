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
    next unless $body =~ /\b(?:record|cancel)TipDeletions\b/;
    my $line = 1 + (() = substr($src, 0, $bodyStart) =~ /\n/g);
    push @hits, "$f:$line";
  }
}
print "$_\n" for @hits;
