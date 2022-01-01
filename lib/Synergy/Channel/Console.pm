use v5.24.0;
use warnings;
package Synergy::Channel::Console;

use utf8;

package Synergy::Channel::Console::Compartment {
  use v5.24.0;
  use warnings;
  use experimental qw(signatures);

  sub _evaluate ($S, $code) {
    my $result = eval $code;
    if ($@) {
      return (undef, $@);
    }

    return ($result, undef);
  }
}

use Moose;
use experimental qw(signatures);
use JSON::MaybeXS;

use Synergy::External::Slack;
use Synergy::Event;
use Synergy::Logger '$Logger';

use namespace::autoclean;
use List::Util qw(max);

use Term::ANSIColor qw(colored);

with 'Synergy::Role::Channel';

my %Theme = (
             # decoration   text
  cyan    => [         75,   117 ],
  green   => [         10,    84 ],
  purple  => [        140,    13 ],
);

has ignore_blank_lines => (
  is => 'rw',
  isa => 'Bool',
  default => 1,
);

has theme => (
  is  => 'ro',
  isa => 'Str',
);

has from_address => (
  is  => 'rw',
  isa => 'Str',
  default => 'sysop',
);

has public_by_default => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

has public_conversation_address => (
  is  => 'rw',
  isa => 'Str',
  default => '#public',
);

has target_prefix => (
  is  => 'rw',
  isa => 'Str',
  default => '@',
);

has send_only => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

has stream => (
  reader    => '_stream',
  init_arg  => undef,
  lazy      => 1,
  builder   => '_build_stream',
);

has allow_eval => (
  is  => 'ro',
  isa => 'Bool',
  default => 0,
);

has message_format => (
  is => 'rw',
  default => 'chonky',
);

sub _build_stream {
  my ($channel) = @_;
  Scalar::Util::weaken($channel);

  open(my $cloned_stdout, ">&STDOUT") or die "Can't dup STDOUT: $!";
  open(my $cloned_stdin , ">&STDIN")  or die "Can't dup STDIN: $!";

  binmode $cloned_stdout, ':pop'; # remove utf8
  binmode $cloned_stdin,  ':pop'; # remove utf8

  my %arg = (
    write_handle => $cloned_stdout,
    encoding     => 'UTF-8',
    # autoflush    => 1,
  );

  unless($channel->send_only) {
    $arg{read_handle} = $cloned_stdin,
    $arg{on_read}     = sub {
      my ( $self, $buffref, $eof ) = @_;

       while( $$buffref =~ s/^(.*\n)// ) {
          my $text = $1;
          chomp $text;

          my $event = $channel->_event_from_text($text);
          next unless $event;

          $channel->hub->handle_event($event);
       }

       return 0;
    };
  }

  return IO::Async::Stream->new(%arg);
}

sub _display_message ($self, $text, $closed = 1, $title = undef) {
  state $B_TL  = q{╔};
  state $B_BL  = q{╚};
  state $B_TR  = q{╗};
  state $B_BR  = q{╝};
  state $B_ver = q{║};
  state $B_hor = q{═};

  state $B_boxleft  = q{╣};
  state $B_boxright = q{╠};

  my $theme = $self->theme ? $Theme{ $self->theme } : undef;

  my $text_C = $theme ? Term::ANSIColor::color("ansi$theme->[1]") : q{};
  my $line_C = $theme ? Term::ANSIColor::color("ansi$theme->[0]") : q{};
  my $null_C = $theme ? Term::ANSIColor::color('reset')           : q{};

  my $header = "$line_C$B_TL" . ($B_hor x 77) . "$B_TR$null_C\n";
  my $footer = "$line_C$B_BL" . ($B_hor x 77) . "$B_BR$null_C\n";

  if (length $title) {
    my $width = length $title;

    $header = "$line_C$B_TL"
            . ($B_hor x 5)
            . "$B_boxleft $title $B_boxright"
            . ($B_hor x (72 - $width - 4))
            . "$B_TR$null_C\n";
  }

  my $new_text = q{};
  for my $line (split /\n/, $text) {
    $new_text .= "$line_C$B_ver $text_C";

    if ($closed && length $line <= 76) {
      $new_text .= sprintf '%-76s', $line;
      $new_text .= "$line_C$B_ver" if length $line <= 76;
    } else {
      $new_text .= $line;
    }

    $new_text .= "$null_C\n";
  }

  $self->_stream->write($header);
  $self->_stream->write($new_text);
  $self->_stream->write($footer);

  return
}

my %HELP;
$HELP{''} = <<'EOH';
You're using the Console channel, which is generally used for testing or
diagnostics.  You can just type a message and hit enter.  Some funky
options exist to aid testing.

Help topics:

  console - commands for inspecting and configuring your Console channel
  diag    - commands for inspecting the Synergy configuration
  events  - how to affect the events generated by your messages
  format  - commands to affect console output format

You can use "/help TOPIC" to read more.

To send a message that begins with a literal "/", start with "//" instead.
EOH

$HELP{console} = <<'EOH';
There are commands for inspecting and tweaking your Console channel.

  /console  - print Console channel configuration
  /format   - configure Console channel output (see "/help format")

  /set VAR VALUE  - change the default value for one of the following

    from-address    - the default from_address on new events
    public          - 0 or 1; whether messages should be public by default
    public-address  - the default conversation address for public events
    target-prefix   - token that, at start of text, is stripped, making the
                      event targeted

EOH

$HELP{diag} = <<'EOH';
Some commands exist to let you learn about the running Synergy.  These will
probably change over time.

  /channels - print the registered channels
  /reactors - print the registered reactors
  /users    - print unknown users

  /config   - print a summary of top-level Synergy configuration
  /http     - print a summary of registered HTTP endpoints

  /console  - print configuration of this Console channel
EOH

$HELP{events} = <<'EOH';
You can begin your message with a string inside braces.  The string is made
up of instructions separated by spaces.  They can be:

  f:STRING      -- make this event have a different from address
  d:STRING      -- make this event have a different default reply address
  p[ublic]:BOOL -- set whether is_public
  t:BOOL        -- set event's was_targeted

So to make the current message appear to be public and to come from "jem",
enter:

  {p:1 f:jem} Hi!

The braced string and any following spaces are stripped.
EOH

$HELP{format} = <<'EOH';
You can toggle the format of messages sent to Console channels with the
following values:

  compact - print the channel name and target address, then the text
  chonky  - print a nice box with the text wrapped into it

Use these commands:

  /format WHICH         - set the output format for this channel
  /format WHICH CHANNEL - set the output format for another Console

You can supply "*" as the channel name to set the format for all Console
channels.
EOH

sub _console_cmd_help ($self, $arg) {
  my $for = $HELP{ length $arg ? lc $arg : q{} };

  unless ($for) {
    $self->_display_message("No help on that topic!");
    return;
  }

  $self->_display_message($for);
  return;
}

sub _console_cmd_config ($self, $arg) {
  my $output = "Synergy Configuration\n\n";

  my $url = sprintf 'http://localhost:%i/', $self->hub->server_port;

  my $width = 8;
  $output .= sprintf "  %-*s - %s\n", $width, 'name', $self->hub->name;
  $output .= sprintf "  %-*s - %s\n", $width, 'http', $url;
  $output .= sprintf "  %-*s - %s\n", $width, 'db',
    $self->hub->env->state_dbfile;

  my $userfile = $self->hub->env->has_user_directory_file
               ? $self->hub->env->user_directory_file
               : "(none)";

  $output .= sprintf "  %-*s - %s\n", $width, 'userfile', $userfile;

  $output .= "\nSee also /channels and /reactors and /users";

  $self->_display_message($output);
}

sub _console_cmd_http ($self, $arg) {
  my $output = "HTTP Endpoints\n\n";

  my @kv = $self->hub->server->_registrations;
  my $url = sprintf 'http://localhost:%i/', $self->hub->server_port;

  my $width = max map {; length $_->[0] } @kv;

  $output .= sprintf "  %-*s routes to %s\n", $width, $_->[0], $_->[1]
    for sort { $a->[0] cmp $b->[0] } @kv;

  $self->_display_message($output);
}

sub _console_cmd_channels ($self, $arg) {
  my @channels = sort {; $a->name cmp $b->name } $self->hub->channels;
  my $width    = max map {; length $_->name } @channels;

  my $output = "Registered Channels\n\n";
  $output .= sprintf "  %-*s - %s\n", $width, $_->name, ref($_) for @channels;

  $self->_display_message($output);
}

sub _console_cmd_reactors ($self, $arg) {
  my @reactors = sort {; $a->name cmp $b->name } $self->hub->reactors;
  my $width    = max map {; length $_->name } @reactors;

  my $output = "Registered Reactors\n\n";
  $output .= sprintf "  %-*s - %s\n", $width, $_->name, ref($_) for @reactors;

  $self->_display_message($output);
}

sub _console_cmd_users ($self, $arg) {
  my @users = sort {; $a->username cmp $b->username }
              $self->hub->user_directory->all_users;

  my $width = max map {; length $_->username } @users;

  my $output = "Known Users\n\n";
  for my $user (@users) {
    my @status;
    push @status, 'deleted' if $user->is_deleted;
    push @status, 'master'  if $user->is_master;
    push @status, 'virtual' if $user->is_virtual;

    my %ident = map {; @$_ } $user->identity_pairs;

    push @status, map {; "$_!$ident{$_}" } sort keys %ident;

    $output .= sprintf "  %-*s - %s\n",
      $width, $user->username,
      join q{; }, @status;
  }

  $self->_display_message($output);
}

sub _console_cmd_console ($self, $arg) {
  my $output = qq{Channel configuration:\n\n};

  my $width = 15;
  $output .= sprintf "%-*s: %s\n", $width, 'name', $self->name;
  $output .= sprintf "%-*s: %s\n", $width, 'theme', $self->theme // '(none)';
  $output .= sprintf "%-*s: %s\n", $width, 'default from', $self->from_address;

  $output .= sprintf "%-*s: %s\n",
    $width, 'default context',
    $self->public_by_default ? 'public' : 'private';

  $output .= sprintf "%-*s: %s\n",
    $width, 'public address',
    $self->public_conversation_address;

  $output .= sprintf "%-*s: %s\n",
    $width, 'target prefix',
    $self->target_prefix;

  $self->_display_message($output);
}

sub _console_cmd_format ($self, $arg) {
  my ($format, $channel) = split /\s+/, $arg, 2;

  unless ($format eq 'chonky' or $format eq 'compact') {
    $self->_display_notice("Not a valid message format.");
    return;
  }

  $channel //= $self->name;

  my @channels = grep {; $channel eq '*' || $_->name eq $channel }
                 grep {; $_->isa('Synergy::Channel::Console') }
                 $self->hub->channels;

  unless (@channels) {
    $self->_display_notice("Couldn't find target Console reactor.");
    return;
  }

  for (@channels) {
    $_->message_format($format);
    $_->_display_notice("Message format set to $format");
  }

  return;
}

sub _console_cmd_eval ($self, $arg) {
  unless ($self->allow_eval) {
    $_->_display_notice("/eval is not enabled");
    return;
  }

  my ($result, $error) = Synergy::Channel::Console::Compartment::_evaluate(
    $self->hub,
    $arg,
  );

  require Data::Dumper::Concise;

  if ($error) {
    my $display = ref $error      ? Data::Dumper::Concise::Dumper($error)
                : defined $error  ? $error
                :                   '(undef)';

    $self->_display_message($display, 0, 'ERROR');
    return;
  }

  my $display = ref $result     ? Data::Dumper::Concise::Dumper($result)
              : defined $result ? $result
              :                   '(undef)';

  $self->_display_message($display, 0, 'RESULT');
  return;
}

# from-address    - the default from_address on new events
# public          - 0 or 1; whether messages should be public by default
# public-address  - the default conversation address for public events
# target-prefix   - token that, at start of text, is stripped, making the
#                   event targeted
sub _console_cmd_set ($self, $rest) {
  unless (length $rest) {
    $self->_display_message("Usage: /set VAR VALUE");
    return;
  }

  my ($var, $value) = split /\s+/, $rest, 2;

  unless (length $var && length $value) {
    $self->_display_message("Usage: /set VAR VALUE");
    return;
  }

  my %var_handler = (
    'from-address'    => sub ($v) { $self->from_address($v) },
    'public'          => sub ($v) { $self->public_by_default($v ? 1 : 0); },
    'public-address'  => sub ($v) { $self->public_conversation_address($v) },
    'target-prefix'   => sub ($v) { $self->target_prefix($v) },
  );

  my $handler = $var_handler{$var};

  unless ($handler) {
    $self->_display_message("Unknown Console channel variable: $var");
    return;
  }

  eval {; $handler->($value) };

  if ($@) {
    $self->_display_message("Error occurred setting $var");
    return;
  }

  $self->_display_message("Updated $var");
  return;
}

sub _event_from_text ($self, $text) {
  # Remove any leading "/".  If there's a leading slash, we're just sending a
  # normal message with a leading slash.  (The now-removed slash was here to
  # escape this one.)  Otherwise, we're looking for a Console channel slash
  # command.
  if ($text =~ s{\A/}{} && $text !~ m{\A/}) {
    my ($cmd, $rest) = split /\s+/, $text, 2;

    if (my $code =$self->can("_console_cmd_$cmd")) {
      $self->$code($rest);
      return undef;
    }

    $self->_display_message("No such console command: /$cmd");
    return undef;
  }

  if (not length $text && $self->ignore_blank_lines) {
    return undef;
  }

  my $orig_text = $text;
  my $meta = ($text =~ s/\A \{ ([^}]+?) \} \s+//x) ? $1 : undef;

  my $is_public     = $self->public_by_default;

  my $target_prefix = $self->target_prefix;
  my $was_targeted  = $text =~ s/\A\Q$target_prefix\E\s+// || ! $is_public;

  my %arg = (
    type => 'message',
    text => $text,
    was_targeted  => $was_targeted,
    is_public     => $self->public_by_default,
    from_channel  => $self,
    from_address  => $self->from_address,
    transport_data => { text => $orig_text },
  );

  if (length $meta) {
    # Crazy format for producing custom events by hand! -- rjbs, 2018-03-16
    #
    # If no colon/value, booleans default to becoming true.
    #
    # f:STRING      -- change the from address
    # d:STRING      -- change the default reply address
    # p[ublic]:BOOL -- set whether is public
    # t:BOOL        -- set whether targeted
    my @flags = split /\s+/, $meta;
    FLAG: for my $flag (@flags) {
      my ($k, $v) = split /:/, $flag;

      if ($k eq 'f') {
        unless (defined $v) {
          $Logger->log([
            "console event on %s: ignoring valueless 'f' flag",
            $self->name,
          ]);
          next FLAG;
        }
        $arg{from_address} = $v;
        next FLAG;
      }

      if ($k eq 'd') {
        unless (defined $v) {
          $Logger->log([
            "console event on %s: ignoring valueless 'd' flag",
            $self->name,
          ]);
          next FLAG;
        }
        $arg{transport_data}{default_reply_address} = $v;
        next FLAG;
      }

      if ($k eq 't') {
        $v //= 1;
        $arg{was_targeted} = $v;
        next FLAG;
      }

      if ($k eq substr("public", 0, length $k)) {
        $v //= 1;
        $arg{is_public} = $v;
        next FLAG;
      }
    }
  }

  $arg{conversation_address}
    =   $arg{transport_data}{default_reply_address}
    //= $arg{is_public}
      ? $self->public_conversation_address
      : $arg{from_address};

  my $user = $self->hub->user_directory->user_by_channel_and_address(
    $self,
    $arg{from_address},
  );

  $arg{from_user} = $user if $user;

  return Synergy::Event->new(\%arg);
}

sub _display_notice ($self, $text) {
  state $width = max map {; length $_->name }
                 grep {; $_->does('Synergy::Role::Channel') }
                 $self->hub->channels;

  my $name = $self->name;

  my $message;

  if ($self->theme) {
    my @T = $Theme{ $self->theme }->@*;
    $message = colored([ "ansi$T[0]" ], "⬮⬮ ")
             . colored([ "ansi$T[1]" ], sprintf '%-*s', $width, $name)
             . colored([ "ansi$T[0]" ], " ⬮⬮ ")
             . colored([ "ansi$T[1]" ], $text)
             . "\n";
  } else {
    $message = "⬮⬮ $name ⬮⬮ $text\n";
  }

  $self->_stream->write($message);
  return;
}

sub start ($self) {
  die "bogus theme" if $self->theme && ! $Theme{$self->theme};
  $self->hub->loop->add($self->_stream);

  my $boot_message = "Console channel online";

  $boot_message .= "; type /help for help" unless $self->send_only;

  $self->_display_notice($boot_message);

  return;
}

sub send_message_to_user ($self, $user, $text, $alts = {}) {
  $self->send_message($user->username, $text, $alts);
}

sub _format_message_compact ($self, $name, $address, $text) {
  my $theme = $self->theme;

  return "❱❱ $name!$address ❱❱ $text\n" unless $theme;

  my @T = $Theme{ $self->theme }->@*;
  return colored([ "ansi$T[0]" ], "❱❱ ")
       . colored([ "ansi$T[1]" ], $name)
       . colored([ "ansi$T[0]" ], '!')
       . colored([ "ansi$T[1]" ], $address)
       . colored([ "ansi$T[0]" ], " ❱❱ ")
       . colored([ "ansi$T[1]" ], $text)
       . "\n";
}

sub _format_message_chonky ($self, $name, $address, $text) {
  state $B_TL  = q{╭};
  state $B_BL  = q{╰};
  state $B_TR  = q{╮};
  state $B_BR  = q{╯};
  state $B_ver = q{│};
  state $B_hor = q{─};

  state $B_boxleft  = q{┤};
  state $B_boxright = q{├};

  my $theme = $self->theme ? $Theme{ $self->theme } : undef;

  my $text_C = $theme ? Term::ANSIColor::color("ansi$theme->[1]") : q{};
  my $line_C = $theme ? Term::ANSIColor::color("ansi$theme->[0]") : q{};
  my $null_C = $theme ? Term::ANSIColor::color('reset')           : q{};

  my $dest_width = length "$name/$address";

  my $dest = "$text_C$name$line_C!$text_C$address$line_C";

  my $header = "$line_C$B_TL"
             . ($B_hor x 5)
             . "$B_boxleft $dest $B_boxright"
             . ($B_hor x (72 - $dest_width - 4))
             . "$B_TR$null_C\n";

  my $footer = "$line_C$B_BL" . ($B_hor x 77) . "$B_BR$null_C\n";

  my $new_text = q{};

  my @lines = split /\n/, $text;
  while (my $line = shift @lines) {
    $new_text .= "$line_C$B_ver $text_C";
    if (length $line > 76) {
      my ($old, $rest) = $line =~ /\A(.{1,76})\s+(.+)/;
      if (length $old) {
        $new_text .= $old;
        unshift @lines, $rest;
      } else {
        # Oh well, nothing to do about it!
        $new_text = $line;
      }
    } else {
      $new_text .= $line;
    }
    $new_text .= "$null_C\n";
  }

  return "$header$new_text$footer";
}

sub _format_message ($self, $name, $address, $text) {
  if ($self->message_format eq 'compact') {
    return $self->_format_message_compact($name, $address, $text)
  }

  return $self->_format_message_chonky($name, $address, $text)
}

sub send_message ($self, $address, $text, $alts = {}) {
  my $name = $self->name;

  $self->_stream->write(
    $self->_format_message($name, $address, $text)
  );
}

sub describe_event ($self, $event) {
  return "(a console event)";
}

sub describe_conversation ($self, $event) {
  return "[console]";
}

1;
