package Mojo::Reactor::Poll;
use Mojo::Base 'Mojo::Reactor';

use IO::Poll qw(POLLERR POLLHUP POLLIN POLLNVAL POLLOUT POLLPRI);
use List::Util 'min';
use Mojo::Util qw(md5_sum steady_time);
use Time::HiRes 'usleep';

sub again {
  my $timer = shift->{timers}{shift()};
  $timer->{time} = steady_time + $timer->{after};
}

sub io {
  my ($self, $handle, $cb) = @_;
  $self->{io}{fileno $handle} = {cb => $cb};
  return $self->watch($handle, 1, 1);
}

sub is_running { !!shift->{running} }

sub one_tick {
  my $self = shift;

  # Just one tick
  local $self->{running} = 1 unless $self->{running};

  # Wait for one event
  my $i;
  until ($i || !$self->{running}) {

    # Stop automatically if there is nothing to watch
    return $self->stop unless keys %{$self->{timers}} || keys %{$self->{io}};

    # Calculate ideal timeout based on timers and round up to next millisecond
    my $min = min map { $_->{time} } values %{$self->{timers}};
    my $timeout = defined $min ? $min - steady_time : 0.5;
    $timeout = $timeout <= 0 ? 0 : int($timeout * 1000) + 1;

    # I/O
    if (keys %{$self->{io}}) {
      my @poll = map { $_ => $self->{io}{$_}{mode} } keys %{$self->{io}};

      # This may break in the future, but is worth it for performance
      if (IO::Poll::_poll($timeout, @poll) > 0) {
        while (my ($fd, $mode) = splice @poll, 0, 2) {

          if ($mode & (POLLIN | POLLPRI | POLLNVAL | POLLHUP | POLLERR)) {
            next unless my $io = $self->{io}{$fd};
            ++$i and $self->_sandbox('Read', $io->{cb}, 0);
          }
          next unless $mode & POLLOUT && (my $io = $self->{io}{$fd});
          ++$i and $self->_sandbox('Write', $io->{cb}, 1);
        }
      }
    }

    # Wait for timeout if poll can't be used
    elsif ($timeout) { usleep $timeout * 1000 }

    # Timers (time should not change in between timers)
    my $now = steady_time;
    for my $id (keys %{$self->{timers}}) {
      next unless my $t = $self->{timers}{$id};
      next unless $t->{time} <= $now;

      # Recurring timer
      if (exists $t->{recurring}) { $t->{time} = $now + $t->{recurring} }

      # Normal timer
      else { $self->remove($id) }

      ++$i and $self->_sandbox("Timer $id", $t->{cb}) if $t->{cb};
    }
  }
}

sub recurring { shift->_timer(1, @_) }

sub remove {
  my ($self, $remove) = @_;
  return !!delete $self->{timers}{$remove} unless ref $remove;
  return !!delete $self->{io}{fileno $remove};
}

sub reset { delete @{shift()}{qw(io timers)} }

sub start {
  my $self = shift;
  $self->{running}++;
  $self->one_tick while $self->{running};
}

sub stop { delete shift->{running} }

sub timer { shift->_timer(0, @_) }

sub watch {
  my ($self, $handle, $read, $write) = @_;

  my $mode = 0;
  $mode |= POLLIN | POLLPRI if $read;
  $mode |= POLLOUT if $write;
  $self->{io}{fileno $handle}{mode} = $mode;

  return $self;
}

sub _id {
  my $self = shift;
  my $id;
  do { $id = md5_sum 't' . steady_time . rand 999 } while $self->{timers}{$id};
  return $id;
}

sub _sandbox {
  my ($self, $event, $cb) = (shift, shift, shift);
  eval { $self->$cb(@_); 1 } or $self->emit(error => "$event failed: $@");
}

sub _timer {
  my ($self, $recurring, $after, $cb) = @_;

  my $id    = $self->_id;
  my $timer = $self->{timers}{$id}
    = {cb => $cb, after => $after, time => steady_time + $after};
  $timer->{recurring} = $after if $recurring;

  return $id;
}

1;

=encoding utf8

=head1 NAME

Mojo::Reactor::Poll - Low-level event reactor with poll support

=head1 SYNOPSIS

  use Mojo::Reactor::Poll;

  # Watch if handle becomes readable or writable
  my $reactor = Mojo::Reactor::Poll->new;
  $reactor->io($first => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'First handle is writable' : 'First handle is readable';
  });

  # Change to watching only if handle becomes writable
  $reactor->watch($first, 0, 1);

  # Turn file descriptor into handle and watch if it becomes readable
  my $second = IO::Handle->new_from_fd($fd, 'r');
  $reactor->io($second => sub {
    my ($reactor, $writable) = @_;
    say $writable ? 'Second handle is writable' : 'Second handle is readable';
  })->watch($second, 1, 0);

  # Add a timer
  $reactor->timer(15 => sub {
    my $reactor = shift;
    $reactor->remove($first);
    $reactor->remove($second);
    say 'Timeout!';
  });

  # Start reactor if necessary
  $reactor->start unless $reactor->is_running;

=head1 DESCRIPTION

L<Mojo::Reactor::Poll> is a low-level event reactor based on L<IO::Poll>.

=head1 EVENTS

L<Mojo::Reactor::Poll> inherits all events from L<Mojo::Reactor>.

=head1 METHODS

L<Mojo::Reactor::Poll> inherits all methods from L<Mojo::Reactor> and
implements the following new ones.

=head2 again

  $reactor->again($id);

Restart active timer.

=head2 io

  $reactor = $reactor->io($handle => sub {...});

Watch handle for I/O events, invoking the callback whenever handle becomes
readable or writable.

=head2 is_running

  my $bool = $reactor->is_running;

Check if reactor is running.

=head2 one_tick

  $reactor->one_tick;

Run reactor until an event occurs or no events are being watched anymore. Note
that this method can recurse back into the reactor, so you need to be careful.

=head2 recurring

  my $id = $reactor->recurring(0.25 => sub {...});

Create a new recurring timer, invoking the callback repeatedly after a given
amount of time in seconds.

=head2 remove

  my $bool = $reactor->remove($handle);
  my $bool = $reactor->remove($id);

Remove handle or timer.

=head2 reset

  $reactor->reset;

Remove all handles and timers.

=head2 start

  $reactor->start;

Start watching for I/O and timer events, this will block until L</"stop"> is
called or no events are being watched anymore.

=head2 stop

  $reactor->stop;

Stop watching for I/O and timer events.

=head2 timer

  my $id = $reactor->timer(0.5 => sub {...});

Create a new timer, invoking the callback after a given amount of time in
seconds.

=head2 watch

  $reactor = $reactor->watch($handle, $readable, $writable);

Change I/O events to watch handle for with true and false values. Note that
this method requires an active I/O watcher.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
