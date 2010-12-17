#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2010 -- leonerd@leonerd.org.uk

package IO::Async::Loop::POE;

use strict;
use warnings;

our $VERSION = '0.02';
use constant API_VERSION => '0.24';

use base qw( IO::Async::Loop );

use Carp;

use POE::Kernel;
use POE::Session;

# Placate POE warning that we didn't call this
# It won't do anything yet as we have no sessions
POE::Kernel->run();

=head1 NAME

L<IO::Async::Loop::POE> - use C<IO::Async> with C<POE>

=head1 SYNOPSIS

 use IO::Async::Loop::POE;

 my $loop = IO::Async::Loop::POE->new();

 $loop->add( ... );

 $loop->add( IO::Async::Signal->new(
       name => 'HUP',
       on_receipt => sub { ... },
 ) );

 $loop->loop_forever();

=head1 DESCRIPTION

This subclass of L<IO::Async::Loop> uses L<POE> to perform its work.

The entire C<IO::Async> system is represented by a single long-lived session
within the C<POE> core. It fully supports sharing the process space with
C<POE>; such resources as signals are properly shared between both event
systems.

=head1 CONSTRUCTOR

=cut

=head2 $loop = IO::Async::Loop::POE->new( %args )

This function returns a new instance of a C<IO::Async::Loop::POE> object.
It takes the following named arguments:

=over 8

=back

=cut

sub new
{
   my $class = shift;
   my ( %args ) = @_;

   my $self = $class->SUPER::__new( %args );

   $self->{session} = POE::Session->create(
      inline_states => {
         _start => sub {
            $_[KERNEL]->alias_set( "IO::Async" );
         },
         invoke => sub {
            # CODEref is always in the last position, but what that is varies
            # given the different events use different initial args
            $_[-1]->();
         },
         invoke_signal => sub {
            $_[-1]->();
            $_[KERNEL]->sig_handled;
         },
         invoke_child => sub {
            $_[-1]->( $_[ARG1], $_[ARG2] ); # $pid, $dollarq
         },
         perform => sub {
            $_[ARG0]->();
         },
      }
   );

   return $self;
}

sub _perform
{
   my $self = shift;
   POE::Kernel->call( $self->{session}, perform => @_ );
}

sub loop_once
{
   my $self = shift;
   my ( $timeout ) = @_;

   if( defined $timeout and $timeout == 0 ) {
      POE::Kernel->run_one_timeslice;
      return;
   }

   my $timer_id;
   if( defined $timeout ) {
      $timer_id = $self->_perform(sub { POE::Kernel->delay_set( invoke => $timeout, sub { } ) });
   }

   POE::Kernel->run_one_timeslice;

   $self->_perform(sub { POE::Kernel->alarm_remove( $timer_id ) });
}

sub watch_io
{
   my $self = shift;
   my %params = @_;

   my $handle = $params{handle} or die "Need a handle";

   if( my $on_read_ready = $params{on_read_ready} ) {
      $self->_perform(sub{ POE::Kernel->select_read( $handle, invoke => $on_read_ready ) });
   }

   if( my $on_write_ready = $params{on_write_ready} ) {
      $self->_perform(sub{ POE::Kernel->select_write( $handle, invoke => $on_write_ready ) });
   }
}

sub unwatch_io
{
   my $self = shift;
   my %params = @_;

   my $handle = $params{handle} or die "Need a handle";

   if( my $on_read_ready = $params{on_read_ready} ) {
      $self->_perform(sub{ POE::Kernel->select_read( $handle ) });
   }

   if( my $on_write_ready = $params{on_write_ready} ) {
      $self->_perform(sub{ POE::Kernel->select_write( $handle ) });
   }
}

sub enqueue_timer
{
   my $self = shift;
   my %params = @_;

   my $time = $self->_build_time( %params );

   my $code = $params{code} or croak "Expected 'code' as CODE ref";

   return $self->_perform(sub { POE::Kernel->alarm_set( invoke => $time, $code ) });
}

sub cancel_timer
{
   my $self = shift;
   my ( $id ) = @_;

   $self->_perform(sub { POE::Kernel->alarm_remove( $id ) });
}

sub requeue_timer
{
   my $self = shift;
   my ( $id, %params ) = @_;

   my $time = $self->_build_time( %params );

   return $self->_perform(sub {
         # TODO: POE docs claim we get an ARRAY ref back here, but testing
         # suggests it's just a list
         my ( undef, undef, $data ) = POE::Kernel->alarm_remove( $id );
         return POE::Kernel->alarm_set( invoke => $time, $data );
   });
}

sub watch_signal
{
   my $self = shift;
   my ( $signal, $code ) = @_;

   exists $SIG{$signal} or croak "Cannot watch signal '$signal' - bad signal name";

   $self->_perform(sub { POE::Kernel->sig( $signal, invoke_signal => $code ) });
}

sub unwatch_signal
{
   my $self = shift;
   my ( $signal ) = @_;

   $self->_perform(sub { POE::Kernel->sig( $signal ) });
}

sub watch_idle
{
   my $self = shift;
   my %params = @_;

   my $when = delete $params{when} or croak "Expected 'when'";

   my $code = delete $params{code} or croak "Expected 'code' as a CODE ref";

   $when eq "later" or croak "Expected 'when' to be 'later'";

   return $self->_perform(sub { POE::Kernel->delay_set( invoke => 0, $code ) });
}

sub unwatch_idle
{
   my $self = shift;
   my ( $id ) = @_;

   $self->_perform(sub { POE::Kernel->alarm_remove( $id ) });
}

sub watch_child
{
   my $self = shift;
   my ( $pid, $code ) = @_;

   $self->_perform(sub { POE::Kernel->sig_child( $pid, invoke_child => $code ) });
}

sub unwatch_child
{
   my $self = shift;
   my ( $pid ) = @_;

   $self->_perform(sub { POE::Kernel->sig_child( $pid ) });
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
