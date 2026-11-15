# satmux (vendored)

`satmux.py` and `LICENSE` are [Th0rgal/satmux](https://github.com/Th0rgal/satmux) at `2922ebb`, unchanged (MIT,
Thomas Marchand). `SatmuxTransport` speaks its wire format; this copy is the reference it is tested against:

- `vectors.py` prints the recorded frames and keys in `Tests/DurableNetworkingTests/SatmuxVectors.swift`, made by
  satmux's own functions: `python3 -I Tools/satmux/vectors.py > Tests/DurableNetworkingTests/SatmuxVectors.swift`.
- `SatmuxRelayTests` runs `satmux.py server` locally and fetches through it.
- The demo runs it as its relay (`Demo/server/geo_link.py` puts a satellite's round trip in front of it).
