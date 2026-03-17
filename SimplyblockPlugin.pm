package PVE::Storage::Custom::SimplyblockPlugin;

use strict;
use warnings;

use feature qw(fc);
use List::Util qw(max);

use Data::Dumper;
use JSON;
use REST::Client;
use Carp::Assert;
use Params::Validate qw(:all);

use PVE::Tools qw(run_command);

use base qw(PVE::Storage::Plugin);

# Helpers
my $MIN_LVOL_SIZE = 100 * (2 ** 20);
my $UUID_PATTERN = qr/[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}/;
my $NQN_PATTERN = qr/^[\d\w\.-]+:$UUID_PATTERN:lvol:(?<volume_id>$UUID_PATTERN)$/;
my $IP_PATTERN = qr/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/;
my $CONTROLLER_ADDRESS_PATTERN = qr/^traddr=(?<traddr>$IP_PATTERN),trsvcid=(?P<trsvcid>\d{1,5})(,src_addr=(?P<src_addr>$IP_PATTERN))?$/;
my $VOLUME_NAME_PATTERN = qr/^(?<name>vm-(?<vmid>\d+)-(?<suffix>\S+))$/;

sub _one {
    my @results = @_;
    if (@results == 0) {
        die "No results found when exactly one was expected";
    } elsif (@results > 1) {
        die "Multiple results found when exactly one was expected: " . scalar(@results);
    }
    return $results[0];
}

sub _one_or_none {
    my @results = @_;
    if (@results == 0) {
        return undef;
    } elsif (@results > 1) {
        die "Multiple results found when exactly one was expected: " . scalar(@results);
    }
    return $results[0];
}

sub _untaint {
    my ($value, $type) = validate_pos(@_, 1, {default => 'any'});

    my %patterns = (
        num => qr/^(-?\d+)$/,
        ip     => qr/^((?:\d{1,3}\.){3}\d{1,3})$/,
        port   => qr/^(\d+)$/,
        nqn    => qr/^([\w\.\-\:]+)$/,
        path   => qr/^([\w\d\/]+)$/,
        any   => qr/^(.*)$/,
    );

    die "Unknown validation type: $type" unless exists $patterns{$type};

    if ($value =~ $patterns{$type}) {
        return $1;  # Return the untainted value
    } else {
        die "Invalid $type value: $value";
    }
}

sub _untaint_recursive {
    my ($data) = @_;

    return undef unless defined $data;

    if (ref $data eq 'HASH') {
        my $clean = {};
        for my $key (keys %$data) {
            my $clean_key = _untaint($key);
            $clean->{$clean_key} = _untaint_recursive($data->{$key});
        }
        return $clean;
    } elsif (ref $data eq 'ARRAY') {
        return [ map { _untaint_recursive($_) } @$data ];
    } else {
        return _untaint($data);
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
    my ($str, $pattern) = validate_pos(@_, 1, 1);

    if ($str =~ $pattern) {
        my %captures = %+;
        return \%captures;
    } else {
        return;
    }
};

sub _request {
    my ($scfg, $method, $path, $body, $expect_failure) = validate_pos(@_, 1, 1, 1, 0, {default => 0});

    my $client = REST::Client->new();
    $client->addHeader("Authorization", "Bearer $scfg->{secret}");

    my $entrypoint = $scfg->{entrypoint};
    $entrypoint =~ s{/+$}{};
    $entrypoint = "http://$entrypoint" unless $entrypoint =~ m{^https?://};
    $client->setHost($entrypoint);

    $client->addHeader("Content-type", "application/json") if defined $body;
    my $encoded_body = defined $body ? encode_json($body) : "";

    (my $request_path = $path) =~ s{^/*}{/api/v2/};

    for (1..5) {
        $client->request($method, $request_path, $encoded_body);
        my $code = $client->responseCode();
        last unless $code >= 301 && $code <= 308 && $code != 304;

        my $location = $client->responseHeader('Location');
        last unless defined $location;

        if ($location =~ m{^https?://}) {
            die "Redirect to foreign host: $location\n"
                unless $location =~ m{^\Q$entrypoint\E(/|$)};
            $location =~ s{^\Q$entrypoint\E}{};
        }
        $location =~ s{^/*}{/};
        $request_path = $location;
    }

    my $code = $client->responseCode();

    if ($code >= 200 && $code < 300) {
        my $body = $client->responseContent();
        return 1 unless defined $body && length $body;
        return _untaint_recursive(decode_json($body));
    }

    my $raw     = $client->responseContent();
    my $content = eval { decode_json($raw) } // {};
    my $detail = $content->{detail};
    my $msg = (ref($detail) eq 'ARRAY' ? $detail->[0]{msg} : $detail)
           // $content->{error} // "-";
    return $msg if $expect_failure;
    warn "Request failed: $code, $msg";
    warn "Validation errors: " . encode_json($content) if $code == 422;
    return;
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

sub _pool_by_name {
    my ($scfg, $pool_name, $cache) = validate_pos(@_, 1, 1, 0);

    my $key = "pool:$pool_name";
    return $cache->{$key} if defined($cache) && exists($cache->{$key});

    my $pools = _request($scfg, "GET", "/clusters/$scfg->{cluster}/storage-pools/")
        or die "Failed to list storage pools\n";
    my $pool = _one(grep { $pool_name eq $_->{name} } @$pools);

    $cache->{$key} = $pool if defined($cache);
    return $pool;
}

# Issue a request scoped to the configured storage pool.
# $subpath is appended to /clusters/{cluster}/storage-pools/{pool_id}/.
sub _pool_request {
    my ($scfg, $cache, $method, $subpath, $body, $expect_failure) =
        validate_pos(@_, 1, 0, 1, {default => ""}, 0, {default => 0});

    my $pool_id = _pool_by_name($scfg, $scfg->{pool}, $cache)->{id};
    my $path = "/clusters/$scfg->{cluster}/storage-pools/$pool_id/";
    $path .= $subpath if length $subpath;
    return _request($scfg, $method, $path, $body, $expect_failure);
}

sub _cluster {
    my ($scfg) = validate_pos(@_, 1);
    return _request($scfg, "GET", "/clusters/$scfg->{cluster}/")
        || die "Cluster not responding\n";
}

sub _pool {
    my ($scfg, $cache) = validate_pos(@_, 1, 0);
    return _pool_request($scfg, $cache, "GET")
        || die "Failed to get storage pool\n";
}

sub _lvols {
    my ($scfg, $cache) = validate_pos(@_, 1, 0);
    return _pool_request($scfg, $cache, "GET", "volumes/")
        || die "Failed to list volumes\n";
}

sub _lvol_by_name {
    my ($scfg, $volname, $fail_missing, $cache) = validate_pos(@_, 1, 1, {default => 1}, 0);
    my $lvol = _one_or_none(grep { $volname eq $_->{name} } @{_lvols($scfg, $cache)});
    if ($fail_missing && !defined($lvol)) {
        die("Volume not found\n");
    }
    return $lvol;
}

sub _lvol_id_by_name {
    my ($scfg, $volname, $fail_missing, $cache) = validate_pos(@_, 1, 1, {default => 1}, 0);
    my $lvol = _lvol_by_name($scfg, $volname, $fail_missing, $cache);
    return defined($lvol) ? $lvol->{id} : undef;
}

sub _vol_id_by_name {
    my ($scfg, $volname, $cache) = validate_pos(@_, 1, 1, 0);
    my $lvol = _one(grep { $volname eq $_->{name} } @{_lvols($scfg, $cache)});
    return $lvol->{id};
}

sub _snapshot_by_name {
    my ($scfg, $snap_name, $cache) = validate_pos(@_, 1, 1, 0);
    my $snapshots = _pool_request($scfg, $cache, "GET", "snapshots/")
        or die "Failed to list snapshots\n";
    my ($snapshot) = grep { $snap_name eq $_->{name} } @$snapshots;
    return ($snapshot->{id} or die("Snapshot not found\n"));
}

sub _connect_lvol {
    my ($scfg, $id, $cache) = validate_pos(@_, 1, 1, 0);

    my $connections = _device_connections();
    my $connected_controllers = (exists $connections->{$id}) ?
            $connections->{$id}->{controllers} : [];
    my $connect_info = _pool_request($scfg, $cache, "GET", "volumes/$id/connect");

    # If first connection fails, secondary will not be connected.
    foreach my $info (@$connect_info) {
        my $ip = $info->{ip};
        my $port = $info->{port};

        next if (grep {"$ip:$port" eq $_} @$connected_controllers);

        run_command([
            "nvme", "connect",
            "--reconnect-delay=" . ($scfg->{'reconnect-delay'} // $info->{'reconnect-delay'}),
            "--ctrl-loss-tmo=" . ($scfg->{'control-loss-timeout'} // $info->{'ctrl-loss-tmo'}),
            "--nr-io-queues=" . ($scfg->{'number-io-queues'} // $info->{'nr-io-queues'}),
            "--keep-alive-tmo=" . ($scfg->{'keep-alive-timeout'} // $info->{'keep-alive-tmo'}),
            "--transport=tcp",
            "--traddr=" . $ip,
            "--trsvcid=" . $port,
            "--nqn=" . $info->{nqn},
        ]);
    }
}


sub _disconnect_lvol {
    my ($scfg, $id) = validate_pos(@_, 1, 1);
    my $device = _device_connections()->{$id};
    return if (!defined($device));

    run_command(["nvme", "disconnect", "-n",  $device->{nqn}], outfunc => sub{});
}

sub _delete_lvol {
    my ($scfg, $id, $cache) = validate_pos(@_, 1, 1, 0);

    _disconnect_lvol($scfg, $id);
    _pool_request($scfg, $cache, "DELETE", "volumes/$id/");

    # Await deletion
    for (my $i = 0; $i < 120; $i += 1) {
        my $ret = _pool_request($scfg, $cache, "GET", "volumes/$id/", undef, 1);

        if (ref($ret) eq 'HASH' && $ret->{status} eq "in_deletion") {
            sleep(1);
        } elsif (!ref($ret)) {
            return undef;  # Got error string — volume gone, success
        } else {
            die("Failed to await LVol deletion");
        }
    }
    die ("Timeout waiting for LVol deletion");
}


sub _check_device_connections {
    my ($scfg, $cache) = validate_pos(@_, 1, 0);

    my $connections = _device_connections();
    foreach my $id (keys %$connections) {
        next if (scalar(@{scalar($connections->{$id}->{controllers})}) == 2);
        _connect_lvol($scfg, $id, $cache);
    }
}


# Configuration
sub api {
    my $min_tested_apiver = 11;
    my $max_tested_apiver = 13;

    my $apiver = PVE::Storage::APIVER;

    if ($apiver >= $min_tested_apiver && $apiver <= $max_tested_apiver) {
        return $apiver;
    }

    return $max_tested_apiver;
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
    my ($class, $storeid, $scfg, $cache) = validate_pos(@_, 1, 1, 1, 1);

    my $cluster = _cluster($scfg);
    if ($cluster->{status} ne "active") {
        die("Cluster not active");
    }

    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = validate_pos(@_, 1, 1, 1, 1);

    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = validate_pos(@_, 1, 1, 1, 1);

    my $cluster = _cluster($scfg);
    my $active = $cluster->{status} eq 'active';

    if ($active && $cluster->{ha_type} eq 'ha') {
        _check_device_connections($scfg, $cache);
    }

    my $lvols = _lvols($scfg, $cache);
    my $used  = 0;

    foreach (@$lvols) {
        $used += _pool_request($scfg, $cache, "GET", "volumes/$_->{id}/capacity")
            ->{stats}[-1]{used} // die 'Failed to access pool';
    }

    my $pool  = _pool($scfg, $cache);
    my $total = $pool->{max_size};
    my $free  = $total - $used;

    return ($total, $free, $used, $active);
}

sub parse_volname {
    my ( $class, $volname ) = validate_pos(@_, 1, 1);

    my $match = _match_pattern($volname, $VOLUME_NAME_PATTERN);
    if ($match) {
        return ('images', $match->{name}, $match->{vmid}, undef, undef, 0, 'raw');
    }

    die "unable to parse volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = validate_pos(@_, 1, 1, 1, 0);
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $id = _lvol_id_by_name($scfg, $volname, 0);
    if (!defined($id)) {
        return undef;
    }

    _connect_lvol($scfg, $id);

    my $path = _device_connections()->{$id}->{path};
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = validate_pos(@_, 1, 1, 1, 1);
    return $volname;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size_kib) = validate_pos(@_, 1, 1, 1, 1, 1, 0, 1);

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    $name //= $class->find_free_diskname($storeid, $scfg, $vmid, "raw", 0);

    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
        if  $name && $name !~ m/^vm-$vmid-/;

    my %body = (
        name => $name,
        size => max($size_kib * 1024, $MIN_LVOL_SIZE),
    );
    for my $field (qw(max_rw_iops max_rw_mbytes max_r_mbytes max_w_mbytes)) {
        (my $cfg_key = $field) =~ s/_/-/g;
        $body{$field} = int($scfg->{$cfg_key}) if defined $scfg->{$cfg_key};
    }

    _pool_request($scfg, undef, "POST", "volumes/", \%body)
        or die "Failed to create image\n";

    my $id = _vol_id_by_name($scfg, $name);
    _connect_lvol($scfg, $id);

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $file_format) = validate_pos(@_, 1, 1, 1, 1, 1, 0);

    my $lvol = _lvol_by_name($scfg, $volname, 0);
    if (defined($lvol)) {
        _delete_lvol($scfg, $lvol->{id});
    } else {
        print("Volume does not exist\n");
        return;
    }

    # Delete associated snapshots
    my $snapshots = _pool_request($scfg, undef, "GET", "snapshots/")
        or die "Failed to list snapshots\n";
    foreach (@$snapshots) {
        next if ($_->{lvol}{id} ne $lvol->{id}) or ($_->{id} ne $lvol->{cloned_from_snap});

        _pool_request($scfg, undef, "DELETE", "snapshots/$_->{id}/")
            or die "Failed to delete snapshot\n";
    }
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $clone_vmid, $existing_snapshot) = validate_pos(@_, 1, 1, 1, 1, 1, 0);

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

    _pool_request($scfg, undef, "POST", "volumes/", {
        name        => $clone_volume_name,
        snapshot_id => $snapshot_id,
    }) or die "Failed to clone snapshot\n";

    if (!$existing_snapshot) {
        $class->volume_snapshot_delete($scfg, $storeid, $volname, $snapshot);
    }

    return $clone_volume_name;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = validate_pos(@_, 1, 1, 1, 0, 0, 0);

    my $lvols = _lvols($scfg, $cache);
    my $res = [];

    foreach (@$lvols) {
        next if $_->{name} !~ m/^vm-(\d+)-/;
        my $volid = "$storeid:$_->{name}";
        if (defined($vollist)) {
            next if !(grep { $_ eq $volid } @$vollist);
        } else {
            next if (defined $vmid) && ($1 ne $vmid);
        }

        push @$res, {
            volid => $volid,
            format => 'raw',
            size => $_->{size},
            vmid => $1,
        };
    }

    return $res;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = validate_pos(@_, 1, 1, 1, 1, 1, 1);

    my $id = _lvol_id_by_name($scfg, $volname);
    _pool_request($scfg, undef, "PUT", "volumes/$id/", {
        size => max($size, $MIN_LVOL_SIZE),
    }) or die "Failed to resize image\n";
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = validate_pos(@_, 1, 1, 1, 1, 1);

    my $id = _lvol_id_by_name($scfg, $volname);
    _pool_request($scfg, undef, "POST", "volumes/$id/snapshots", {
        name => "$volname-$snap",
    }) or die "Failed to create snapshot\n";
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = validate_pos(@_, 1, 1, 1, 1, 1);

    # delete $volname
    my $id = _lvol_id_by_name($scfg, $volname, 0);
    if (!defined($id)) {
        print("Volume does not exist\n");
        return;
    }
    _delete_lvol($scfg, $id);

    # clone $snap
    my $snap_id = _snapshot_by_name($scfg, "$volname-$snap");
    _pool_request($scfg, undef, "POST", "volumes/", {
        snapshot_id => $snap_id,
        name        => $volname,
    }) or die "Failed to restore snapshot\n";

    my $new_id = _vol_id_by_name($scfg, $volname);
    _connect_lvol($scfg, $new_id);
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = validate_pos(@_, 1, 1, 1, 1, 1, 0);

    my $snap_id = _snapshot_by_name($scfg, "$volname-$snap");
    _pool_request($scfg, undef, "DELETE", "snapshots/$snap_id/")
        or die "Failed to delete snapshot\n";
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = validate_pos(@_, 1, 1, 1, 1, 1, 1);

    my $id = _lvol_id_by_name($scfg, $source_volname);

    $target_volname = $class->find_free_diskname($storeid, $scfg, $target_vmid, "raw")
        if !$target_volname;

    _pool_request($scfg, undef, "PUT", "volumes/$id/", {
        name => $target_volname,
    }) or die "Failed to rename image\n";
}

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = validate_pos(@_, 1, 1, 1, 1, 0, 0, 0);
    return () if defined($snapshot) || defined($base_snapshot) || $with_snapshots;
    return ('raw+size');
}

sub volume_import_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = validate_pos(@_, 1, 1, 1, 1, 0, 0, 0);
    return () if defined($base_snapshot) || $with_snapshots;
    return ('raw+size');
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) = validate_pos(@_, 1, 1, 1, 1, 1, 1, 1, 1);

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
    my ($class, $storeid, $scfg, $volname, $snapname, $cache, $hints) = validate_pos(@_, 1, 1, 1, 1, 0, 0, 0);

    _connect_lvol($scfg, _lvol_id_by_name($scfg, $volname, 1, $cache), $cache);
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = validate_pos(@_, 1, 1, 1, 1, 0, 0);

    _disconnect_lvol($scfg, _lvol_id_by_name($scfg, $volname, 1, $cache));
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = validate_pos(@_, 1, 1, 1, 1, 0);
    return _lvol_by_name($scfg, $volname)->{size};
}

1;
