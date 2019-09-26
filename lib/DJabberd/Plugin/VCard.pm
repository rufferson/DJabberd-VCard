package DJabberd::Plugin::VCard;
use strict;
use base 'DJabberd::Plugin';
use warnings;

our $VERSION = '0.50'; 

our $logger = DJabberd::Log->get_logger();

# this spec implements the jep--0054 vcard spec using an SQLite store
# later it should be refactored to have pluggable stores
# but I really just want to get it out there -- sky
# This should be split into the following
#  DJabberd::Plugin::VCard::IQ isa DJabberd::IQ
#  DJabberd::Plugin::VCard::SQLite isa Djabberd::Plugin::VCard
#  DJabberd::Plugin::VCard manages and loads everythign



sub iq_class {
    "DJabberd::Plugin::VCard::IQ";
}

our @feats = ( "vcard-temp" );

sub register {
    my ($self, $vhost) = @_;
    my $vcard_cb = sub {
        my ($vh, $cb, $iq) = @_;
        unless ($iq->isa("DJabberd::IQ")) {
            $cb->decline;
            return;
        }
        if(my $to = $iq->to_jid) {
            unless ($vh->handles_jid($to)) {
                $cb->decline;
                return;
            }
        }
        if ($iq->signature eq 'get-{vcard-temp}vCard') {
            $self->get_vcard($vh, $iq);
            $cb->stop_chain;
            return;
        } elsif ($iq->signature eq 'set-{vcard-temp}vCard') {
            $self->set_vcard($vh, $iq);
            $cb->stop_chain;
            return;
        }
        $cb->decline;
    };
    $vhost->register_hook("switch_incoming_client",$vcard_cb);
    $vhost->register_hook("switch_incoming_server",$vcard_cb);
    map{$vhost->add_feature($_)}@feats;
}


sub get_vcard {
    my ($self, $vhost, $iq) = @_;
    my $user;
    if ($iq->to) {
        $user = $iq->to_jid->as_bare_string;
    } else {
        # user is requesting their own vCard
        $user = $iq->connection->bound_jid->as_bare_string;
    }
    $logger->info("Getting vcard for user '$user'");
    # Just make it a lil' less synchronous
    $self->load_vcard($user, sub {
        my $vcard = shift;
        my $reply;
        if($vcard) {
            $reply = $self->make_response($iq, $vcard);
        } else {
            $reply = $self->make_response($iq, "<vCard xmlns='vcard-temp'/>");
        }
        $reply->deliver($vhost);
    });
}


sub make_response {
    my ($self, $iq, $vcard) = @_;
    my $response = $iq->clone;
    my $from = $iq->from;
    my $to   = $iq->to;

    $response->set_raw($vcard);

    $response->attrs->{"{}type"} = 'result';
    $response->set_to($from);
    $to ? $response->set_from($to) : delete($response->attrs->{"{}from"});

    return $response;
}

sub set_vcard {
    my ($self, $vhost, $iq) = @_;

    my $vcard = $iq->first_element();
    my $user  = $iq->connection->bound_jid->as_bare_string;
    $self->store_vcard($user, $vcard, sub {
        if(@_ && $_[0]) {
            $logger->info("Failed setting vcard for user '$user': ".$_[0]);
            $iq->send_reply('error',"<error type='wait'>
                <remote-server-timeout xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
                <text>".DJabberd::Util::exml(shift)."</text>
            </error>");
        } else {
            $logger->info("Set vcard for user '$user'");
            $self->make_response($iq)->deliver($vhost);
        }
    });
}


1;

__END__

=head1 NAME

DJabberd::Plugin::VCard - VCard storage plugin

