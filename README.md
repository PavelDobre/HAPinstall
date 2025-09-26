# HAPinstall

! Dont use this script, it's a private template only.

Install script for Docker + HAProxy + configure
To use on clean Ubuntu server to prepare a TCP-mode HAPproxy with round bobin balancing

To install:

```bash
curl -fsSL https://raw.githubusercontent.com/PavelDobre/HAPinstall/main/HAProxySetup.sh -o HAProxySetup.sh
chmod +x HAProxySetup.sh
sudo ./HAProxySetup.sh
```
OR:

```bash
curl -fsSL https://raw.githubusercontent.com/PavelDobre/HAPinstall/main/HAProxySetup.sh -o HAProxySetup.sh && chmod +x HAProxySetup.sh && sudo ./HAProxySetup.sh
```