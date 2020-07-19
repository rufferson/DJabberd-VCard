
package DJabberd::Plugin::VCard::InMemoryOnly;
use strict;
use base 'DJabberd::Plugin::VCard';
use warnings;

our $logger = DJabberd::Log->get_logger();

sub load_vcard {
    my ($self, $user, $cb) = @_;
    $self->{vcards} ||= {};
    $cb->($self->{vcards}{$user->as_bare_string});
}

sub store_vcard {
    my ($self, $user, $vcard, $cb) = @_;
    $self->{vcards} ||= {};
    $self->{vcards}{$user->as_bare_string} = $vcard->as_xml;
    $cb->();
}

1;
