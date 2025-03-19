from subprocess import check_output as co

import pytest


def pytest_addoption(parser):
    parser.addoption("--entrypoint", action="store", required=True)
    parser.addoption("--cluster", action="store", required=True)
    parser.addoption("--secret", action="store", required=True)
    parser.addoption("--pool", action="store", required=True)


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
