from subprocess import check_output as co
from pathlib import Path

import pytest


def storages():
    status = co(['pvesm', 'status'], text=True)
    return {line.split()[0] for line in status.splitlines()[1:]}


def volumes(storage):
    status = co(['pvesm', 'list', storage], text=True)
    return {line.split()[0] for line in status.splitlines()[1:]}


@pytest.fixture
def image(storage):
    vmid = 999
    name = f'vm-{vmid}-0'
    co(['pvesm', 'alloc', storage, f'{vmid}', name, '1G'])
    yield name
    co(['pvesm', 'free', f'{storage}:{name}'])


def test_storage_creation(storage):
    status = co(['pvesm', 'status'], text=True)
    assert storage in storages()


def test_image_allocation(storage, image):
    status = co(['pvesm', 'list', storage], text=True)
    assert f'{storage}:{image}' in volumes(storage)


def test_image_path(storage, image):
    path = co(['pvesm', 'path', f'{storage}:{image}'], text=True).strip()
    assert Path(path).is_block_device()
    assert path in [
        line.split()[0]
        for line
        in co(['nvme', 'list'], text=True).splitlines()[2:]
    ]
