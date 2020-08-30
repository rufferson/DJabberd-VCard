package DJabberd::Plugin::VCard::PEP;
use strict;
use base 'DJabberd::Plugin::VCard';
use warnings;
use DJabberd::Log;
DJabberd::Log->set_logger();
use DJabberd::Plugin::PEP;
use XML::LibXML '1.70';
use MIME::Base64;
use Digest::SHA;


use constant AVAMD => 'urn:xmpp:avatar:metadata';
use constant AVABD => 'urn:xmpp:avatar:data';
use constant AVAUP => 'vcard-temp:x:update';
use constant CNVNS => 'urn:xmpp:pep-vcard-conversion:0';

our $logger = DJabberd::Log->get_logger(__PACKAGE__);
sub register {
    my $self = shift;
    my $vhost = shift;
    $self->{vh} = $vhost;
    $self->{xp} = XML::LibXML->new(no_network => 1, validation => 0);
    $vhost->register_hook("DiscoBare", sub {
	my ($vh,$cb,$iq,$disco,$bare,$from,$ri) = @_;
	if($disco eq 'info' && $ri && ref($ri) && $ri->subscription->{from}) {
	    return $cb->addFeatures(CNVNS);
	}
	$cb->decline;
    });
    $vhost->register_hook("AlterPresenceAvailable", sub {
	my ($vh, $cb, $conn, $pres) = @_;
	my %meta = $self->load_meta($conn->bound_jid);
	if(%meta && $meta{id}) {
	    $pres->push_child(DJabberd::XMLElement->new(AVAUP, 'x', {'{}xmlns'=>AVAUP},
		[
		    DJabberd::XMLElement->new(undef, 'photo', {}, [$meta{id}]),
		]));
	}
	$cb->decline();
    });
    $self->SUPER::register($vhost);
}

sub vhost { $_[0]->{vh} }

sub pepper {
    my $self = shift;
    $logger->debug("Checking PEP for VCard");
    unless(!$self->{pep} && ref($self->{pep})) {
	$logger->debug('Obtaining PEP instance for '.$self->vhost->server_name);
	$self->vhost->hook_chain_fast('GetPlugin',
				[ 'DJabberd::Plugin::PEP' ],
				{ set => sub { $self->{pep} = $_[1] } });
    }
    return $self->{pep};
}

sub load_meta {
    my ($self, $user) = @_;
    return () unless($self->pepper);
    my ($vmi) = $self->{pep}->get_pub_last($user, AVAMD, undef, 1);
    if($vmi) {
	my %info;
	$logger->debug("Retrieved MD item: ".$vmi->{data});

	if($vmi->{data}) {
	    my $meta;
	    eval {
	        ($meta) = grep{$_->nodeName eq 'info' && $_->{type} eq 'image/png'}$self->{xp}->parse_balanced_chunk($vmi->{data})->firstChild->childNodes;
	    };
	    %info = map{($_->nodeName => $_->value)}$meta->attributes if($meta);
	}
	return %info;
    }
    return ();
}

sub load_vcard {
    my ($self, $user, $cb) = @_;
    # Since we're only fetching 'last' no reason to go async as it's always in-memory
    $logger->info("Loading VCard from PEP");
    if($self->pepper) {
	my %info = $self->load_meta($user);
	if(%info) {
	    my $vdi = $self->{pep}->get_pub_last($user, AVABD, $info{id}, 1);
	    unless($vdi) {
		$logger->debug("No data or usable metadata found");
		return $cb->();
	    }
	    my $data;
	    if($vdi->{data}) {
		eval {
	           ($data) = grep{$_->nodeName eq 'data' && $_->{xmlns} eq AVABD}$self->{xp}->parse_balanced_chunk($vdi->{data})->firstChild;
	    	};
	    }
	    if(ref($data)) {
		my $vcard = DJabberd::XMLElement->new('vcard-temp', 'vCard', {'{}xmlns'=>'vcard-temp'}, [
			DJabberd::XMLElement->new(undef, 'PHOTO', {}, [
			    DJabberd::XMLElement->new(undef,'TYPE',{},[],$info{type}),
			    DJabberd::XMLElement->new(undef,'BINVAL',{},[],$data->textContent),
			])
		    ]);
		return $cb->($vcard->as_xml);
	    }
        }
    }
    $cb->();
}

sub store_vcard {
    my ($self, $user, $vcard, $cb) = @_;

    if($self->pepper) {
	my %attrs;
	my ($photo) = grep{$_->element eq '{vcard-temp}PHOTO'}$vcard->children_elements;
	if($photo) {
	    # Publish new MD and BD
	    my ($type) = map{$_->innards_as_xml}grep{$_->element_name eq 'TYPE'}$photo->children_elements;
	    my ($data) = map{$_->innards_as_xml}grep{$_->element_name eq 'BINVAL'}$photo->children_elements;
	    if($type && $data) {
		my $bin = MIME::Base64::decode($data);
		my $bytes = length($bin);
		my $digest = Digest::SHA::sha1_hex($bin);
		$logger->debug("We've just got avatar: $type; $bytes");
		# First comes the data, it's normally not broadcasted, fetched on demand
		my $item = DJabberd::XMLElement->new(undef, 'item', {
		    '{}id' => $digest,
		},[
		    DJabberd::XMLElement->new(AVABD, 'data', {'{}xmlns' => AVABD }, [], $data)
		]);
		my $cfg = $self->{pep}->get_pub_cfg($user, AVABD);
		if(!$cfg) {
		    $self->{pep}->set_pub($user, AVABD);
		    $self->{pep}->set_pub_cfg($user, AVABD, {persist_items => 1, max => 10});
		} elsif(!$cfg->{persist_items} || $cfg->{max} < 10) {
		    $self->{pep}->set_pub_cfg($user, AVABD, {persist_items => 1, max => 10});
		}
		$self->{pep}->publish($user, AVABD, $item);
		# Now comes metadata, this is normally broadcasted to all subscribers
		$item = DJabberd::XMLElement->new(undef, 'item', {
		    '{}id' => $digest,
		},[
		    DJabberd::XMLElement->new(AVAMD, 'metadata', { '{}xmlns'=> AVAMD },
		    [
			DJabberd::XMLElement->new(AVAMD, 'info', {
				'{}bytes' => $bytes,
				'{}type' => $type,
				'{}id' => $digest,
				%attrs,
			    },[])
		    ])
		]);
		$cfg = $self->{pep}->get_pub_cfg($user, AVAMD);
		if(!$cfg) {
		    $self->{pep}->set_pub($user, AVAMD);
		    $self->{pep}->set_pub_cfg($user, AVAMD, {persist_items => 1, max => 10});
		} elsif(!$cfg->{persist_items} || $cfg->{max} < 10) {
		    $self->{pep}->set_pub_cfg($user, AVAMD, {persist_items => 1, max => 10});
		}
		$self->{pep}->publish($user, AVAMD, $item);
	    }
	}
	$cb->();
    } else {
	$cb->('PEP node not available');
    }
}

1;
