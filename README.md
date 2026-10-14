# HAPinstall

Installation script for "HAProxy in Docker" + config
To be used on clean Ubuntu server to quick prepare:
- TCP-mode HAPproxy with configuring Round Robin balancing / Backup
- SSH settings

To install / run:

```bash
curl -fsSL https://raw.githubusercontent.com/PavelDobre/HAPinstall/main/menu.sh -o menu.sh
chmod +x menu.sh
sudo ./menu.sh
```
OR:

```bash
curl -fsSL https://raw.githubusercontent.com/PavelDobre/HAPinstall/main/menu.sh -o menu.sh && chmod +x menu.sh && sudo ./menu.sh

```

