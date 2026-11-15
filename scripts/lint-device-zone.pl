use strict; use warnings; use File::Find;

# The earnings path: money is computed here, so a device zone reaching it
# would reprice history the moment the user travels.
my @roots = ("Payday/Earnings");

# The device zone is legitimately consulted at exactly these sites, each to
# FREEZE it into a policy or as the documented first-launch fallback before
# any policy exists. Counted, not merely named, so a second fallback inside an
# allowlisted file still fails.
my %allow = (
  # `?? .current` when there is no calendar policy at all, which is a first
  # launch before the migration. PolicyStore then freezes the device zone into
  # a policy, so this is unreachable afterwards.
  "Payday/Earnings/EarningsStore.swift"     => 1,
  # One is that same first-launch fallback, moved here from
  # ShiftInputAdapter when the adapter began reading work days through
  # StoredDay. The other three are the PHONE's zone as the default for a
  # picker's day (`stored(picked:)`, `shown`) and for the repair of rows the
  # phone wrote (`repaired`); none of them is read by `civilDay`, the
  # engine's reading. ShiftDraftPreview's "today" moved here too.
  "Payday/Earnings/StoredDay.swift"         => 4,
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
