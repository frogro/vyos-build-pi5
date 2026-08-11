# Security Policy

## Supported versions

Security fixes are normally applied only to the current `rolling` branch and the latest published Raspberry Pi 5 image.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose credentials, permit unauthorized access, or compromise a running router.

Use GitHub's private vulnerability reporting feature if it is enabled for this repository. Otherwise, contact the repository owner privately through the contact method listed on their GitHub profile.

Include:

- affected release or commit;
- reproduction steps;
- expected impact;
- relevant logs with secrets removed;
- any suggested mitigation.

Please allow reasonable time for investigation before public disclosure.

## User responsibilities

This is an unofficial rolling image. Before deployment:

- change the default `vyos` password immediately;
- prefer SSH key authentication;
- restrict management access with firewall rules;
- review all generated configuration;
- keep backups of `/config/config.boot`;
- test updates before production use;
- never publish SIM PINs, APNs containing credentials, private keys, tokens, or configuration backups containing secrets.
