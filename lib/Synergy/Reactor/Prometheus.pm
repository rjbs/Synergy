use v5.24.0;
use warnings;
package Synergy::Reactor::Prometheus;

use Moose;
with 'Synergy::Role::Reactor::EasyListening';
with 'Synergy::Role::HTTPEndpoint';

use experimental qw(signatures);
use namespace::clean;

use Prometheus::Tiny 0.002;

has '+http_path' => (
  default => '/metrics',
);

has _prom_client => (
  is => 'ro',
  default => sub { Prometheus::Tiny->new },
);

sub listener_specs {
  return {
    name      => 'prometheus',
    method    => 'count_event',
    predicate => sub { 1 },
  };
}

sub start ($self) {
  my $prom = $self->_prom_client;

  $prom->declare('synergy_events_received_total',
    help => 'Number of events received by reactors',
    type => 'counter',
  );
}

sub http_app ($self, $env) {
  state $app = $self->_prom_client->psgi;
  $app->($env);
}

sub count_event ($self, $event) {
  my $from = $event->from_user
           ? $event->from_user->username
           : $event->from_address;

  $self->_prom_client->inc(synergy_events_received_total => {
    channel   => $event->from_channel->name,
    user      => $from,
    in        => $event->from_channel->describe_conversation($event),
    targeted  => $event->was_targeted ? 1 : 0,
  });
}

1;
