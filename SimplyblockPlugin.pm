package PVE::Storage::Custom::SimplyblockPlugin;

use strict;
use warnings;

use feature qw(fc);

use Data::Dumper;
use JSON;
use REST::Client;

use PVE::Tools qw(run_command);

use base qw(PVE::Storage::Plugin);

# Helpers
sub _untaint {
    my ($value, $type) = @_;

    my %patterns = (
        num => qr/^(-?\d+)$/,
        ip     => qr/^((?:\d{1,3}\.){3}\d{1,3})$/,
        port   => qr/^(\d+)$/,
        nqn    => qr/^([\w\.\-\:]+)$/
    );

    die "Unknown validation type: $type" unless exists $patterns{$type};

    if ($value =~ $patterns{$type}) {
        return $1;  # Return the untainted value
    } else {
        die "Invalid $type value: $value";
    }
}

sub _request {
    my ($scfg, $method, $path, $body, $expect_failure) = @_;

    $expect_failure //= 0;

    # TODO: Reuse client, place in $cache
    my $client = REST::Client->new({ follow => 1});
    $client->addHeader("Authorization", "$scfg->{cluster} $scfg->{secret}");
    $client->setHost($scfg->{entrypoint});

    if (defined $body) {
        $client->addHeader("Content-type", "application/json");
    }

    $client->request($method, $path, defined $body ? encode_json($body) : "");

    my $code = $client->responseCode();
    my $content = (fc($client->responseHeader('Content-type')) eq fc('application/json'))
        ? decode_json($client->responseContent())
        : ((200 <= $code or $code < 300)  # Ensure we always have response content
            ? { status => 1, results => 1 }
            : { status => 0 }
        );

    if (($code < 200 or 300 <= $code) or (not $content->{status})) {
        my $msg = exists $content->{error} ? $content->{error} : "-";

        if ($expect_failure) {
            return $msg;
        }

        warn("Request failed: $code, $msg");
        return;
    }

    return $content->{"results"};
}

sub _list_nvme {
    my $json = '';

    eval {
    run_command(['nvme', 'list', '--output=json'],
        outfunc => sub { $json .= shift },
    );
    };

    return decode_json($json);
}

sub _lvol_by_name {
    my ($scfg, $volname) = @_;
    my $lvols = _request($scfg, "GET", "/lvol") or die("Failed to list volumes\n");
    my ($lvol) = grep { $volname eq $_->{lvol_name} } @$lvols;
    return ($lvol or die("Volume not found\n"));
};

sub _lvol_id_by_name {
    my ($scfg, $volname) = @_;
    return _lvol_by_name($scfg, $volname)->{id};
};

sub _snapshot_by_name {
    my ($scfg, $snap_name) = @_;
    my $snapshots = _request($scfg, "GET", "/snapshot") or die("Failed to list snapshots\n");
    my ($snapshot) = grep { $snap_name eq $_->{snap_name} } @$snapshots;
    return ($snapshot->{id} or die("Snapshot not found\n"));
}

sub _connect_lvol {
    my ($scfg, $id) = @_;
    my $connect_info = _request($scfg, "GET", "/lvol/connect/$id");

    foreach (@$connect_info) {
        run_command([
            "nvme", "connect",
            "--reconnect-delay=" . _untaint($_->{"reconnect-delay"}, "num"),
            "--ctrl-loss-tmo=" . _untaint($_->{"ctrl-loss-tmo"}, "num"),
            "--nr-io-queues=" . _untaint($_->{"nr-io-queues"}, "num"),
            "--transport=tcp",
            "--traddr=" . _untaint($_->{ip}, "ip"),
            "--trsvcid=" . _untaint($_->{port}, "port"),
            "--nqn=" . _untaint($_->{nqn}, "nqn"),
        ]);
    }
}


sub _disconnect_lvol {
    my ($scfg, $id) = @_;
    my $info = _request($scfg, "GET", "/lvol/$id")->[0];

    run_command("nvme disconnect -n " . _untaint($info->{nqn}, "nqn"));
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
            { images => 1, rootdir => 1 },
            { images => 1, rootdir => 1 }
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

    _request($scfg, "GET", "/cluster/$scfg->{cluster}") or die("Cluster not responding");
    my $lvols = _request($scfg, "GET", "/lvol") or die("Failed to list volumes\n");

    my $devices = _list_nvme()->{Devices};

    foreach (@$lvols) {
        my $lvol = $_;

        next if $lvol->{lvol_name} !~ m/^vm-(\d+)-/;
        next if $lvol->{status} ne "online";

        # Skip already connected
        next if grep { $lvol->{id} eq $_->{ModelNumber} } @$devices;

        _connect_lvol($scfg, $lvol->{id});
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # TODO: disconnect volumes?

    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $capacity = _request($scfg, "GET", "/cluster/capacity/$scfg->{cluster}")->[0]
        or die("Cluster not responding");

    return ($capacity->{size_total}, $capacity->{size_free}, $capacity->{size_used}, 1);
}

sub parse_volname {
    my ( $class, $volname ) = @_;

    if ($volname =~ m/^(vm-(\d+)-\S+)$/) {
        return ('images', $1, $2, undef, undef, 0, 'raw');
    }

    die "unable to parse volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $id = _lvol_id_by_name($scfg, $volname);
    my $devices = _list_nvme()->{Devices};
    my ($device) = grep { $id eq $_->{ModelNumber} } @$devices;
    my $path = $device->{DevicePath};
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    die "create_base unimplemented";
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, "raw", 0);

    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
        if  $name && $name !~ m/^vm-$vmid-/;

    my $id = _request($scfg, "POST", "/lvol", {
        pool => $scfg->{pool},
        name => $name,
        size => $size * 1024,  # Size given in KiB
    }) or die("Failed to create image");

    _connect_lvol($scfg, $id);

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $id = _lvol_by_name($scfg, $volname);
    _disconnect_lvol($scfg, $id);
    _request($scfg, "DELETE", "/lvol/$id");

    # Await deletion
    for (my $i = 0; $i < 120; $i += 1) {
        my $ret = _request($scfg, "GET", "/lvol/$id", undef, 1);

        if (ref($ret) eq 'ARRAY' && exists $ret->[0]{status} && ($ret->[0]{status} eq "in_deletion")) {
            sleep(1);
        } elsif ($ret eq "LVol not found: $id") {
            return undef;  # Success
        } else {
            die("Failed to await LVol deletion");
        }
    }
    die ("Timeout waiting for LVol deletion");
}

sub clone_image {
    die "clone_image unimplemented";
}

sub list_images {
    my ($class, $storeid, $scfg) = @_;

    my $lvols = _request($scfg, "GET", "/lvol") or die("Failed to list volumes\n");

    my $res = [];

    foreach (@$lvols) {
	    next if $_->{lvol_name} !~ m/^vm-(\d+)-/;

        push @$res, {
            volid => "$storeid:$_->{lvol_name}",
            format => 'raw',
            size => $_->{size},
            vmid => $1,
	    };
    }

    return $res;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    my $id = _lvol_id_by_name($scfg, $volname);

    _request($scfg, "PUT", "/lvol/resize/$id", {
        size => $size
    }) or die("Failed to resize image");
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $id = _lvol_id_by_name($scfg, $volname);

    _request($scfg, "POST", "/snapshot", {
        snapshot_name => $snap,
        lvol_id => $id
    }) or die("Failed to resize image");
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    # delete $volname
    $class->free_image($storeid, $scfg, $volname, 0);

    # clone $snap
    my $snap_id = _snapshot_by_name($scfg, $snap);
    my $id = _request($scfg, "POST", "/snapshot/clone", {
        snapshot_id => $snap_id,
        clone_name => $volname
    }) or die("Failed to restore snapshot");

    _connect_lvol($scfg, $id);
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $snap_id = _snapshot_by_name($scfg, $snap);
    _request($scfg, "DELETE", "/snapshot/$snap_id") or die ("Failed to delete snapshot");
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my $id = _lvol_id_by_name($scfg, $source_volname);

    $target_volname = $class->find_free_diskname($storeid, $scfg, $target_vmid, "raw")
        if !$target_volname;

    _request($scfg, "PUT", "/lvol/resize/$id", {
        name => $target_volname
    }) or die("Failed to rename image");
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = @_;

    return 1 if exists({
        snapshot => 1,
        sparseinit => 1,
    }->{$feature});

    die "unchecked feature '$feature'";
}

1;
