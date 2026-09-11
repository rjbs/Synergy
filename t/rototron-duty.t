#!perl
use v5.36.0;

use Test::More;

use Synergy::Rototron;

# Synergy::Rototron itself wants a config file, a JMAP endpoint, and the
# availability database, but a Duty is just a view onto one calendar event, so
# we can hand it literal events and check what it makes of them.
# -- claude, 2026-09-11
sub duty_ok ($desc, $event, $expect) {
  my $duty = Synergy::Rototron::Duty->new({ event => $event });

  subtest $desc => sub {
    is($duty->title,         $expect->{title},         'title');
    is($duty->rotor_keyword, $expect->{rotor_keyword}, 'rotor keyword');
    is($duty->username,      $expect->{username},      'username');
    is($duty->rotor,         undef,                    'no rotor was set');
  };
}

duty_ok(
  'a planned duty with an assignee',
  {
    title    => 'Engineering Triage - Ricardo',
    keywords => { 'rotor:triage_us' => 1, 'username:rjbs' => 1 },
  },
  {
    title         => 'Engineering Triage - Ricardo',
    rotor_keyword => 'rotor:triage_us',
    username      => 'rjbs',
  },
);

duty_ok(
  'a planned duty that nobody was available for',
  {
    title    => 'Engineering Triage - (nobody)',
    keywords => { 'rotor:triage_us' => 1 },
  },
  {
    title         => 'Engineering Triage - (nobody)',
    rotor_keyword => 'rotor:triage_us',
    username      => undef,
  },
);

duty_ok(
  'an event put on the calendar by hand, with no keywords at all',
  { title => 'All-hands offsite' },
  { title => 'All-hands offsite', rotor_keyword => undef, username => undef },
);

duty_ok(
  'an event put on the calendar by hand, with empty keywords',
  { title => 'All-hands offsite', keywords => {} },
  { title => 'All-hands offsite', rotor_keyword => undef, username => undef },
);

duty_ok(
  'an event claiming two rotors, which we refuse to guess between',
  {
    title    => 'Engineering Triage - Ricardo',
    keywords => {
      'rotor:triage_us' => 1,
      'rotor:triage_au' => 1,
      'username:rjbs'   => 1,
    },
  },
  {
    title         => 'Engineering Triage - Ricardo',
    rotor_keyword => undef,
    username      => 'rjbs',
  },
);

duty_ok(
  'an event claiming two assignees',
  {
    title    => 'Engineering Triage - Ricardo',
    keywords => {
      'rotor:triage_us' => 1,
      'username:rjbs'   => 1,
      'username:alh'    => 1,
    },
  },
  {
    title         => 'Engineering Triage - Ricardo',
    rotor_keyword => 'rotor:triage_us',
    username      => undef,
  },
);

done_testing;
