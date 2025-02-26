package PVE::Storage::Custom::SimplyblockPlugin;

use strict;
use warnings;

use feature 'fc';

use Data::Dumper;
use JSON;
use REST::Client;

use base qw(PVE::Storage::Plugin);

# Helpers
sub request {
    my ($scfg, $method, $path, $body) = @_;
    
    # TODO: Reuse client, place in $cache
    my $client = REST::Client->new({ follow => 1});
    $client->addHeader("Authorization", "$scfg->{cluster} $scfg->{secret}");
    $client->setHost($scfg->{entrypoint});

    if (defined $body) {
        $client->addHeader("Content-type", "application/json");
    }

    $client->request($method, $path, defined $body ? encode_json($body) : "");

    my $content = (fc($client->responseHeader('Content-type')) ne fc('application/json'))
        ? decode_json($client->responseContent())
        : { status => "true", results => "true" };

    my $code = $client->responseCode();
    if (($code < 200 or 300 <= $code) or ($content->{status} ne "true")) {
        my $msg = exists $content->{error} ? $content->{error} : "-";
        warn("Request failed: $code, $msg");
        return;
    }

    return $content ? $content->{"results"} : "true";
}

# Configuration
sub api {
	return 10;  # Only tested on this version so far.
}

sub type {
    return 'simplyblock';
}

sub plugindata {
    return {
        content => [
            { images => 1 },
            { images => 1 }
        ],
        format => [
            { raw => 1 },
            'raw'
        ],
    };
}

sub properties {
    return {
        entrypoint => {
            description => "Control plane server",
            type => 'string',
        },
        cluster => {
            description => "Cluster UUID",
            type => 'string',
        },
        secret => {
            description => "Cluster access token",
            type => 'string',
        },
    };
}

sub options {
    return {
        entrypoint => { optional => 0 },
        cluster => { optional => 0 },
        pool => { optional => 0 },
        secret => { optional => 0 },
    };
}

# Storage
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    request($scfg, "GET", "/cluster/$scfg->{cluster}") or die("Cluster not responding");

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub status {
    # (total, avail, used, active) in KiB
    return (0, 0, 0, 0);
}

sub map_volume {
    die "map_volume unimplemented";
}

sub unmap_volume {
    die "unmap_volume unimplemented";
}

sub parse_volname {
    die "parse_volname unimplemented";
}

sub filesystem_path {
    die "filesystem_path unimplemented";
}

sub create_base {
    die "create_base unimplemented";
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
	if  $name && $name !~ m/^vm-$vmid-/;

    request($scfg, "POST", "/lvol", {
        pool => $scfg->{pool},
        name => $name,
        size => $size * 1024,  # Size given in KiB
    }) or die("Failed to create image");

    return $name;
}

sub free_image {
    die "free_image unimplemented";
}

sub clone_image {
    die "clone_image unimplemented";
}

sub list_images {
    die "list_images unimplemented";
}

sub activate_volume {
    die "activate_volume unimplemented";
}

sub deactivate_volume {
    die "deactivate_volume unimplemented";
}

sub volume_resize {
    die "volume_resize unimplemented";
}

sub volume_snapshot {
    die "volume_snapshot unimplemented";
}

sub volume_snapshot_rollback {
    die "volume_snapshot_rollback unimplemented";
}

sub volume_snapshot_delete {
    die "volume_snapshot_delete unimplemented";
}

sub rename_volume {
    die "rename_volume unimplemented";
}

sub volume_has_feature {
    die "volume_has_feature unimplemented";
}

1;
