# Security policy

StickyDock runs with Accessibility permission, so security reports are taken seriously.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/amarchakitus/stickydock/security/advisories/new)
rather than in a public issue. Include the StickyDock version, your macOS version, and
steps to reproduce.

## Supported versions

Only the latest release receives fixes.

## Verifying a download

Each release includes a `SHA256SUMS` file. After downloading, check your file against it:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
```

Every official build is signed with the same certificate. To confirm an installed copy
came from this project, run:

```sh
codesign -dv -r- /Applications/StickyDock.app 2>&1 | grep designated
```

The output should read:

```
designated => identifier "io.github.amarchakitus.stickydock" and certificate leaf = H"b7191fab62588f155df6354a56bd2e3b5cc372c5"
```

If the certificate value differs, don't run that copy.
