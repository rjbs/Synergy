use v5.24.0;
use warnings;
package Synergy::Reactor::DiscordTester;

use Moose;
use DateTime;
with 'Synergy::Role::Reactor::EasyListening';

use experimental qw(signatures lexical_subs);
use namespace::clean;
use List::Util qw(first uniq);
use Synergy::Util qw(parse_date_for_user);
use Time::Duration::Parse;

use utf8;

sub listener_specs {
  return (
    {
      name      => 'discord_reconnect',
      method    => 'handle_discord_reconnect',
      exclusive => 1,
      predicate => sub ($self, $e) {
        return unless $e->was_targeted;
        return unless $e->text eq 'initiate discord reconnection';
      },
    },
  );
}

sub handle_discord_reconnect ($self, $event) {
  $event->mark_handled;

  $event->reply("Initiating Discord reconnection...");

  $self->hub->channel_named('discord')->discord->handle_reconnect({});
}

1;
