use v5.24;
use warnings;
package Synergy::Reactor::Zendesk;

use Moose;
with 'Synergy::Role::Reactor::EasyListening',
     'Synergy::Role::HasPreferences';

use Date::Parse qw(str2time);
use Future;
use Lingua::EN::Inflect qw(WORDLIST);
use Synergy::Logger '$Logger';
use Time::Duration qw(ago);
use Zendesk::Client;

use experimental qw(postderef signatures);
use namespace::clean;
use utf8;

has [qw( domain username api_token )] => (
  is => 'ro',
  required => 1,
);

# XXX config'able
has ticket_regex => (
  is => 'ro',
  lazy => 1,
  default => sub {
    my $prefix = 'PTN';
    return qr/(?:^|\W)(?:#|(?i)$prefix)\s*[_*]{0,2}([0-9]{7,})\b/i;
  },
);

# id => name-or-slackmoji
has brand_mapping => (
  is => 'ro',
  isa => 'HashRef',
  predicate => 'has_brand_mapping',
);

has zendesk_client => (
  is => 'ro',
  lazy => 1,
  default => sub ($self) {
    my $username = $self->username;
    $username .= '/token' unless $username =~ m{/token$};

    return Zendesk::Client->new({
      username => $username,
      domain   => $self->domain,
      token    => $self->api_token,
    });
  },
);

sub listener_specs ($self) {
  my $ticket_re = $self->ticket_regex;

  return (
    {
      name      => 'mention-ptn',
      method    => 'handle_ptn_mention',
      predicate => sub ($self, $e) {
        return 1 if $e->text =~ /$ticket_re/;
        return;
      },
    },
  );
}

sub handle_ptn_mention ($self, $event) {
  $event->mark_handled if $event->was_targeted;

  my $ticket_re = $self->ticket_regex;
  my @ids = $event->text =~ m/$ticket_re/g;
  my %ids = map {; $_ => 1 } @ids;
  @ids = sort keys %ids;

  my $replied = 0;

  $self->zendesk_client->ticket_api->get_many_f(\@ids)
    ->then(sub ($tickets) {
      my @got;
      for my $ticket (@$tickets) {
        push @got, $ticket->id;
        $self->_output_ticket($event, $ticket);
      }

      return unless $event->was_targeted;
      return if @got == @ids;

      # Uh oh, we didn't get everything we wanted; if we were targeted, let's
      # tell them.
      my %have = map {; $_ => 1 } @got;
      my @missing = grep {; ! $have{$_} } @ids;

      my $which = WORDLIST(@ids, { conj => "or" });
      $event->reply("Sorry, I couldn't find any tickets for $which.");
    })
    ->retain;

  return;
}

sub _output_ticket ($self, $event, $ticket) {
  my $id = $ticket->id;
  my $status = $ticket->status;
  my $subject = $ticket->subject;
  my $created = str2time($ticket->created_at);
  my $updated = str2time($ticket->updated_at);

  my $text = "#$id: $subject (status: $status)";

  my $link = sprintf("<https://%s/agent/tickets/%s|#%s>",
    $self->domain,
    $id,
    $id,
  );

  my $assignee = $ticket->assignee;
  my @assignee = $assignee ?  [ "Assigned to" => $assignee->name ] : ();

  my @brand;
  if ( $self->has_brand_mapping && $ticket->brand_id) {
    my $brand_text = $self->brand_mapping->{$ticket->brand_id};
    @brand = [ Product => $brand_text ] if $brand_text;
  }

  # slack block syntax is silly.
  my @fields = map {;
    +{
       type => 'mrkdwn',
       text => "*$_->[0]:* $_->[1]",
     }
  } (
    @brand,
    [ "Status"  => ucfirst($status) ],
    [ "Opened"  => ago(time - $created) ],
    [ "Updated" => ago(time - $updated) ],
    @assignee,
  );

  my $blocks = [
    {
      type => "section",
      text => {
        type => "mrkdwn",
        text => "\N{MEMO} $link - $subject",
      }
    },
    {
      type => "section",
      fields => \@fields,
    },
  ];

  $event->reply($text, {
    slack => {
      blocks => $blocks,
      text => $text,
    },
  });
}

1;
