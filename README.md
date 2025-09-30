# HAPinstall

! Dont use this script, it's a private template only.

Installation script for "HAProxy in Docker" + config
To be used on clean Ubuntu server to quick prepare a TCP-mode HAPproxy with configuring Round Robin balancing

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

