use v5.36.0;
package Synergy::Reactor::Rototron;

use utf8;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::CommandPost';

use namespace::clean;

use Future::AsyncAwait;
use IO::Async::Timer::Periodic;
use JMAP::Tester;
use JSON::MaybeXS;
use Lingua::EN::Inflect qw(NUMWORDS PL_N);
use List::Util qw(uniq);
use Synergy::CommandPost;
use Synergy::Logger '$Logger';
use Synergy::Rototron;
use Synergy::Util qw(expand_date_range parse_date_for_user reformat_help);
use Try::Tiny;

has roto_config_path => (
  is => 'ro',
  required => 1,
);

has rototron => (
  is    => 'ro',
  lazy  => 1,
  handles => [ qw(availability_checker jmap_client) ],
  default => sub ($self, @) {
    return Synergy::Rototron->new({
      user_directory => $self->hub->user_directory,
      config_path    => $self->roto_config_path,
    });
  },
);

after register_with_hub => sub ($self, @) {
  $self->rototron; # crash early, crash often -- rjbs, 2019-01-31
};

my $YMD_RE = qr{ [0-9]{4} - [0-9]{2} - [0-9]{2} }x;

responder 'assign-rotor' => {
  exclusive => 1,
  targeted  => 1,
  skip_help => 1, # documented under "rotors"
  matcher   => sub ($self, $text, $event) {
    if ($text =~ /^assign rotor (\S+) to (\S+) on ($YMD_RE)\z/) {
      return [ $1, $2, $3, $3 ];
    }

    if ($text =~ /^assign rotor (\S+) to (\S+) from ($YMD_RE) to ($YMD_RE)\z/) {
      return [ $1, $2, $3, $4 ];
    }

    return;
  },
} => async sub ($self, $event, $rotor_name, $username, $from_ymd, $to_ymd) {
  $event->mark_handled;

  unless (grep {; $_->name eq $rotor_name } $self->rototron->rotors) {
    return await $event->error_reply("I don't know a rotor with that name.");
  }

  my $from = parse_date_for_user($from_ymd, $event->from_user);
  my $to   = parse_date_for_user($to_ymd,   $event->from_user);

  unless ($from && $to) {
    return await $event->error_reply(
      "I had problems understanding the dates in your *assign rotor* command.",
    );
  }

  my @dates = expand_date_range($from, $to);

  unless (@dates) { return await $event->error_reply("That range didn't make sense."); }
  if (@dates > 28) { return await $event->error_reply("That range is too large."); }

  my $assign_to;
  if ($username ne '*') {
    my $target = $self->resolve_name($username, $event->from_user);

    unless ($target) {
      return await $event->error_reply("I don't know who you wanted to assign the rotor to.");
    }

    $assign_to = $target->username;
  }

  $self->availability_checker->update_manual_assignments({
    $rotor_name => { map {; $_->ymd => $assign_to } @dates },
  });

  await $event->reply(
    sprintf "I updated the assignments on that rotor for %s %s.",
      NUMWORDS(0+@dates),
      PL_N('day', 0+@dates),
  );

  $self->_replan_range($dates[0], $dates[-1]);

  return;
};

responder 'set-availability' => {
  exclusive => 1,
  targeted  => 1,
  skip_help => 1, # documented under "rotors"
  matcher   => sub ($self, $text, $event) {
    return [] if $text =~ /^(?:(\S+)\s+is\s+)?(un)?available\b/in;
    return;
  },
} => async sub ($self, $event) {
  $event->mark_handled;

  my ($from, $to);

  my $target = $event->from_user;
  if ($event->text =~ /^(\S+)\s+is\s+/) {
    $target = $self->resolve_name($1, $event->from_user);
    unless ($target) {
      return await $event->error_reply("Sorry, I don't know who you mean.");
    }
  }

  my $text = $event->text;
  my $adj  = $text =~ /unavailable/i ? 'unavailable' : 'available';

  if ($text =~ m{\bon\s+($YMD_RE)\z}) {
    $from = parse_date_for_user("$1", $event->from_user);
    $to   = $from->clone;
  } elsif ($text =~ m{\bfrom\s+($YMD_RE)\s+to\s+($YMD_RE)\z}) {
    my ($d1, $d2) = ($1, $2);
    $from = parse_date_for_user($d1, $event->from_user);
    $to   = parse_date_for_user($d2, $event->from_user);
  } else {
    return await $event->error_reply(
      "It's: `$adj on YYYY-MM-DD` "
      . "or `$adj from YYYY-MM-DD to YYYY-MM-DD`"
    );
  }

  $from->truncate(to => 'day');
  $to->truncate(to => 'day');

  my @dates = expand_date_range($from, $to);

  unless (@dates) { return await $event->error_reply("That range didn't make sense."); }
  if (@dates > 28) { return await $event->error_reply("That range is too large."); }

  my $method = qq{set_user_$adj\_on};
  for my $date (@dates) {
    my $username = $target->username;
    $self->availability_checker->$method(
      $target->username,
      $date,
    );
  }

  await $event->reply(
    sprintf "I marked %s %s on %s %s.",
      ($target->username eq $event->from_user->username
        ? 'you'
        : $target->them),
      $adj,
      NUMWORDS(0+@dates),
      PL_N('day', 0+@dates),
  );

  $self->_replan_range($dates[0], $dates[-1]);

  return;
};

responder 'replan-rotors' => {
  exclusive => 1,
  targeted  => 1,
  skip_help => 1,
  matcher   => sub ($self, $text, $event) {
    return [] if $text =~ /\Areplan rotors\z/i;
    return;
  },
} => async sub ($self, $event) {
  $event->mark_handled;
  $self->_plan_the_future;
  return await $event->reply("Okay, I've replanned upcoming duty rotations!");
};

sub _replan_range ($self, $from_dt, $to_dt) {
  my $plan = $self->rototron->compute_rotor_update($from_dt, $to_dt);

  $Logger->log([ 'replan plan %s - %s: %s', $from_dt, $to_dt, $plan ]);
  return unless $plan;

  my $res = $self->rototron->jmap_client->request({
    methodCalls => [
      [ 'CalendarEvent/set' => $plan, ],
    ],
  });

  eval {
    $res->assert_successful_set("CalendarEvent/set");
  };

  if ($@) {
    $Logger->log(["Failed to CalendarEvent/set. Res: %s", $res->response_payload ]);
  }

  $self->rototron->_duty_cache->%* = (); # should build this into Rototron

  return;
}

# Obviously this is a bit overly specific to my work install.
# -- rjbs, 2019-03-26
#
# We should cache this, but I'd rather be a little slow and correct, for now.
# -- rjbs, 2019-03-26
sub current_triage_officers ($self) {
  my @users = (
    $self->current_officers_for_duty('triage_us'),
    $self->current_officers_for_duty('triage_au'),
  );

  return @users;
}

sub current_officers_for_duty ($self, $duty_name) {
  my $rototron = $self->rototron;

  my $now  = DateTime->now(time_zone => 'UTC');

  my $items = $self->rototron->_get_duty_items_between($now, $now);

  my @users = grep {; defined && $_->is_working_now }
              map  {; $self->_user_from_duty($_) }
              grep {; $_->{keywords}{"rotor:$duty_name"} }
              @$items;

  return uniq sort @users;
}

sub _user_from_duty ($self, $duty) {
  my (@user_keywords) = grep {; /^username:/ } keys $duty->{keywords}->%*;

  if (@user_keywords != 1) {
    $Logger->log([
      "didn't find exactly one username keyword on duty event: %s",
      $duty,
    ]);

    return;
  }

  my $username = $user_keywords[0] =~ s/^username://r;

  return $self->hub->user_directory->user_named($username);
}

command rotors => {
  help => reformat_help(<<~'EOH'),
    The *rotors* command lists all duty rotations managed by Synergy.  A duty
    rotation represents a job that gets done by different people at different
    times, based on some schedule.  To see who's on duty for various rotations, now
    or at some future time, use the *duty* command.

    To tell Synergy that you're not available (or are available) on a given day,
    you can say either:

    • `{available,unavailable}` on `YYYY-MM-DD`
    • `{available,unavailable}` from `YYYY-MM-DD` to `YYYY-MM-DD`

    If you're an admin, you can set other user's availability:

    • `USER` is `{available,unavailable}` on `YYYY-MM-DD`
    • `USER` is `{available,unavailable}` from `YYYY-MM-DD` to `YYYY-MM-DD`

    To manually assign someone to a duty rotation, you can say either:

    • assign rotor `ROTOR` to `USER` on `YYYY-MM-DD`
    • assign rotor `ROTOR` to `USER` from `YYYY-MM-DD` to `YYYY-MM-DD`
    EOH
} => async sub ($self, $event, $) {
  my @lines;
  for my $rotor (sort {; fc $a->name cmp fc $b->name } $self->rototron->rotors) {
    push @lines, sprintf '• %s — %s', $rotor->name, $rotor->description;
  }

  my $text = join qq{\n}, @lines;
  return await $event->reply(
    "Known duty rotations:\n$text",
    { slack => "*Known duty rotations:*\n$text" }
  );
};

command duty => {
  help => reformat_help(<<~'EOH'),
    The *duty* command tells you who is on duty for various duty rotations.  For
    more information on duty rotations, see *help rotors*.
    EOH
} => async sub ($self, $event, $when) {
  my $when_dt;
  my $is_now;

  if ($when) {
    $when_dt = eval { parse_date_for_user($when, $event->from_user) };
    return await $event->error_reply("I didn't understand the day you asked about")
      unless $when_dt;
  } else {
    $is_now = 1;
    my $tz = $event->from_user ? $event->from_user->time_zone : 'UTC';
    $when_dt = DateTime->now(time_zone => $tz);
  }

  my @lines;
  for my $rotor ($self->rototron->rotors) {
    my $dt = $when_dt;
    if ($rotor->time_zone && $is_now) {
      $dt = $dt->clone;
      $dt->set_time_zone($rotor->time_zone);
    }

    for my $duty (@{ $self->rototron->duties_on($dt) || [] }) {
      next unless $duty->{keywords}{ $rotor->keyword };

      my $user = $self->_user_from_duty($duty);
      push @lines, $duty->{title}
                 . ', ' . $dt->ymd
                 . (($is_now && $user && $user->is_working_now)
                    ? q{ *(on the clock)*}
                    : q{});
    }
  }

  unless (@lines) {
    my $str = $is_now ? q{today} : q{that time};
    return await $event->reply("Like booze in an airport, $str is duty free.");
  }

  my $reply = "*Duty roster for " . $when_dt->ymd . ":*\n"
            . join qq{\n}, sort @lines;

  return await $event->reply($reply);
};

async sub start ($self) {
  my $timer = IO::Async::Timer::Periodic->new(
    notifier_name => 'rototron-planner',
    interval => 15 * 60,
    on_tick  => sub {
      try {
        $self->_plan_the_future;
      } catch {
        my $err = $_;
        $Logger->log([ "rototron: failed to _plan_the_future: %s", $err ]);
      };
    },
  );

  $self->hub->loop->add($timer);

  $timer->start;

  return;
}

sub _plan_the_future ($self) {
  my $start = DateTime->today;
  my $days  = 60 + 6 - $start->day_of_week % 7;
  my $end   = $start->clone->add(days => $days);
  my @dates = expand_date_range($start, $end);

  $self->_replan_range($dates[0], $dates[-1]);
}

1;
