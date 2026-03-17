from subprocess import check_output as co

import pytest


def pytest_addoption(parser):
    parser.addoption("--entrypoint", action="store", required=True)
    parser.addoption("--cluster", action="store", required=True)
    parser.addoption("--secret", action="store", required=True)
    parser.addoption("--pool", action="store", required=True)
    parser.addoption("--vm-image", action="store", default=None,
                     help="Path to a VM disk image (e.g. /root/debian.qcow2); "
                          "VM tests are skipped when omitted")
    parser.addoption("--ct-template", action="store", default=None,
                     help="Proxmox container template volid "
                          "(e.g. local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst); "
                          "container tests are skipped when omitted")


@pytest.fixture(scope='session')
def storage(request):
    name  = 'sb-test'

    co([
        'pvesm', 'add',
        'simplyblock', name,
        '--entrypoint=' + request.config.option.entrypoint,
        '--cluster=' + request.config.option.cluster,
        '--pool=' + request.config.option.pool,
        '--secret=' + request.config.option.secret,
    ])
    yield name
    co(['pvesm', 'remove', name])


@pytest.fixture(scope='session')
def vm_image(request):
    return request.config.option.vm_image


@pytest.fixture(scope='session')
def ct_template(request):
    return request.config.option.ct_template
