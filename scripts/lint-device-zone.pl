use strict; use warnings; use File::Find;

# The earnings path: money is computed here, so a device zone reaching it
# would reprice history the moment the user travels.
my @roots = ("Payday/Earnings", "Payday/Utilities/LegacyLedgerBridge.swift");

# The device zone is legitimately consulted at exactly these sites, each to
# FREEZE it into a policy or as the documented first-launch fallback before
# any policy exists. Counted, not merely named, so a second fallback inside an
# allowlisted file still fails.
my %allow = (
  # `?? .current` when there is no calendar policy at all, which is a first
  # launch before the migration. PolicyStore then freezes the device zone into
  # a policy, so this is unreachable afterwards.
  "Payday/Earnings/ShiftInputAdapter.swift" => 1,
  "Payday/Earnings/EarningsStore.swift"     => 1,
  # Draft PREVIEW only, pre-save, never a stored or valued figure.
  "Payday/Earnings/ShiftDraftPreview.swift" => 2,
);

my @files;
for my $r (@roots) {
  if (-d $r) { find(sub { push @files, $File::Find::name if /\.swift$/ }, $r) }
  elsif (-f $r) { push @files, $r }
}

my @problems;
for my $f (sort @files) {
  open(my $fh, "<", $f) or next;
  local $/; my $src = <$fh>; close $fh;
  $src =~ s{/\*.*?\*/}{}gs;
  $src =~ s{//[^\n]*}{}g;
  my $n = () = $src =~ /(?<![A-Za-z_.])\.current\b|\bTimeZone\.current\b|\bCalendar\.current\b/g;
  my $allowed = $allow{$f} // 0;
  next if $n == $allowed;
  push @problems, "$f: $n device-zone reference(s), allowlisted for $allowed";
}
print "$_\n" for @problems;
