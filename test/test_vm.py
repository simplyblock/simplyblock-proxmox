from subprocess import check_call as cc, check_output as co, check_call as cc, STDOUT

import pytest


def vms():
    status = co(['qm', 'list'], text=True)
    return {line.split()[0] for line in status.splitlines()[1:]}


@pytest.fixture(scope='module')
def vm(storage):
    id = 9000
    image = '/root/debian-12-generic-amd64.qcow2'
    co([
        'qm', 'create', f'{id}',
        '--memory', '1024',
        '--scsihw', 'virtio-scsi-pci',
        '--scsi0', f'{storage}:0,import-from={image}',
    ])
    yield f'{id}'
    co(['qm', 'destroy', f'{id}'])


@pytest.fixture(scope='module')
def snapshot(vm):
    co(['qm', 'snapshot', vm, 'snap1'])
    yield 'snap1'
    co(['qm', 'delsnapshot', vm, 'snap1'])


def test_vm(vm):
    print(vm, vms())
    assert vm in vms()


def test_snapshot(vm, snapshot):
    assert snapshot in co(['qm', 'listsnapshot', vm], text=True)


def test_rollback(vm, snapshot):
    co(['qm', 'rollback', vm, snapshot])


def test_resize_grow(vm):
    co(['qm', 'resize', vm, 'scsi0', '4G'])


def test_resize_shrink(vm):
    output = co(['qm', 'resize', vm, 'scsi0', '2G'], stderr=STDOUT, text=True).strip()
    assert output == "shrinking disks is not supported"

def test_full_clone(vm):
    clone_id = '9001'
    cc(['qm', 'clone', vm, clone_id])
    cc(['qm', 'destroy', clone_id])

def test_linked_clone(vm):
    clone_id = '9001'
    cc(['qm', 'clone', '--full=false', vm, clone_id])
    cc(['qm', 'destroy', clone_id])

def test_template(vm):
    template_id = '9001'
    cc(['qm', 'clone', vm, template_id])
    cc(['qm', 'template', template_id])

    clone_id = '9002'
    cc(['qm', 'clone', template_id, clone_id])

    cc(['qm', 'destroy', clone_id])
    cc(['qm', 'destroy', template_id])
