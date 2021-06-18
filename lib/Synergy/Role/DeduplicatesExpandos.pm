use v5.24.0;
use warnings;
package Synergy::Role::DeduplicatesExpandos;

use MooseX::Role::Parameterized;

use Scalar::Util qw(blessed);
use Synergy::Logger '$Logger';
use Try::Tiny;
use utf8;

use experimental qw(signatures);
use namespace::clean;

parameter expandos => (
  isa => 'ArrayRef[Str]',
  required => 1,
);

role {
  my $p = shift;

  requires 'start';

  for my $thing ($p->expandos->@*) {
    my $key_generator = "_expansion_key_for_${thing}";
    my $attr_name = "_recent_${thing}_expansions";

    has $attr_name => (
      is => 'ro',
      isa => 'HashRef',
      traits => ['Hash'],
      lazy => 1,
      default => sub { {} },
      handles => {
        "remove_${thing}_expansion"      => 'delete',
        "recent_${thing}_expansions"     => 'keys',
        "${thing}_expansion_for"         => 'get',
      },
    );

    method $key_generator => sub ($self, $event, $id) {
      # Not using $event->source_identifier here because we don't care _who_
      # triggered the expansion. -- michael, 2019-02-05
      return join(';',
        $id,
        $event->from_channel->name,
        $event->conversation_address
      );
    };

    method "note_${thing}_expansion" => sub ($self, $event, $id) {
      my $key = $self->$key_generator($event, $id);
      $self->$attr_name->{$key} = time;
    };

    method "has_expanded_${thing}_recently" => sub ($self, $event, $id) {
      my $key = $self->$key_generator($event, $id);
      return exists $self->$attr_name->{$key};
    };
  }

  # We'll only keep records of expansions for 5m or so.
  has expansion_record_reaper => (
    is => 'ro',
    lazy => 1,
    default => sub ($self) {
      return IO::Async::Timer::Periodic->new(
        interval => 30,
        on_tick  => sub {
          my $then = time - (60 * 5);

          for my $thing ($p->expandos->@*) {
            my $recent_method = "recent_${thing}_expansions";
            my $get_method    = "${thing}_expansion_for";
            my $delete_method = "remove_${thing}_expansion";

            for my $key ($self->$recent_method) {
              my $ts = $self->$get_method($key);
              $self->$delete_method($key) if $ts < $then;
            }
          }
        },
      );
    }
  );

  around start => sub ($orig, $self, @rest) {
    $self->$orig(@rest);
    $self->hub->loop->add($self->expansion_record_reaper->start);
  };
};

1;
