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
use List::Util qw(uniq);

use Synergy::Util qw(
  canonicalize_names

  result_ok result_err
);

use Synergy::Logger '$Logger';

use utf8;

my $JSON = JSON::MaybeXS->new->utf8;

my %Showable_Attribute = (
  shortcuts   => 1,
  phase       => 1,
  project     => 0,
  age         => 0,
  staleness   => 0,
  tags        => 0,
  due         => 1,
  emoji       => 1,
  assignees   => 0,
  estimates   => 0,
  urgency     => 1,
  lastcomment => 0,

  escalation    => 0,
  stakeholders  => 0,
  # stuff we could make optional later:
  #   name
  #   type icon
  #   doneness
);

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

has triage_user_lp_id => (
  is => 'ro',
  isa => 'Int',
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

sub _compile_search ($self, $conds, $from_user) {
  my %flag;
  my %display;
  my %error;

  my @unknown_fields;
  my @unknown_users;

  my sub cond_error ($str) {
    no warnings 'exiting';
    $error{$str} = 1;
    next COND;
  }

  my sub bad_value ($field) {
    cond_error("I don't understand the value you gave for `$field:`.");
  }

  my sub bad_op ($field, $op) {
    cond_error("I don't understand the operator you gave in `$field:$op`.");
  }

  my sub maybe_conflict ($field, $value) {
    cond_error("You gave conflicting values for `$field`.")
      if exists $flag{$field} && differ($flag{$field}, $value);
  }

  my sub differ ($x, $y) {
    return 1 if defined $x xor defined $y;
    return 1 if defined $x && $x ne $y;
    return 0;
  }

  my sub normalize_bool ($field, $value) {
    my $to_set  = $value eq 'yes'   ? 1
                : $value eq 1       ? 1
                : $value eq 'no'    ? 0
                : $value eq 0       ? 0
                : $value eq 'both'  ? undef
                : $value eq '*'     ? undef
                :                     -1;

    bad_value($field) if defined $to_set && $to_set == -1;
    return $to_set;
  }

  COND: for my $cond (@$conds) {
    # field and op are guaranteed to be in fold case.  Value, not.
    my $field = $cond->{field};
    my $op    = $cond->{op};
    my $value = $cond->{value};

    if (grep {; $field eq $_ } qw(done onhold scheduled)) {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = normalize_bool($field, fc $value);

      maybe_conflict($field, $value);

      $flag{$field} = $value;
      next COND;
    }

    if ($field eq 'in') {
      $field = 'project' if $value =~ /\A#/;
    }

    if ($field eq 'in') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = fc $value;
      my $to_set = $value eq 'inbox'              ? $self->inbox_package_id
                 : $value eq 'interrupts'         ? $self->interrupts_package_id
                 : $value eq 'urgent'             ? $self->urgent_package_id
                 : $value =~ /\Adiscuss(ion)?\z/n ? $self->discussion_package_id
                 : $value =~ /\A[0-9]+\z/         ? $value
                 : undef;

      bad_value($field) unless defined $to_set;

      # We could really allow multiple in: here, if we rejigger things.  But do
      # we care enough?  I don't, right this second. -- rjbs, 2019-03-30
      maybe_conflict('in', $to_set);

      $flag{in} = $to_set;
      next COND;
    }

    if ($field eq 'project') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = fc $value;
      $value =~ s/\A#//;
      my ($item, $err) = $self->project_for_shortcut($value);

      cond_error($err) if $err;
      maybe_conflict('project', $item->{id});

      $flag{project} = $item->{id};
      next COND;
    }

    if ($field eq 'tags') {
      bad_op($field, $op) unless ($op//'include') eq 'include';

      $value = fc $value;

      $flag{tags}{$value} = 1;
      next COND;
    }

    if ($field eq 'client') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = fc $value;

      my $to_store;
      if ($value ne '~') {
        bad_value('client') unless my $client = $self->client_named($value);
        $to_store = $client->{id};
      }

      maybe_conflict('client', $to_store // '~');

      $flag{client} = $to_store;
      next COND;
    }

    if ($field eq 'shortcut') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      cond_error(q{The only valid values for `shortcut` are `*` and `~`, meaning "shortcut defined" and "no shortcut defined", respectively.})
        unless $value eq '~' or $value eq '*';

      $flag{shortcut} = $value;
      next COND;
    }

    if ($field eq 'page') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      maybe_conflict('page', $value);

      cond_error("You have to pick a positive integer page number.")
        unless $value =~ /\A[1-9][0-9]*\z/;

      cond_error("Sorry, you can't get a page past the tenth.") if $value > 10;

      $flag{page} = $value;
      next COND;
    }

    if (grep {; $field eq $_ } qw(owner creator)) {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      my $target = $self->resolve_name($value, $from_user);
      my $lp_id  = $target && $target->lp_id;

      unless ($lp_id) {
        push @unknown_users, $value;
        next COND;
      }

      $flag{$field}{$lp_id} = 1;
      next COND;
    }

    for my $pair (
      [ escalation   => [ qw(e esc escalation) ] ],
      [ stakeholders => [ qw(stake stakeholder stakeholders) ] ],
    ) {
      if (grep {; $field eq $_ } $pair->[1]->@*) {
        # These aren't a LiquidPlanner thing, we made them up, so they store
        # canonical usernames, not a member id.  We'll have some sanity check
        # that makes sure we don't have ones with garbage.  Also, we use
        # "contains" because they're comma lists.
        bad_op($field, $op) unless ($op//'is') eq 'is';

        if ($value eq '~') {
          $flag{$pair->[0]}{'~'} = 1;
          next COND;
        }

        my $target = $self->resolve_name($value, $from_user);

        unless ($target) {
          push @unknown_users, $value;
          next COND;
        }

        $flag{$pair->[0]}{$target->username} = 1;
        next COND;
      }
    }

    if ($field eq 'type') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      $value = fc $value;

      bad_value($field)
        unless $value =~ /\A (?: project | task | package | \* ) \z/x;

      maybe_conflict('type', $value);

      # * means explicit "no filter"
      $flag{$field} = $value eq '*' ? undef : $value;
      next COND;
    }

    if ($field eq 'phase') {
      bad_op($field, $op) unless ($op//'is') eq 'is';

      # TODO: get phases from LP definition
      my %Phase = (
        none      => 'none',
        flight    => 'In Flight',
        longhaul  => 'Long Haul',
        map {; $_ => ucfirst } qw(desired planning waiting landing)
      );

      my $to_set = $Phase{ fc $value };

      bad_value($field) unless $to_set;

      $flag{$field} = $to_set;
      next COND;
    }

    if ($field eq 'created' or $field eq 'lastupdated' or $field eq 'closed') {
      cond_error("The `$field` term has to be used like this: `$field:before:YYYY-MM-DD` (or use _after_ instead of _before_).")
        unless defined $op and ($op eq 'after' or $op eq 'before');

      bad_value("$field:$op") unless $value =~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

      cond_error("You gave conflicting values for `$field:$op`.")
        if exists $flag{$field}{$op} && differ($flag{$field}{$op}, $value);

      $flag{$field}{$op} = $value;
      next COND;
    }

    if ($field eq 'show') {
      # Silly hack:  "show:X" means "show:X:yes" so when there is no op, we
      # turn the value into the op and replace the value with "yes".  This is
      # an abuse of the field/op/value system, but so is "show" itself… almost
      # makes you wonder if I'm a bad person for putting the abuse into the
      # code just about 30 minutes after the feature itself.
      # -- rjbs, 2019-03-31
      unless (defined $op) {
        $op = fc $value;
        $value = 'yes';
      }

      bad_op($field, $op) unless exists $Showable_Attribute{ $op };

      $value = normalize_bool($field, fc $value);

      cond_error("You gave conflicting values for `$field:$op`.")
        if exists $flag{$field}{$op} && differ($flag{$field}{$op}, $value);

      $flag{$field}{$op} = $value;
      next COND;
    }

    if ($field eq 'debug' or $field eq 'force') {
      # Whatever, if you put debug:anythingtrue in there, we turn it on.
      # Live with it. -- rjbs, 2019-02-07
      $flag{$field} = 1;
      next COND;
    }

    if ($field eq 'name') {
      # We punt on pretty much any validation here.  So be it.
      # -- rjbs, 2019-03-30
      $flag{name} //= [];
      push $flag{name}->@*, [ $op, $value ];
      next COND;
    }

    push @unknown_fields, $field;
  }

  if (@unknown_fields) {
    my $text = "You used some parameters I don't understand: "
             . join q{, }, sort uniq @unknown_fields;

    $error{$text} = 1;
  }

  if (@unknown_users) {
    my $text = "I don't know who these users are: "
             . join q{, }, sort uniq @unknown_users;

    $error{$text} = 1;
  }

  if (my $show = delete $flag{show}) {
    $display{show} = $show;
  }

  return (\%flag, \%display, (%error ? \%error : undef));
}

sub _execute_search ($self, $lpc, $search, $orig_error = undef) {
  my %flag  = $search ? %$search : ();

  my %error = $orig_error ? %$orig_error : ();

  my %qflag = (flat => 1, depth => -1, order => 'earliest_start');
  my $q_in;
  my @filters;

  my $has_strong_check = 0;

  # We start with a limit higher than one page because there are reasons we
  # need to overshoot.  One common reason: if we've got an "in" filter, the
  # container may be removed, and we want to drop it.  We'll crank the limit up
  # more, later, if we're filtering by user on un-done tasks, because the
  # LiquidPlanner behavior on owner filtering is less than ideal.
  # -- rjbs, 2019-02-18
  my $page_size = 10;
  my ($limit, $offset) = ($page_size + 5, 0);

  unless (exists $flag{done}) {
    $flag{done} = $flag{closed} ? 1 : 0;
  }

  if (defined $flag{done}) {
    push @filters, [ 'is_done', 'is', ($flag{done} ? 'true' : 'false') ];
  }

  if (defined $flag{onhold}) {
    push @filters, [ 'is_on_hold', 'is', ($flag{onhold} ? 'true' : 'false') ];
  }

  if (defined $flag{scheduled}) {
    push @filters, $flag{scheduled}
      ? [ 'earliest_start', 'after', '2001-01-01' ]
      : [ 'earliest_start', 'never' ];
  }

  if (defined $flag{project}) {
    push @filters, [ 'project_id', '=', $flag{project} ];
  }

  if (exists $flag{client}) {
    push @filters, defined $flag{client}
      ? [ 'client_id', '=', $flag{client} ]
      : [ 'client_id', 'is_not_set' ];
  }

  if (defined $flag{tags}) {
    push @filters, map {; [ 'tags', 'include', $_ ] } keys $flag{tags}->%*;
  }

  {
    my %datefield = (
      created => 'created',
      closed  => 'date_done',
      lastupdated => 'last_updated',
    );

    for my $field (keys %datefield) {
      if (my $got = $flag{$field}) {
        for my $op (qw( after before )) {
          if ($got->{$op}) {
            push @filters, [ $datefield{$field}, $op, $got->{$op} ];
          }
        }
      }
    }
  }

  $flag{page} //= 1;
  if ($flag{page}) {
    $offset = ($flag{page} - 1) * 10;
    $limit += $offset;
  }

  if ($flag{owner} && keys $flag{owner}->%*) {
    # So, this is really $!%@# annoying.  The owner_id filter finds tasks that
    # have an assignment for the given owner, but they don't care whether the
    # assignment is done or not.  So, if you're looking for tasks that are
    # undone for a given user, you need to do filtering in the application
    # layer, because LiquidPlanner does not have your back.
    # -- rjbs, 2019-02-18
    push @filters, map {; [ 'owner_id', '=', $_ ] } keys $flag{owner}->%*;

    if (defined $flag{done} && ! $flag{done}) {
      # So, if we're looking for specific users, and we want non-done tasks,
      # let's only find ones where those users' assignments are not done.
      # We'll have to do that filtering at this end, so we need to over-select.
      # I have no idea what to guess, so I picked 3x, just because.
      # -- rjbs, 2019-02-18
      $limit *= 3;
    }
  }

  if ($flag{creator} && keys $flag{creator}->%*) {
    push @filters, map {; [ 'created_by', '=', $_ ] } keys $flag{creator}->%*;
  }

  for my $field (qw( escalation stakeholders )) {
    if ($flag{$field} && keys $flag{$field}->%*) {
      push @filters, map {;
        [
          "custom_field:\u$field",
          ($_ eq '~' ? 'is_not_set' : ('contains', $_)),
        ]
      } keys $flag{$field}->%*;
    }
  }

  if (defined $flag{phase}) {
    # If you're asking for something by phase, you probably want a project.
    # You can override this if you want with "phase:planning type:task" but
    # it's a little weird. -- rjbs, 2019-02-07
    $flag{type} //= 'project';

    push @filters,
      $flag{phase} eq 'none'
      ? [ "custom_field:'Project Phase'", 'is_not_set' ]
      : [ "custom_field:'Project Phase'", '=', "'$flag{phase}'" ];
  }

  if ($flag{type}) {
    push @filters, [ 'item_type', 'is', ucfirst $flag{type} ];
  }

  if (defined $flag{in}) {
    $q_in = $flag{in};
  }

  if (defined $flag{done} and ! $flag{done}) {
    # If we're only looking at open tasks in one container, we'll assume it's a
    # small enough set to just search. -- rjbs, 2019-02-07
    $has_strong_check = 1 if $flag{in};

    # If we're looking for only open triage tasks, that should be small, too.
    # -- rjbs, 2019-02-08
    if (defined (my $triage_id = $self->triage_user_lp_id)) {
      $has_strong_check = 1 if grep {; $_ == $triage_id } keys $flag{owner}->%*;
    }
  }

  if (exists $flag{shortcut}) {
    if (
      ! $flag{type}
      or ($flag{type} ne 'task' && $flag{type} ne 'project')
    ) {
      $error{"You can't search by missing shortcuts unless you specify a `type` of project or task."} = 1;
    } else {
      push @filters, [
        "custom_field:'Synergy \u$flag{type} Shortcut'",
        ( $flag{shortcut} eq '~' ? 'is_not_set'
        : $flag{shortcut} eq '*' ? 'is_set'
        :                           'designed_to_fail'), # no -r
      ];
    }
  }

  $has_strong_check = 1
    if ($flag{project} || $flag{in})
    || ($flag{debug} || $flag{force})
    || ($flag{type} && $flag{type} ne 'task')
    || ($flag{phase} && (defined $flag{done} && ! $flag{done})
                     && ($flag{phase} ne 'none' || $flag{type} ne 'task'));

  if ($flag{name}) {
    MATCHER: for my $matcher ($flag{name}->@*) {
      my ($op, $value) = @$matcher;
      if ($op eq 'does_not_contain') {
        state $error = qq{Annoyingly, there's no "does not contain" }
                     . qq{query in LiquidPlanner, so you can't use "!" }
                     . qq{as a prefix.};

        $error{$error} = 1;
        next MATCHER;
      }

      if (! defined $op) {
        $error{ q{Something weird happened with your search.} } = 1;
        next MATCHER;
      }

      # You need to have some kind of actual search.
      $has_strong_check++ unless $op eq 'does_not_start_with';

      push @filters, [ 'name', $op, $value ];
    }
  }

  unless ($has_strong_check) {
    state $error = "This search is too broad.  Try adding search terms or "
                 . "more limiting conditions.  I'm sorry this advice is so "
                 . "vague, but the existing rules are silly and subject to "
                 . "change at any time.";

    $error{$error} = 1;
  }

  if (%error) {
    return Future->done(error => join q{  }, sort keys %error);
  }

  my %to_query = (
    in      => $q_in,
    flags   => \%qflag,
    filters => \@filters,
  );

  if ($flag{debug}) {
    return Future->done(
      reply => "I'm going to run this query: ```"
             . JSON::MaybeXS->new->pretty->canonical->encode(\%to_query)
             . "```"
    );
  }

  my $search_f = $lpc
    ->query_items(\%to_query)
    ->else(sub {
      Future->done(error => "Something went wrong when running that search.");
    });

  $search_f->then(sub ($data) {
    my %seen;
    my @tasks = grep {; ! $seen{$_->{id}}++ } @$data;

    if ($q_in) {
      # If you search for the contents of n, you will get n back also.
      @tasks = grep {; $_->{id} != $q_in } @tasks;
    }

    if ($flag{owner} && keys $flag{owner}->%*
        && defined $flag{done} && ! $flag{done}
    ) {
      @tasks = grep {;
        keys $flag{owner}->%*
        ==
        grep {; ! $_->{is_done} and $flag{owner}{ $_->{person_id} } }
          $_->{assignments}->@*;
      } @tasks;
    }

    unless (@tasks) {
      return Future->done(itemlist => {
        items => [],
        more  => 0,
        page  => $flag{page},
      });
    }

    my $more  = @tasks > $offset + 11;
    @tasks = splice @tasks, $offset, 10;

    return Future->done(reply => "That's past the last page of results.")
      unless @tasks;

    return Future->done(itemlist => {
      items => \@tasks,
      more  => $more ? 1 : 0,
      page  => $flag{page},
    });
  });
}

no Moose;
__PACKAGE__->meta->make_immutable;
