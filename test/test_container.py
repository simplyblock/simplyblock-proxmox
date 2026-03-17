from subprocess import check_call as cc, check_output as co, CalledProcessError

import pytest


def containers():
    status = co(['pct', 'list'], text=True)
    return {line.split()[0] for line in status.splitlines()[1:]}


@pytest.fixture(scope='module')
def container(storage, ct_template):
    if ct_template is None:
        pytest.skip("--ct-template not provided")
    id = 9000
    co([
        'pct', 'create', f'{id}',
        ct_template,
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

def test_linked_clone(container):
    clone_id = '9001'
    cc(['pct', 'clone', '--full=false', container, clone_id])
    cc(['pct', 'destroy', clone_id])

def test_template(container):
    template_id = '9001'
    cc(['pct', 'clone', container, template_id])
    cc(['pct', 'template', template_id])

    clone_id = '9002'
    cc(['pct', 'clone', template_id, clone_id])

    cc(['pct', 'destroy', clone_id])
    cc(['pct', 'destroy', template_id])
