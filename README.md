# AIC8800D80 — Driver WiFi + Bluetooth para CachyOS / Arch

Script de instalação para adaptadores USB WiFi+Bluetooth baseados no chip
**AIC8800D80** (Tenda U11, AX913B, clones "Pandora", ugreen, Cudy, etc.) no
**CachyOS / Arch Linux** — incluindo o kernel handheld `cachyos-deckify`
(testado no **BC250** com kernel `7.1.3-2`).

Compila, instala e ativa tudo:
* módulos do kernel (`aic8800_fdrv` + `aic_load_fw`)
* firmware em `/lib/firmware/aic8800*`
* regras `udev` + config `usb_modeswitch` (para o *mode-switch* do dongle)
* **hook do pacman** que recompila o driver automaticamente após
  atualizações de kernel (substituto do DKMS, sem instalar o pacote `dkms`)

> Repositório do driver original: [`shenmintao/aic8800d80`](https://github.com/shenmintao/aic8800d80) — branch [`bluetooth`](https://github.com/shenmintao/aic8800d80/tree/bluetooth), única branch que ativa WiFi **e** Bluetooth (`aic_load_fw` carrega o firmware BT e o `btusb` nativo do kernel assume a interface HCI).

## Por que este script

O dongle AIC8800D80 apresenta ao Linux um *Mass Storage* (`a69c:5721`,
"Aic MSC") contendo o instalador Windows. Precisa de um *mode-switch*
(`eject` / `usb_modeswitch`) para se reenumerar como `a69c:8d8x` e expor
as interfaces WiFi + Bluetooth. Sem o driver devidamente compilado e o
firmware correto, nada aparece.

O instalador original do upstream (`install.sh`) usa DKMS, que **não** vem
instalado no CachyOS. Este script:

* instala direto com `make install` (mais rápido e sem depender do `dkms`);
* já roda o *mode-switch* mesmo no dispositivo plugado como disco;
* provisiona um **hook do pacman** que recompila o driver sozinho quando o
  kernel é atualizado — sem isso, qualquer `pacman -Syu` quebra o driver.

## Dispositivos testados

| ID USB (modo disco)        | ID USB (modo operacional) | Chip      | Clones                       |
|----------------------------|---------------------------|-----------|------------------------------|
| `a69c:5721`                | `a69c:8d81`               | AIC8800D80| Tenda U11 / AX913B           |
| `1111:1111`                | `a69c:8d80`               | AIC8800D80| "Pandora"                    |
| `a69c:5722`/`5723`/`5724`… | `a69c:8d8x`               | AIC8800D80| ugreen / Cudy / Tenda v2/v3  |

A regra `udev` incluída cobre os PIDs `5721`–`572c` e `1111:1111`.

## Pré-requisitos

* CachyOS ou Arch Linux (64-bit)
* `sudo`
* conexão à internet (para clonar o repo e instalar deps via `pacman`)

As dependências são instaladas automaticamente: `base-devel`, `git`,
`linux-cachyos-deckify-headers` (ou os `linux-headers` correspondentes),
`usb_modeswitch`, `bluez`, `bluez-utils`, `rfkill`.

## Uso

```bash
# instala, compila, carrega e verifica
sudo bash ~/fix-aic8800.sh

# remove tudo (módulos, firmware, regras e hook)
sudo bash ~/fix-aic8800.sh --uninstall

# recompila para todos os kernels instalados (chamado pelo hook do pacman,
# não precisa rodar manualmente)
sudo bash ~/fix-aic8800.sh --rebuild
```

Ao final aparecerão:

* `wlan0` em `ip link`
* um controller em `bluetoothctl list`
* `lsmod | grep aic` mostrando `aic8800_fdrv` + `aic_load_fw`
* `lsmod | grep btusb` mostrando o `btusb` nativo

Se o dongle não trocar de modo no primeiro run, **desconecte e reconecte**
o USB — a regra `udev` agora dispara o *mode-switch* e vincula os drivers.

## Conectar

```bash
# WiFi
nmcli device wifi list
nmcli device wifi connect "SSID" password "SENHA"

# Bluetooth
bluetoothctl
[bluetooth]# power on
[bluetooth]# scan on
[bluetooth]# pair <MAC>
[bluetooth]# trust <MAC>
[bluetooth]# connect <MAC>
```

## Como funciona

```
USB plug → udev (aic.rules)
            ├─ a69c:5721/572x: eject → modo operacional
            └─ 1111:1111     : usb_modeswitch → a69c:8d80
                                   ↓
Kernel vê a69c:8d8x → modules.alias (depmod) carrega:
            ├─ aic_load_fw    (carrega firmware WiFi+BT pro chip)
            ├─ aic8800_fdrv   (driver WiFi cfg80211) → wlan0
            └─ btusb          (driver BT nativo)    → hci0
```

Quando o pacman atualiza o kernel:

```
pacman -Syu linux-cachyos-deckify
  → hook /etc/pacman.d/hooks/aic8800-rebuild.hook
  → fix-aic8800.sh --rebuild
  → recompila aic8800_fdrv.ko + aic_load_fw.ko para o kernel novo
  → depmod
```

## Diagnóstico

Se o Bluetooth não subir:

```bash
sudo bash /usr/src/aic8800d80-src/diagnose_bt.sh
sudo dmesg | grep -iE "aic|btusb|hci|fw_patch"
rfkill list bluetooth && sudo rfkill unblock bluetooth
```

Causas comuns:

* **firmware errado**: `sudo bash ~/fix-aic8800.sh` reinstala o firmware
  correto e remove o antigo (`/lib/firmware/aic8800*`).
* **`/etc/modprobe.d/aic8800-bt.conf` residual**: de versões antigas, faz
  referência a um `aic_btusb` que não existe nesta branch, causando
  `HCI_Reset` timeout (`-110`). O script remove automaticamente.
* **Secure Boot**: módulos não-assinados não carregam. Desabilite o Secure
  Boot na BIOS/UEFI.

## Estrutura

```
fix-aic8800.sh         # instalador (run as root)
```

O script clona o driver upstream para `/usr/src/aic8800d80-src/`.

## Compatibilidade de kernel

Testado em `7.1.3-2-cachyos-deckify`. O driver compila sem erros (apenas
warnings) nesse kernel. Para kernels significativamente diferentes pode ser
necessário aplicar patches — nesse caso, reporte via issues.

## Agradecimentos

* [`shenmintao`](https://github.com/shenmintao) — mantenedor do fork
  `aic8800d80` branch `bluetooth` com suporte Bluetooth funcionando.
* [`radxa-pkg`](https://github.com/radxa-pkg/aic8800) — driver base.
* Aicsemi — fabricante do chip AIC8800.

## Licença

O driver upstream é GPL (vide `drivers/aic8800/*/Kconfig` e cabeçalhos).
Este script (`fix-aic8800.sh`) é MIT — veja abaixo.

```
MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```