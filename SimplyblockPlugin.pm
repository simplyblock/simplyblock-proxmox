package PVE::Storage::Custom::SimplyblockPlugin;

use strict;
use warnings;

use feature qw(fc);
use List::Util qw(max);

use Data::Dumper;
use JSON;
use REST::Client;
use Carp::Assert;

use PVE::Tools qw(run_command);

use base qw(PVE::Storage::Plugin);

# Helpers
my $MIN_LVOL_SIZE = 100 * (2 ** 20);
my $UUID_PATTERN = qr/[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}/;
my $NQN_PATTERN = qr/^[\d\w\.-]+:$UUID_PATTERN:lvol:(?<volume_id>$UUID_PATTERN)$/;
my $IP_PATTERN = qr/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/;
my $CONTROLLER_ADDRESS_PATTERN = qr/^traddr=(?<traddr>$IP_PATTERN),trsvcid=(?P<trsvcid>\d{1,5}),src_addr=(?P<src_addr>$IP_PATTERN)$/;
my $VOLUME_NAME_PATTERN = qr/^(?<name>vm-(?<vmid>\d+)-(?<suffix>\S+))$/;

sub _untaint {
    my ($value, $type) = @_;

    my %patterns = (
        num => qr/^(-?\d+)$/,
        ip     => qr/^((?:\d{1,3}\.){3}\d{1,3})$/,
        port   => qr/^(\d+)$/,
        nqn    => qr/^([\w\.\-\:]+)$/,
        path    => qr/^([\w\d\/]+)$/,
    );

    die "Unknown validation type: $type" unless exists $patterns{$type};

    if ($value =~ $patterns{$type}) {
        return $1;  # Return the untainted value
    } else {
        die "Invalid $type value: $value";
    }
}

sub _json_command {
    my $json = '';

    eval {
    run_command(@_,
        outfunc => sub { $json .= shift },
    );
    };

    return decode_json($json);
}

sub _match_pattern {
    my ($str, $pattern) = @_;

    if ($str =~ $pattern) {
        my %captures = %+;
        return \%captures;
    } else {
        return;
    }
};

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

sub _device_connections() {
    my $devices = _json_command(['nvme', 'list', '--output-format=json', '--verbose'])->{Devices};

    if (scalar(@$devices) == 0) {
        return {};
    }
    assert(scalar(@$devices) == 1);
    my $subsystems = $devices->[0]->{Subsystems};

    my $result = {};
    foreach my $subsystem (@$subsystems) {
        next if (scalar(@{$subsystem->{Namespaces}}) != 1);

        $result->{_match_pattern($subsystem->{SubsystemNQN}, $NQN_PATTERN)->{volume_id}} = {
            nqn => _untaint($subsystem->{SubsystemNQN}, 'nqn'),
            path => "/dev/" . _untaint($subsystem->{Namespaces}[0]->{NameSpace}, 'path'),
            controllers => [map {
                my $match = _match_pattern($_->{Address}, $CONTROLLER_ADDRESS_PATTERN);
                $_ = _untaint($match->{traddr}, 'ip') . ":" . _untaint($match->{trsvcid}, 'port');
            } @{$subsystem->{Controllers}}],
        };
    }
    return $result;
}

sub _lvol_by_name {
    my ($scfg, $volname) = @_;
    my $lvols = _request($scfg, "GET", "/lvol") or die("Failed to list volumes\n");
    my ($lvol) = grep { $volname eq $_->{lvol_name} } @$lvols;
    return ($lvol or die("Volume not found\n"));
}

sub _lvol_id_by_name {
    my ($scfg, $volname) = @_;
    return _lvol_by_name($scfg, $volname)->{id};
}

sub _lvols_by_pool {
    my ($scfg, $pool_name) = @_;
    return [
        grep { $_->{pool_name} eq $pool_name }
        @{_request($scfg, "GET", "/lvol")or die("Failed to list volumes\n")}
    ];
}

sub _pool_by_name {
    my ($scfg, $pool_name) = @_;
    my $pools = _request($scfg, "GET", "/pool") or die("Failed to list pools\n");
    my ($pool) = grep { $pool_name eq $_->{pool_name} } @$pools;
    return ($pool or die("Pool not found\n"));
}

sub _snapshot_by_name {
    my ($scfg, $snap_name) = @_;
    my $snapshots = _request($scfg, "GET", "/snapshot") or die("Failed to list snapshots\n");
    my ($snapshot) = grep { $snap_name eq $_->{snap_name} } @$snapshots;
    return ($snapshot->{id} or die("Snapshot not found\n"));
}

sub _connect_lvol {
    my ($scfg, $id) = @_;

    my $connections = _device_connections();
    my $connected_controllers = (exists $connections->{$id}) ?
            $connections->{$id}->{controllers} : [];
    my $connect_info = _request($scfg, "GET", "/lvol/connect/$id");

    # If first connection fails, secondary will not be connected.
    foreach my $info (@$connect_info) {
        my $ip = _untaint($info->{ip}, "ip");
        my $port = _untaint($info->{port}, "port");

        next if (grep {"$ip:$port" eq $_} @$connected_controllers);

        run_command([
            "nvme", "connect",
            "--reconnect-delay=" . ($scfg->{'reconnect-delay'} // _untaint($info->{'reconnect-delay'}, 'num')),
            "--ctrl-loss-tmo=" . ($scfg->{'control-loss-timeout'} // _untaint($info->{'ctrl-loss-tmo'}, 'num')),
            "--nr-io-queues=" . ($scfg->{'number-io-queues'} // _untaint($info->{'nr-io-queues'}, 'num')),
            "--keep-alive-tmo=" . ($scfg->{'keep-alive-timeout'} // _untaint($info->{'keep-alive-tmo'}, 'num')),
            "--transport=tcp",
            "--traddr=" . $ip,
            "--trsvcid=" . $port,
            "--nqn=" . _untaint($info->{nqn}, "nqn"),
        ]);
    }
}


sub _disconnect_lvol {
    my ($scfg, $id) = @_;
    my $device = _device_connections()->{$id};
    return if (!defined($device));

    run_command(["nvme", "disconnect", "-n",  $device->{nqn}], outfunc => sub{});
}

sub _delete_lvol {
    my ($scfg, $id) = @_;

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


sub _check_device_connections {
    my ($scfg) = @_;

    my $connections = _device_connections();
    foreach my $id (keys %$connections) {
        next if (scalar(@{scalar($connections->{$id}->{controllers})}) == 2);
        _connect_lvol($scfg, $id);
    }
}


# Configuration
sub api {
    return 11;
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
        'reconnect-delay' => {
            type => 'integer',
            minimum => 1,
            optional => 1,
        },
        'control-loss-timeout' => {
            type => 'integer',
            minimum => -1,
            optional => 1
        },
        'number-io-queues' => {
            type => 'integer',
            minimum => 1,
            optional => 1
        },
        'keep-alive-timeout' => {
            type => 'integer',
            minimum => -1,
            optional => 1
        },
        'max-rw-iops' => {
            type => 'integer',
            minimum => 0,
            default => 0,
            optional => 1
        },
        'max-rw-mbytes' => {
            type => 'integer',
            minimum => 0,
            default => 0,
            optional => 1
        },
        'max-r-mbytes' => {
            type => 'integer',
            minimum => 0,
            default => 0,
            optional => 1
        },
        'max-w-mbytes' => {
            type => 'integer',
            minimum => 0,
            default => 0,
            optional => 1
        },
    };
}

sub options {
    return {
        entrypoint => { optional => 0 },
        cluster => { optional => 0 },
        pool => { optional => 0 },
        secret => { optional => 0 },
        'reconnect-delay' => { optional => 1 },
        'control-loss-timeout' => { optional => 1 },
        'number-io-queues' => { optional => 1 },
        'keep-alive-timeout' => { optional => 1 },
        'max-rw-iops' => { optional => 1 },
        'max-rw-mbytes' => { optional => 1 },
        'max-r-mbytes' => { optional => 1 },
        'max-w-mbytes' => { optional => 1 },
        'shared' => { optional => 1 },
    };
}

# Storage
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $cluster = (_request($scfg, "GET", "/cluster/$scfg->{cluster}") or die("Cluster not responding"))->[0];
    if ($cluster->{status} ne "active") {
        die("Cluster not active");
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $cluster = _request($scfg, "GET", "/cluster/$scfg->{cluster}")->[0]
        or die("Cluster not responding");
    if ($cluster->{ha_type} eq 'ha') {
        _check_device_connections($scfg);
    }

    my $lvols = _lvols_by_pool($scfg, $scfg->{pool});
    my $used = 0;

    foreach (@$lvols) {
        $used += _request($scfg, "GET", "/lvol/capacity/$_->{uuid}")->{stats}[-1]{used} or die('Failed to access pool');
    }

    my $total = (_pool_by_name($scfg, $scfg->{pool})->{pool_max_size} or $cluster->{cluster_max_size});
    my $free = $total - $used;

    return ($total, $free, $used, 1);
}

sub parse_volname {
    my ( $class, $volname ) = @_;

    my $match = _match_pattern($volname, $VOLUME_NAME_PATTERN);
    if ($match) {
        return ('images', $match->{name}, $match->{vmid}, undef, undef, 0, 'raw');
    }

    die "unable to parse volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $id = _lvol_id_by_name($scfg, $volname);

    _connect_lvol($scfg, $id);

    my $path = _device_connections()->{$id}->{path};
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;
    return $volname;
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size_kib ) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, "raw", 0);

    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
        if  $name && $name !~ m/^vm-$vmid-/;

    my $id = _request($scfg, "POST", "/lvol", {
        pool => $scfg->{pool},
        name => $name,
        size => max($size_kib * 1024, $MIN_LVOL_SIZE),
        max_rw_iops => ${scfg}->{'max-rw-iops'},
        max_rw_mbytes => ${scfg}->{'max-rw-mbytes'},
        max_r_mbytes => ${scfg}->{'max-r-mbytes'},
        max_w_mbytes => ${scfg}->{'max-w-mbytes'},
    }) or die("Failed to create image");

    _connect_lvol($scfg, $id);

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $lvol = _lvol_by_name($scfg, $volname);
    _delete_lvol($scfg, $lvol->{id});

    # Delete associated snapshots
    my $snapshots = _request($scfg, "GET", "/snapshot") or die("Failed to list snapshots\n");
    foreach (@$snapshots) {
        next if ($_->{lvol}{id} ne $lvol->{id}) or ($_->{id} ne $lvol->{cloned_from_snap});

        _request($scfg, "DELETE", "/snapshot/$_->{id}") or die("Failed to delete snapshot\n");
    }
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $clone_vmid, $existing_snapshot) = @_;

    my $snapshot;
    if ($existing_snapshot) {
        $snapshot = $existing_snapshot;
    } else {
        $snapshot = "clone-snapshot-$clone_vmid";
        $class->volume_snapshot($scfg, $storeid, $volname, $snapshot);
    }
    my $snapshot_id = _snapshot_by_name($scfg, "$volname-$snapshot");

    my $match = _match_pattern($volname, $VOLUME_NAME_PATTERN);
    my $clone_volume_name = "vm-$clone_vmid-$match->{suffix}";
    _request($scfg, "POST", "/snapshot/clone", {
        snapshot_id => $snapshot_id,
        clone_name => $clone_volume_name
    }) or die("Failed to clone snapshot");

    if (!$existing_snapshot) {
        $class->volume_snapshot_delete($scfg, $storeid, $volname, $snapshot);
    }

    return $clone_volume_name;
}

sub list_images {
    my ($class, $storeid, $scfg) = @_;

    my $lvols = _lvols_by_pool($scfg, $scfg->{pool});
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
        size => max($size, $MIN_LVOL_SIZE)
    }) or die("Failed to resize image");
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $id = _lvol_id_by_name($scfg, $volname);

    _request($scfg, "POST", "/snapshot", {
        snapshot_name => "$volname-$snap",
        lvol_id => $id
    }) or die("Failed to create snapshot");
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    # delete $volname
    my $id = _lvol_id_by_name($scfg, $volname);
    _delete_lvol($scfg, $id);

    # clone $snap
    my $snap_id = _snapshot_by_name($scfg, "$volname-$snap");
    my $new_id = _request($scfg, "POST", "/snapshot/clone", {
        snapshot_id => $snap_id,
        clone_name => $volname
    }) or die("Failed to restore snapshot");

    _connect_lvol($scfg, $new_id);
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $snap_id = _snapshot_by_name($scfg, "$volname-$snap");
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
        clone => 1,
        copy => 1,
        snapshot => 1,
        sparseinit => 1,
        template => 1,
    }->{$feature});

    return 0;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    _connect_lvol($scfg, _lvol_id_by_name($scfg, $volname));
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    _disconnect_lvol($scfg, _lvol_id_by_name($scfg, $volname));
}

1;
