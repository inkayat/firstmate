#!/usr/bin/env bash
# fm-hold-reason-lib.sh - the one reversible encoding of a captain-hold reason.
#
# tasks-axi stores a hold reason as one markdown line inside a parenthesised tag,
# so its own `hold` refuses parentheses and line breaks. A decision reason is
# ordinary prose, so bin/fm-captain-hold.sh encodes the reason where it writes
# it and every reader that shows it decodes it again, instead of banning the
# characters. Stored reasons use the reserved fm-hold-v1: prefix followed by
# base64-encoded UTF-8 text. Unmarked reasons are plain text. Readers decode only
# the hold-reason field, once, and keep line breaks in quoted output strings.
#
# It also owns the one rule for a captain call's request GENERATION, the opaque
# version a console binds a reply to:
#   <hold-set stamp>#<recorded answer count>#<sha256 of title LF decoded reason>
# The stamp and count change with every new lifecycle of the call; the digest
# changes whenever the title or the decoded reason the captain is shown changes,
# including an in-place re-hold that keeps the stamp. A stamp-less legacy hold has
# an empty first part. bin/fm-fleet-snapshot.sh applies it once, in its one
# backlog parser, so every reader - the combined view and the answer check -
# sees the same value for the same row.
#
# Source this file; it defines functions only.

# fm_hold_reason_encode <reason>: print the storable form, no trailing newline.
fm_hold_reason_encode() {
  printf '%s' "$1" | perl -MMIME::Base64=encode_base64 -0777 -ne \
    'print "fm-hold-v1:", encode_base64($_, "")'
}

# fm_hold_reason_decode_stream [toon|markdown|json]: decode marked reason fields.
fm_hold_reason_decode_stream() {
  perl -MJSON::PP -MMIME::Base64=encode_base64,decode_base64 -MEncode=decode,FB_CROAK -e '
    use strict;
    use warnings;
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my $format = shift;
    my $json = JSON::PP->new->allow_nonref;
    sub decode_reason {
      my ($value) = @_;
      return $value unless defined($value) && $value =~ /^fm-hold-v1:(.*)\z/s;
      my $payload = $1;
      my $bytes = decode_base64($payload);
      return $value unless encode_base64($bytes, "") eq $payload;
      # Historical literals with valid base64 and UTF-8 remain indistinguishable
      # from encoded reasons; malformed payloads retain their stored text.
      my $decoded = eval { decode("UTF-8", $bytes, FB_CROAK) };
      return $@ ? $value : $decoded;
    }
    sub decode_field {
      my ($raw) = @_;
      my $value = $raw =~ /^"/ ? $json->decode($raw) : $raw;
      my $decoded = decode_reason($value);
      return $decoded eq $value ? $raw : $json->encode($decoded);
    }
    if ($format eq "json") {
      local $/;
      my $snapshot = $json->decode(<STDIN>);
      for my $record (@{$snapshot->{records}}) {
        $record->{hold_reason} = decode_reason($record->{hold_reason})
          if exists $record->{hold_reason};
      }
      print $json->encode($snapshot), "\n";
      exit;
    }
    my ($column, $task);
    while (my $line = <STDIN>) {
      if ($format eq "markdown") {
        $line =~ s{^([-*] .*\(hold:\s*)(fm-hold-v1:[A-Za-z0-9+/]*={0,2})(\).*)$}
          {$1 . decode_field($2) . $3}e;
      } elsif ($line =~ /^tasks\[\d+\]\{([^}]*)\}:\n?$/) {
        my @names = split /,/, $1;
        ($column) = grep { $names[$_] eq "hold_reason" } 0 .. $#names;
        $task = 0;
      } elsif (defined($column) && $line =~ /^  (.*)\n?$/) {
        my @fields = $1 =~ /("(?:[^"\\]|\\.)*"|[^,]+)/g;
        $fields[$column] = decode_field($fields[$column]);
        $line = "  " . join(",", @fields) . "\n";
      } elsif ($task && $line =~ /^  hold_reason: (.*)\n?$/) {
        $line = "  hold_reason: " . decode_field($1) . "\n";
      } elsif ($line !~ /^  /) {
        $column = undef;
        $task = $line eq "task:\n";
      }
      print $line;
    }
  ' "${1:-toon}"
}

# fm_hold_request_generations: on a backlog JSON document ({records:[...]}, hold
# reasons already decoded) set every structured record's hold_generation to the
# generation above when it is an open captain hold, and to null otherwise.
fm_hold_request_generations() {
  perl -MJSON::PP -MDigest::SHA=sha256_hex -MEncode=encode -e '
    use strict;
    use warnings;
    binmode STDIN, ":encoding(UTF-8)";
    binmode STDOUT, ":encoding(UTF-8)";
    my $json = JSON::PP->new->allow_nonref;
    local $/;
    my $doc = $json->decode(<STDIN>);
    for my $record (@{$doc->{records} || []}) {
      next unless ref($record) eq "HASH" && $record->{structured};
      my $kind = $record->{hold_kind};
      my $reason = $record->{hold_reason};
      my $state = $record->{state};
      if (defined($kind) && $kind eq "captain" && defined($reason)
          && !(defined($state) && $state eq "done")) {
        my $title = defined($record->{title}) ? $record->{title} : $record->{id};
        $title = "" unless defined $title;
        my $stamp = defined($record->{hold_set}) ? $record->{hold_set} : "";
        my $count = defined($record->{hold_resolutions}) ? $record->{hold_resolutions} : 0;
        $record->{hold_generation} = $stamp . "#" . $count . "#"
          . sha256_hex(encode("UTF-8", $title . "\n" . $reason));
      } else {
        $record->{hold_generation} = undef;
      }
    }
    print $json->encode($doc), "\n";
  '
}
