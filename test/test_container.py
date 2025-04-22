from subprocess import check_call as cc, check_output as co, CalledProcessError

import pytest


def containers():
    status = co(['pct', 'list'], text=True)
    return {line.split()[0] for line in status.splitlines()[1:]}


@pytest.fixture(scope='module')
def container(storage):
    id = 9000
    image = 'local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst'
    co([
        'pct', 'create', f'{id}',
        image,
        '--rootfs', f'{storage}:3',
        '--hostname', 'LXC-9000',
        '--memory', '1024',
        '--cores', '1',
    ])
    yield f'{id}'
    co(['pct', 'destroy', f'{id}'])


@pytest.fixture(scope='module')
def snapshot(container):
    co(['pct', 'snapshot', container, 'snap1'])
    yield 'snap1'
    co(['pct', 'delsnapshot', container, 'snap1'])


def test_container(container):
    assert container in containers()


def test_snapshot(container, snapshot):
    assert snapshot in co(['pct', 'listsnapshot', container], text=True)


def test_rollback(container, snapshot):
    co(['pct', 'rollback', container, snapshot])


def test_resize_grow(container):
    co(['pct', 'resize', container, 'rootfs', '4G'])


def test_resize_shrink(container):
    with pytest.raises(CalledProcessError):
        co(['pct', 'resize', container, 'rootfs', '2G'])

def test_full_clone(container):
    clone_id = '9001'
    cc(['pct', 'clone', container, clone_id])
    cc(['pct', 'destroy', clone_id])
