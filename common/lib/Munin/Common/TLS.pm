package Munin::Common::TLS;

use warnings;
use strict;

use Carp;
use English qw(-no_match_vars);

sub new {
    my ($class, $read_fd, $write_fd, $read_func, $write_func, $logger, $debug) = @_;

    my $self = {
        tls_context        => undef,
        tls_session        => undef,
        read_fd            => $read_fd,
        write_fd           => $write_fd,
        read_func          => $read_func,
        write_func         => $write_func,
        logger             => $logger,
        DEBUG              => $debug || 0,
        private_key_loaded => 0,
    };

    return bless $self, $class;
}


sub start_tls_client {
    my $self = shift;

    my $tls_paranoia = shift;
    my $tls_cert     = shift;
    my $tls_priv     = shift;
    my $tls_ca_cert  = shift;
    my $tls_verify   = shift;
    my $tls_vdepth   = shift;

    my $remote_key = 0;

    $self->_start_tls(
        $tls_paranoia,
        $tls_cert,
        $tls_priv,
        $tls_ca_cert,
        $tls_verify,
        $tls_vdepth,
        sub {
            # Tell the node that we want TLS
            $self->{write_func}("STARTTLS\n");
            my $tlsresponse = $self->{read_func}();
            if (!defined $tlsresponse) {
                $self->{logger}("[ERROR] Bad TLS response \"\".");
                return 0
            }
            if ($tlsresponse =~ /^TLS OK/) {
                $remote_key = 1;
            }
            elsif ($tlsresponse !~ /^TLS MAYBE/i) {
                $self->{logger}("[ERROR] Bad TLS response \"$tlsresponse\".");
                return 0;
            }
        },
        sub {
            my ($has_key) = @_;
            return !$remote_key;
        },
        sub {
            $self->write("quit\n");
        },
    );
}


sub start_tls_server {
    my $self         = shift;
    my $tls_paranoia = shift;
    my $tls_cert     = shift;
    my $tls_priv     = shift;
    my $tls_ca_cert  = shift;
    my $tls_verify   = shift;
    my $tls_vdepth   = shift;


    $self->_start_tls(
        $tls_paranoia,
        $tls_cert,
        $tls_priv,
        $tls_ca_cert,
        $tls_verify,
        $tls_vdepth,
        sub {
            my ($has_key) = @_;
            if ($has_key) {
                $self->{write_func}("TLS OK\n");
            }
            else {
                $self->{write_func}("TLS MAYBE\n");
            }
            
            return 1;
        },
        sub {
            my ($has_key) = @_;
            return $has_key;
        },
        sub {},
    );
}

sub _start_tls {
    my $self = shift;

    my $tls_paranoia = shift || 0;
    my $tls_cert     = shift || '';
    my $tls_priv     = shift || '';
    my $tls_ca_cert  = shift || '';
    my $tls_verify   = shift || 0;
    my $tls_vdepth   = shift || 0; 

    my $communicate         = shift;
    my $use_key_if_present  = shift;
    my $unverified_callback = shift;

    my %tls_verified = (
        level          => 0, 
        cert           => "",
        verified       => 0, 
        required_depth => $tls_vdepth, 
        verify         => $tls_verify,
    );

    $self->{logger}("[TLS] Enabling TLS.") if $self->{DEBUG};
    
    $self->_load_net_ssleay()
        or return 0;

    $self->_initialize_net_ssleay();

    $self->{tls_context} = $self->_creat_tls_context();

    $self->_load_private_key($tls_paranoia, $tls_priv)
        or return 0;
    
    $self->_load_certificate($tls_cert);

    $self->_load_ca_certificate($tls_ca_cert);
    
    $communicate->($self->{private_key_loaded})
        or return 0;
    
    $self->_set_peer_requirements($tls_vdepth, $tls_verify, \%tls_verified);
    
    if (! ($self->{tls_session} = Net::SSLeay::new($self->{tls_context})))
    {
	$self->{logger}("[ERROR] Could not create TLS: $!");
	return 0;
    }

    $self->_log_cipher_list() if $self->{DEBUG};

    $self->_set_ssleay_file_descriptors();

    $self->_accept_or_connect(
        $tls_paranoia,
        \%tls_verified,
        $use_key_if_present,
        $unverified_callback,
    );

    return $self->{tls_session};
}


sub _load_net_ssleay {
    my ($self) = @_;

    eval {
        require Net::SSLeay;
    };
    if ($@) {
	$self->{logger}("[ERROR] TLS enabled but Net::SSLeay unavailable.");
	return 0;
    }

    return 1;
}


sub _initialize_net_ssleay {
    my ($self) = @_;

    Net::SSLeay::load_error_strings();
    Net::SSLeay::SSLeay_add_ssl_algorithms();
    Net::SSLeay::randomize();
}


sub _creat_tls_context {
    my ($self) = @_;

    my $ctx = Net::SSLeay::CTX_new();
    if (!$ctx) {
	$self->{logger}("[ERROR] Could not create SSL_CTX");
	return 0;
    }

    # Tune a few things...
    if (Net::SSLeay::CTX_set_options($ctx, &Net::SSLeay::OP_ALL)) {
	$self->{logger}("[ERROR] Could not set SSL_CTX options");
	return 0;
    }

    return $ctx;
}


sub _load_private_key {
    my ($self, $tls_paranoia, $tls_priv) = @_;

    if (defined $tls_priv and length $tls_priv) {
    	if (-e $tls_priv or $tls_paranoia eq "paranoid") {
	    if (Net::SSLeay::CTX_use_PrivateKey_file($self->{tls_context}, $tls_priv, 
                                                     &Net::SSLeay::FILETYPE_PEM)) {
                $self->{private_key_loaded} = 1;
            }
            else {
	        if ($tls_paranoia eq "paranoid") {
	    	    $self->{logger}("[ERROR] Problem occured when trying to read file with private key \"$tls_priv\": $!");
		    return 0;
	        }
	        else {
	    	    $self->{logger}("[ERROR] Problem occured when trying to read file with private key \"$tls_priv\": $!. Continuing without private key.");
	        }
	    }
	}
	else {
	    $self->{logger}("[WARNING] No key file \"$tls_priv\". Continuing without private key.");
        }
    }

    return 1;
}


sub _load_certificate {
    my ($self, $tls_cert) = @_;

    if ($tls_cert && -e $tls_cert) {
        if (defined $tls_cert and length $tls_cert) {
	    if (!Net::SSLeay::CTX_use_certificate_file($self->{tls_context}, 
                                                       $tls_cert, 
                                                       &Net::SSLeay::FILETYPE_PEM)) {
	        $self->{logger}("[WARNING] Problem occured when trying to read file with certificate \"$tls_cert\": $!. Continuing without certificate.");
	    }
        }
    }
    else {
	$self->{logger}("[WARNING] No certificate file \"$tls_cert\". Continuing without certificate.");
    }

    return 1;
}


sub _load_ca_certificate {
    my ($self, $tls_ca_cert) = @_;

    if ($tls_ca_cert && -e $tls_ca_cert) {
    	if(!Net::SSLeay::CTX_load_verify_locations($self->{tls_context}, $tls_ca_cert, '')) {
    	    $self->{logger}("[WARNING] Problem occured when trying to read file with the CA's certificate \"$tls_ca_cert\": ".&Net::SSLeay::print_errs("").". Continuing without CA's certificate.");
   	 }
    }

    return 1;
}


sub _set_peer_requirements {
    my ($self, $tls_vdepth, $tls_verify, $tls_verified) = @_;

    $tls_vdepth = 5 if !defined $tls_vdepth;
    Net::SSLeay::CTX_set_verify_depth ($self->{tls_context}, $tls_vdepth);
    my $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err) {
	$self->{logger}("[WARNING] in set_verify_depth: $err");
    }
    Net::SSLeay::CTX_set_verify ($self->{tls_context}, 
                                 &Net::SSLeay::VERIFY_PEER, 
                                 $self->_tls_verify_callback($tls_verified));
    $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err) {
	$self->{logger}("[WARNING] in set_verify: $err");
    }
    
    return 1;
}


sub _tls_verify_callback {
    my ($self, $tls_verified) = @_;

    return sub {
        my ($ok, $subj_cert, $issuer_cert, $depth, 
	    $errorcode, $arg, $chain) = @_;
        #    $self->{logger}("ok is ${ok}");

        $tls_verified->{"level"}++;

        if ($ok) {
            $tls_verified->{"verified"} = 1;
            $self->{logger}("[TLS] Verified certificate.") if $self->{DEBUG};
            return 1;           # accept
        }
        
        if (!($tls_verified->{"verify"} eq "yes")) {
            $self->{logger}("[TLS] Certificate failed verification, but we aren't verifying.") if $self->{DEBUG};
            $tls_verified->{"verified"} = 1;
            return 1;
        }

        if ($tls_verified->{"level"} > $tls_verified->{"required_depth"}) {
            $self->{logger}("[TLS] Certificate verification failed at depth ".$tls_verified->{"level"}.".");
            $tls_verified->{"verified"} = 0;
            return 0;
        }

        return 0;               # Verification failed
    }
}


sub _log_cipher_list {
    my ($self) = @_;

    my $i = 0;
    my $p = '';
    my $cipher_list = 'Cipher list: ';
    $p=Net::SSLeay::get_cipher_list($self->{tls_session},$i);
    $cipher_list .= $p if $p;
    do {
        $i++;
        $cipher_list .= ', ' . $p if $p;
        $p=Net::SSLeay::get_cipher_list($self->{tls_session},$i);
    } while $p;
    $cipher_list .= '\n';
    $self->{logger}("[TLS] Available cipher list: $cipher_list.");
}


sub _set_ssleay_file_descriptors {
    my ($self) = @_;

    Net::SSLeay::set_rfd($self->{tls_session}, $self->{read_fd});
    my $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err) {
        $self->{logger}("TLS Warning in set_rfd: $err");
    }
    Net::SSLeay::set_wfd($self->{tls_session}, $self->{write_fd});
    $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err) {
        $self->{logger}("TLS Warning in set_wfd: $err");
    }
}


sub _accept_or_connect {
    my ($self, $tls_paranoia, $tls_verified, $use_key_if_present, $unverified_callback) = @_;

    $self->{logger}("Accept/Connect: $self->{private_key_loaded}, " . $use_key_if_present->($self->{private_key_loaded})) if $self->{DEBUG};
    my $res;
    if ($use_key_if_present->($self->{private_key_loaded})) {
        $res = Net::SSLeay::accept($self->{tls_session});
    }
    else {
        $res = Net::SSLeay::connect($self->{tls_session});
    }
    $self->{logger}("Done Accept/Connect") if $self->{DEBUG};

    my $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err)
    {
	$self->{logger}("[ERROR] Could not enable TLS: " . $err);
	Net::SSLeay::free ($self->{tls_session});
	Net::SSLeay::CTX_free ($self->{tls_context});
	$self->{tls_session} = undef;
    }
    elsif (!$tls_verified->{"verified"} and $tls_paranoia eq "paranoid")
    {
	$self->{logger}("[ERROR] Could not verify CA: " . Net::SSLeay::dump_peer_certificate($self->{tls_session}));
	$unverified_callback->();
	Net::SSLeay::free ($self->{tls_session});
	Net::SSLeay::CTX_free ($self->{tls_context});
	$self->{tls_session} = undef;
    }
    else
    {
	$self->{logger}("[TLS] TLS enabled.");
	$self->{logger}("[TLS] Cipher `" . Net::SSLeay::get_cipher($self->{tls_session}) . "'.");
	$self->{logger}("[TLS] client cert: " . Net::SSLeay::dump_peer_certificate($self->{tls_session}));
    }
}


sub read {
    my ($self) = @_;

    local $_;

    eval { $_ = Net::SSLeay::read($self->{tls_session}); };
    my $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err) {
        $self->{logger}("TLS Warning in read: $err");
        return;
    }
    if($_ eq '') { undef $_; } #returning '' signals EOF

    $self->{logger}("DEBUG: < $_") if $self->{DEBUG};

    return $_;
}


sub write {
    my ($self, $text) = @_;

    $self->{logger}("DEBUG: > $text") if $self->{DEBUG};

    eval { Net::SSLeay::write($self->{tls_session}, $text); };
    my $err = &Net::SSLeay::print_errs("");
    if (defined $err and length $err) {
        $self->{logger}("TLS Warning in write: $err");
    }
}



1;

=head1 NAME

Munin::Node::TLS - Implements the STARTTLS protocol


=head1 SYNOPSIS

FIX


=head1 METHODS

=over

=item B<new>

FIX

=item B<start_tls_client>

FIX

=item B<start_tls_server>

FIX

=item B<read>

FIX

=item B<write>

FIX

=back
