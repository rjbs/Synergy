use v5.24.0;
use warnings;
package Synergy::LiquidPlanner::Helper;

use Moose;

use experimental qw(signatures lexical_subs);
use namespace::clean;

use Archive::Zip;
use Archive::Zip::MemberRead;
use Future;
use JSON::MaybeXS;

use Synergy::Util qw(
  canonicalize_names

  result_ok result_err
);

use Synergy::Logger '$Logger';

use utf8;

my $JSON = JSON::MaybeXS->new->utf8;

has http_provider => (
  is => 'ro',
  required => 1,
  weak_ref => 1,
  handles  => [ qw(http_get) ],
);

has lp_client => (
  is => 'ro',
  required => 1,
);

has tags_archive_url => (
  is => 'ro',
  predicate => 'has_tags_archive_url',
);

has tag_config_f => (
  is => 'ro',
  lazy    => 1,
  clearer => 'clear_tag_config',
  default => sub ($self) {
    return Future->done({}) unless $self->has_tags_archive_url;
    my $f = $self->http_get($self->tags_archive_url);

    $f->then(sub ($res) {
      unless ($res->is_success) {
        $Logger->log("Failed to get tags archive");
        return Future->done({});
      }

      my $config;

      my $zip_bytes = $res->decoded_content(charset => 'none');
      open my $bogus_fh, '+<', \$zip_bytes;

      my $zip = Archive::Zip->new;
      unless ($zip->readFromFileHandle($bogus_fh) == Archive::Zip::AZ_OK()) {
        $Logger->log("Failed to process tag archive zip content");
        return Future->done({});
      }

      my $reader = Archive::Zip::MemberRead->new($zip, 'Tags/approved-tags.json');
      my $json = q{};
      while (my $str = $reader->getline) {
        $json .= $str;
      }

      my $data = eval { $JSON->decode($json); };
      unless ($data) {
        $Logger->log("failed to get JSON from tag config");
        return Future->done({});
      }

      return Future->done($data)
    });
  },
);

sub _tag_to_search ($self, $tag) {
  my ($got_p) = $self->project_for_shortcut($tag)->get;
  return [ [ project => "#$tag" ] ] if $got_p->is_ok && $got_p->is_nil;

  my $got = $self->tag_config_f->get->{$tag};

  unless ($got) {
    return [ [ tags => fc $tag ] ];
  }

  if ($got->{target} && $got->{target}->@*) {
    return [ map {; [ tags => $_ ] } $got->{target}->@* ];
  }

  # TODO: support specials?

  # ???
  return;
}

sub _get_treeitem_shortcuts {
  my ($self, $type) = @_;

  my $lpc = $self->lp_client;
  my $res = $lpc->query_items({
    filters => [
      [ item_type => '='  => $type    ],
      [ is_done   => is   => 'false'  ],
      [ "custom_field:'Synergy $type Shortcut'" => 'is_set' ],
    ],
  });

  $res = $res->else(sub {
    $Logger->log([ "failed to get $type shortcuts: %s", [@_] ]);
    return Future->done({});
  });

  return $res->then(sub ($items) {
    my %dict;
    my %seen;

    for my $item ($res->get->@*) {
      # Impossible, right?
      next unless my $shortcut = $item->{custom_field_values}{"Synergy $type Shortcut"};

      # Because of is_packaged_version field leading to dupes. -- rjbs 2018-07-05
      next if $seen{ $item->{id} }++;

      # We'll deal with conflicts later. -- rjbs, 2018-01-22
      $dict{ lc $shortcut } //= [];

      # But don't add the same project twice. -- michael, 2018-04-24
      my @existing = grep {; $_->{id} eq $item->{id} } $dict{ lc $shortcut }->@*;
      if (@existing) {
        $Logger->log([
          qq{Duplicate %s %s found; got %s, conflicts with %s},
          "\l$type",
          $shortcut,
          $item->{id},
          [ map {; $_->{id} } @existing ],
        ]);
        next;
      }

      $item->{shortcut} = $shortcut; # needed?
      push $dict{ lc $shortcut }->@*, $item;
    }

    return Future->done(\%dict);
  });
}

has project_shortcuts_f => (
  is => 'ro',
  lazy    => 1,
  clearer => 'clear_project_shortcuts',
  default => sub ($self, @) { $self->_get_treeitem_shortcuts('Project') }
);

has task_shortcuts_f => (
  is => 'ro',
  lazy    => 1,
  clearer => 'clear_task_shortcuts',
  default => sub ($self, @) { $self->_get_treeitem_shortcuts('Project') }
);

sub _item_for_shortcut ($self, $thing, $shortcut) {
  my $getter = "$thing\_shortcuts_f";
  $self->$getter->then(sub ($shortcuts) {
    my $got = $shortcuts->{ fc $shortcut };

    unless ($got && @$got) {
      return Future->done(
        result_err(qq{Sorry, I don't know a $thing with the shortcut "$shortcut".})
      );
    }

    if (@$got > 1) {
      return Future->done(
        result_err(qq{More than one LiquidPlanner $thing has the shortcut }
                 . qq{"$shortcut".  Their ids are: }
                 . join(q{, }, map {; $_->{id} } @$got))
      );
    }

    return Future->done(result_ok($got->[0]));
  });
}

sub project_for_shortcut ($self, $shortcut) {
  $self->_item_for_shortcut(project => $shortcut);
}

sub task_for_shortcut ($self, $shortcut) {
  $self->_item_for_shortcut(task => $shortcut);
}

sub _parse_search ($self, $text) {
  my %aliases = (
    u => 'owner',
    o => 'owner',
    user => 'owner',
  );

  state $prefix_re  = qr{!?\^?};

  my $fallback = sub ($text_ref) {
    if ($$text_ref =~ s/^\#\#?($Synergy::Util::ident_re)(?: \s | \z)//x) {
      my $tag = $1;

      my $instr = $self->_tag_to_search($tag);
      return @$instr;
    }

    if ($$text_ref =~ s/^($prefix_re)$Synergy::Util::qstring\s*//x) {
      my ($prefix, $word) = ($1, $2);

      return [
        'name',
        ( $prefix eq ""   ? "contains"
        : $prefix eq "^"  ? "starts_with"
        : $prefix eq "!^" ? "does_not_start_with"
        : $prefix eq "!"  ? "does_not_contain" # fake operator
        :                   ()),
        ($word =~ s/\\(["“”])/$1/gr)
      ]
    }

    # Just a word.
    ((my $token), $$text_ref) = split /\s+/, $$text_ref, 2;
    $token =~ s/\A($prefix_re)//;
    my $prefix = $1;

    return [
      'name',
      ( $prefix eq ""    ? "contains"
      : $prefix eq "^"   ? "starts_with"
      : $prefix eq "!^"  ? "does_not_start_with"
      : $prefix eq "!"   ? "does_not_contain" # fake operator
      :                    undef),
      $token,
    ];
  };

  my $hunks = Synergy::Util::parse_colonstrings($text, { fallback => $fallback });

  canonicalize_names($hunks, \%aliases);

  # XXX This is garbage, we want a "real" error.
  # The valid forms are [ name => value ] and [ name => op => value ]
  # so [ name => x = y => z... ] is too many and we barf.
  # -- rjbs, 2019-06-23
  return undef if grep {; @$_ > 3 } @$hunks;

  return [
    map {;
      +{
        field => $_->[0],
        (@$_ > 2) ? (op => $_->[1], value => $_->[2])
                  : (               value => $_->[1]),
      }
    } @$hunks
  ];
}


no Moose;
__PACKAGE__->meta->make_immutable;
