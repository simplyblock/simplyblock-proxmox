# Simplyblock Proxmox integration

**High-performance NVMe-first software-defined block storage for Proxmox VE**

[![Docs](https://img.shields.io/badge/Docs-simplyblock-green)](https://docs.simplyblock.io/latest/deployments/proxmox/) [![Issues](https://img.shields.io/github/issues/simplyblock/simplyblock-proxmox)](https://github.com/simplyblock/simplyblock-proxmox/issues)

![](assets/simplyblock-logo.svg)

---

## 🚀 Overview

`simplyblock-proxmox` is the official **simplyblock storage plugin for Proxmox VE**. 

It enables **enterprise-grade, NVMe/TCP-powered block storage** directly inside Proxmox, offering high performance, scalability, and resilience without the need for specialized hardware or vendor lock-in.

With simplyblock, you can seamlessly integrate **software-defined storage (SDS)** into your Proxmox environment, enabling support for advanced features like:

- ⚡ **Ultra-low latency**: Unlock performance with NVMe-over-TCP
- 🧩 **Native Proxmox integration**: Manage volumes directly in Proxmox
- 🛡️ **Enterprise data services**: Snapshots, clones, erasure coding, multi-tenancy
- 🔒 **Secure & robust**: Cluster authentication and Quality of Service (QoS)
- ☁️ **Cloud & on-prem flexibility**: Deploy anywhere Proxmox runs

👉 For full documentation, see the [Simplyblock Proxmox Deployment Guide](https://docs.simplyblock.io/latest/deployments/proxmox/).

---

## ✨ Features

| Feature                           | Benefit                                                                 |
|----------------------------------|-------------------------------------------------------------------------|
| **Proxmox Plugin**               | Storage lifecycle fully managed with the Proxmox UI                     |
| **NVMe/TCP Support**              | High throughput, low latency storage over standard Ethernet              |
| **Snapshots & Clones**           | Efficient data protection and instant provisioning                      |
| **Erasure Coding**                | Fault-tolerant, space-efficient redundancy                             |
| **Multi-tenancy & QoS**          | Isolated tenants with guaranteed IOPS, bandwidth, and latency           |
| **Resilient Networking**         | Supports redundant or isolated storage/control networks                  |
| **Auto-Reconnect**               | Automatic reconnection of NVMe devices after network or host failures   |

---

## 📦 Quick Start Guide

The following section acts as a quick start guide. For the full documentation see the [Simplyblock Proxmox Deployment Guide](https://docs.simplyblock.io/latest/deployments/proxmox/).

### 1. Add the Simplyblock Repository

Run as **root** or via `sudo`:

```bash
curl https://install.simplyblock.io/install-debian-repository | bash
````

Or set it up manually:

```bash
curl -o /etc/apt/keyrings/simplyblock.gpg https://install.simplyblock.io/simplyblock.key
echo 'deb [signed-by=/etc/apt/keyrings/simplyblock.gpg] https://install.simplyblock.io/debian stable main' | \
  tee /etc/apt/sources.list.d/simplyblock.list
```

### 2. Install the Plugin

```bash
apt update
apt install simplyblock-proxmox
```

This installs the storage plugin and makes it available inside Proxmox VE.

---

## ⚙️ Configuration

Register a simplyblock storage backend in Proxmox:

```bash
pvesm add simplyblock <STORAGE_NAME> \
  --entrypoint=<CONTROL_PLANE_ADDR> \
  --cluster=<CLUSTER_ID> \
  --secret=<CLUSTER_SECRET> \
  --pool=<STORAGE_POOL_NAME>
```

### Parameters

* `STORAGE_NAME`: Display name of the storage in Proxmox
* `CONTROL_PLANE_ADDR`: IP/hostname of the simplyblock control plane
* `CLUSTER_ID`: Id of the simplyblock cluster (retrieved from `sbctl cluster list`)
* `CLUSTER_SECRET`: Authentication secret (retrieved from `sbctl cluster get-secret`)
* `STORAGE_POOL_NAME`: Storage pool name inside the simplyblock storage plane

👉 Run `sbctl cluster list` and `sbctl cluster get-secret` to retrieve cluster details.

Once added, you can manage simplyblock storage like any other backend, directly from the **Proxmox GUI or CLI**.

---

## 🖥️ Usage

* Create VMs and containers using simplyblock volumes.
* Manage volumes directly via the **Proxmox Storage panel**.
* Use CLI for advanced workflows:

  ```bash
  pvesm list <STORAGE-NAME>
  pvesm alloc <STORAGE-NAME> <VM-ID> <SIZE>
  pvesm free <STORAGE-NAME> <VOLUME-ID>
  ```

---

## 📚 Documentation

* [Deployment Guide](https://docs.simplyblock.io/latest/deployments/proxmox/)
* [Architecture Overview](https://docs.simplyblock.io/latest/architecture/)
* [Release Notes](https://docs.simplyblock.io/latest/release-notes/)
* [Maintenance & Operations](https://docs.simplyblock.io/latest/maintenance-operations/)

---

## 🛠️ Troubleshooting

| Problem                      | Solution                                                                   |                                        |
| ---------------------------- | -------------------------------------------------------------------------- | -------------------------------------- |
| Storage not showing in UI    | Verify installation with \`dpkg -l                                         | grep simplyblock\` and restart Proxmox |
| NVMe volume not reconnecting | In Proxmox, auto-reconnect is built in. On plain Linux, run `nvme connect` |                                        |
| Network contention           | Use dedicated NICs or VLANs; avoid software-only VLANs                     |                                        |
| Cluster secret not accepted  | Refresh with `sbctl cluster get-secret` and re-register storage            |                                        |

If issues persist, please [open an issue](https://github.com/simplyblock/simplyblock-proxmox/issues).

---

## 🤝 Contributing

We welcome community contributions!

1. Fork the repo
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -m "Add my feature"`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Open a Pull Request

Before contributing, please review:

* `CONTRIBUTING.md` (if available)
* Open [issues](https://github.com/simplyblock/simplyblock-proxmox/issues) to avoid duplicates

---

## 📬 Support

* 📖 [Documentation](https://docs.simplyblock.io/latest/deployments/proxmox/)
* 🐞 [GitHub Issues](https://github.com/simplyblock/simplyblock-proxmox/issues)
* 🌐 [Simplyblock Website](https://www.simplyblock.io)

Maintained by the **simplyblock team**.

## Packaging for Releases

```bash
EMAIL=<mail> gbp dch --git-author --release --new-version <version>-1
git add debian/changelog
git commit -m "Release v<version>"
git tag <version> -m "Version <version>"
dpkg-buildpackage -b --no-sign  # or push to GitHub
```
