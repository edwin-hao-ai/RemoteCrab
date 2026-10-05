# Third-party notices — Windows build

The Windows receiver is distributed as a binary, so the licences of the
components compiled into it have to travel with it. This file is that list. Keep
it in step with `windows/Cargo.lock`; a component added without a line here is a
compliance gap, not a documentation gap.

## OpenH264

- **Where**: `rc-render` and `rc-mirror` (dependency `openh264`), and through
  them the receiver's preview and virtual-camera picture.
- **Version**: see `windows/Cargo.lock`.
- **Licence**: BSD-3-Clause, with Cisco's binary-distribution terms.
- **Source**: <https://github.com/cisco/openh264>

OpenH264 is Copyright (c) 2013, Cisco Systems. All rights reserved. Redistribution
and use in source and binary forms, with or without modification, are permitted
provided that the copyright notice, the list of conditions and the disclaimer are
retained. Cisco's terms also require that this notice be reproduced in the
documentation and/or other materials provided with the distribution — which is
what this file is for.

> If this project ever ships a **paid** application that includes OpenH264,
> Cisco's terms require the OpenH264 binary to be obtained from Cisco or a
> Cisco-authorized source, or a royalty to be paid. Building from source, as
> `cargo` does here, is the case those terms are written about. Worth a legal
> read before the first paid release; recorded here so it is not discovered
> afterwards.

## Everything else

The remaining Rust dependencies are permissively licensed (MIT / Apache-2.0 /
BSD / ISC). To regenerate the full list from a checkout:

```sh
cargo install cargo-license        # once
cd windows && cargo license --avoid-build-deps --avoid-dev-deps
```

`cargo-deny` can gate this in CI if it ever needs to be automatic:

```sh
cargo deny check licenses
```
