package pf::clustermgmt;

=head1 NAME

pf::clustermgmt

=cut

=head1 DESCRIPTION

Use as a rpc server and as a rpc client.
It will sync between all the cluster members somes configurations parameters.

=cut

use Apache2::RequestRec ();
use Apache2::Request;
use Apache2::Const;
use APR::URI ();
use NetAddr::IP;
use List::MoreUtils qw(uniq);
use Try::Tiny;

use strict;
use pf::config;
use pf::config::cached;
use pf::db;
use pf::log(service => 'httpd.admin');
use pf::util;
use pf::ConfigStore::Interface;
use pf::ConfigStore::Pf;
use NetAddr::IP;
use List::MoreUtils qw(uniq);
use pf::api::jsonrpcclient;
use pf::services;


our %STATUS_PARSERS = (
    status => \&status,
    mysql => \&mysql,
);

our %MYSQL_ACTION = (
    connect => \&connect,
    cluster => \&cluster,
);

# DATABASE HANDLING
use constant CLUSTERMGMT       => 'clustermgmt';
our $clustermgmt_db_prepared   = 0;
our $clustermgmt_statements    = {};

sub clustermgmt_db_prepare {
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    $logger->debug("Preparing database statements.");

    $clustermgmt_statements->{'cluster_test_sql'} = get_db_handle()->prepare(qq[
            SELECT 1 FROM node LIMIT 1
    ]);

    $clustermgmt_db_prepared = 1;
    return 1;
}

=item handler

The handler check the status of all the services of the cluster and only allow connection from
the management network (need it for haproxy check)

=cut

sub handler {

    my $r = (shift);

    my $parsed = APR::URI->parse($r->pool, $r->uri);

    my @uri_elements = split('/',$parsed->path);
    shift @uri_elements;

    my $action = shift @uri_elements;
    $r->handler('modperl');
    $r->set_handlers( PerlResponseHandler => \&answer );
    if (defined( $STATUS_PARSERS{$action} )) {
        return $STATUS_PARSERS{$action}($r,\@uri_elements);
    } else {
        return  Apache2::Const::SERVER_ERROR;
    }

}

=head2 status

Return 200 if the service is running, 500 else

=cut

sub status {

    my ($r,$uri_elements) = @_;

    my $service = shift @{$uri_elements};
    if (grep { $_ eq $service } @pf::services::ALL_SERVICES) {
        my $manager = pf::services::get_service_manager($service);
        if ($manager->status('1')) {
            return  Apache2::Const::OK;
        } else {
            return  Apache2::Const::SERVER_ERROR;
        }
    } else {
        return  Apache2::Const::SERVER_ERROR;
    }
    return Apache2::Const::OK;
}

=head2 mysql

Check the status of mysql, is it running, can we connect, what the status of the database

=cut

sub mysql {

    my ($r,$uri_elements) = @_;

    my $action = shift @{$uri_elements};
    return $MYSQL_ACTION{$action}($r);
}

=head2 connect

Check if we can connect to mysql

=cut

sub connect {

    my ($r) = @_;

    if (db_ping()) {
        return Apache2::Const::OK;
    } else {
        return  Apache2::Const::SERVER_ERROR;
    }
}

=head2 cluster

Check the status of the cluster

=cut

sub cluster {

    my ($r) = @_;

    my $query = db_query_execute(CLUSTERMGMT, $clustermgmt_statements, 'cluster_test_sql') || 0;
    if ($query eq '0') {
        return  Apache2::Const::SERVER_ERROR;
    }
    my ($val) = $query->fetchrow_array();
    if ($val eq '1') {
        return Apache2::Const::OK;
    } else {
        return  Apache2::Const::SERVER_ERROR;
    }
}

=head2 answer

ResponseHandler answer

=cut

sub answer {

    my ($r) = @_;

    return Apache2::Const::OK;
}

=head2 sync_cluster

RPC Client that send his configuration and adapt his own

=cut

sub sync_cluster {
    my $logger = get_logger;
    pf::config::cached::ReloadConfigs();

    my $client = pf::api::jsonrpcclient->new;

    my @all_members;
    my $priority;
    my @priority;

    my $int = $management_network->{'Tint'};
    my @members = split(',',$Config{"active_active"}{'members'});
    @members = grep { $_ ne $Config{"interface $int"}{'ip'} } @members;

    my @ints = uniq(@listen_ints,@dhcplistener_ints);

    if ( (defined $Config{"interface $int"}{'active_active_mysql_master'}) && ($Config{"interface $int"}{'ip'} eq $Config{"interface $int"}{'active_active_mysql_master'}) ) {
        $priority = '150';
    } else {
        $priority = $Config{"interface $int"}{'active_active_priority'} || 0;
    }

    my $cs = pf::ConfigStore::Interface->new();

    foreach my $interface ( @ints ) {
        my $dhcpd_master = 0;
        my $mysql_master = 0;
        my $cfg = $Config{"interface $interface"};
        if (isenabled($cfg->{'active_active_enabled'})) {
            my @all_members;
            for my $member (@members) {
                my %data = (
                    'ip' => $cfg->{'ip'},
                    'dhcpd' => $cfg->{'active_active_dhcpd_master'},
                    'activeip' => $cfg->{'active_active_ip'},
                    'mysql' => $cfg->{'active_active_mysql_master'} || 0,
                    'priority' => $priority,
                );
                $client->{'proto'} = 'https';
                $client->{'host'} = $member;
                my ($result) = $client->call('active_active',%data);
                if ($result){
                    $dhcpd_master = $result->{'dhcpd_master'} if ($result->{'dhcpd_master'} && defined($cfg->{'active_active_dhcpd_master'}));
                    $mysql_master = $result->{'mysql_master'} if ($result->{'mysql_master'} && defined($cfg->{'active_active_mysql_master'}));
                    push(@all_members , split(',',$result->{'active_active_members'}));
                    push(@all_members , $result->{'member_ip'});
                    $logger->error("There is more than one dhcpd master, fix that") if ($result->{'dhcpd_master'} && $Config{"interface $int"}{'active_active_dhcpd_master'});
                    push(@priority, $result->{'priority'});
                } else {
                    @all_members = grep { $_ ne $member } @all_members;
                }
            }
            push (@all_members,$cfg->{'ip'});
            my @uniq_members = uniq(@all_members);

            $cs->update($interface, { active_active_members => join(',',@uniq_members)});
            $cs->update($interface, { active_active_dhcpd_master => 0}) if ($dhcpd_master && defined($cfg->{'active_active_dhcpd_master'} ) && $cfg->{'type'} ne 'management');
            $cs->update($interface, { active_active_mysql_master => $mysql_master}) if ($mysql_master && defined($cfg->{'active_active_mysql_master'} ) &&  $cfg->{'type'} eq 'management');
            $cs->update($interface, { active_active_dhcpd_master => 1}) if (!$dhcpd_master && defined($cfg->{'active_active_dhcpd_master'} ) && $cfg->{'type'} ne 'management');
            $cs->update($interface, { active_active_mysql_master => $Config{"interface $int"}{ip}}) if (!$mysql_master && defined($cfg->{'active_active_mysql_master'} ) && $cfg->{'type'} eq 'management' );
            $cs->update($interface, { active_active_priority => $priority}) if ($priority eq 150);
            undef(@all_members);
        }
        if (grep { $_ eq $priority } @priority) {
            my $i = 100;
            while (grep { $_ eq $priority } @priority) {
                $priority = $i;
                $i++;
            }
            $cs->update($int, { active_active_priority => $priority});
        } else {
            $cs->update($int, { active_active_priority => $priority});
        }
        $cs->commit();
        #Reload configuration
        pf::config::cached::ReloadConfigs();
    }
}

=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2014 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and::or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;
