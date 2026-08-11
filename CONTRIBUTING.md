# Contributing

Thank you for considering a contribution.

## Before opening an issue

1. Confirm that the issue occurs on the latest image or current `rolling` branch.
2. Search existing issues and discussions.
3. Collect relevant logs without publishing passwords, private keys, SIM PINs, APNs containing credentials, or other secrets.
4. State whether the issue occurs before or after running any optional helper script.

## Bug reports

Please include:

- Raspberry Pi 5 hardware revision and RAM size
- boot medium: SD, eMMC, NVMe, or USB
- image release or commit
- connected Ethernet, Wi-Fi, and modem hardware
- exact steps to reproduce
- expected and actual behaviour
- relevant logs and command output

Useful first-boot diagnostics:

```bash
cat /config/dhcp-wan-firstboot-wrapper.log
cat /config/dhcp-wan-ssh-setup.log
systemctl status dhclient@eth0.service --no-pager -l
ip -br link
ip -4 -br address
ip route
```

## Pull requests

- Keep Raspberry Pi 5-specific changes under `scripts/pi5` whenever possible.
- Avoid unrelated formatting changes.
- Explain why the change is needed and how it was tested.
- Update `README.md` and `CHANGELOG.md` when user-visible behaviour changes.
- Never commit generated images, credentials, private keys, tokens, or subscriber-only material.
- Preserve the unofficial and non-endorsement notices.

## Testing

For networking or first-boot changes, test a freshly flashed image with:

1. Ethernet connected before power-on.
2. No manual AP or modem helper invoked.
3. At least 90 seconds allowed for first-boot setup.
4. DHCP address and SSH reachability verified.
5. A second reboot confirming the saved configuration remains functional.
