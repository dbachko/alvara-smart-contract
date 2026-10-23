# Chainlink EVM source pin

This directory contains only the upstream source files reachable from Alvara's two Chainlink VRF
v2.5 imports. It avoids installing the unrelated JavaScript and multi-chain packages shipped as
normal dependencies of the broad `@chainlink/contracts` npm distribution.

- Upstream repository: `https://github.com/smartcontractkit/chainlink-evm`
- Official release tag: `contracts-v1.5.0`
- Verified tag commit: `86aa5a1d34b20eda8d18fe6eb0e4882948e545ba`
- Retrieved archive:
  `https://codeload.github.com/smartcontractkit/chainlink-evm/tar.gz/86aa5a1d34b20eda8d18fe6eb0e4882948e545ba`
- Archive SHA-256: `2bbe5a567c1f16a6e56d7c175196f405db68adb395454b45469798f09182f4da`
- License: upstream MIT license retained as `LICENSE`

## Retained source manifest

| Repository-relative path under `contracts/` | SHA-256 |
| --- | --- |
| `src/v0.8/shared/access/ConfirmedOwner.sol` | `0ee82c5fd2b3bd8914f51ea5e04cc10e2c9ba5ad25800bfe071f3e236f57f0da` |
| `src/v0.8/shared/access/ConfirmedOwnerWithProposal.sol` | `b5f02ce053e1c9566a9caed8c87eb915168f030864b7ea398e2fae1565ae324e` |
| `src/v0.8/shared/interfaces/IOwnable.sol` | `8393df1c8bbc27e94957c9d088f59d281f4091ad1b414de29b62b1e38028135d` |
| `src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol` | `a71d645fc82a7ac89e7d203827c2c97325fd311af289483f5035d20e393e89eb` |
| `src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol` | `b09dc6442316ff371ed04bd1c36a877a071e10d76d0270b6b7a732b38a9114cc` |
| `src/v0.8/vrf/dev/interfaces/IVRFMigratableConsumerV2Plus.sol` | `58f2ae957bc8ec789a2d8cb11a2ad087c61e09038726c021eeaae7162bafd8fa` |
| `src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol` | `88fd9e9250d8131d9adf8af753ac2f2e51babec3fe9ba4d5c564a13b91b0933f` |
| `src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol` | `f3b89bb466c2a79b10c1816d342fbfbec49fe82695cba92bd46e7d31af698011` |

These files were byte-compared with the same paths from the exact npm 1.5.0 source before the npm
package was removed. No source edits were made.

From this directory, verify the retained files with:

```sh
shasum -a 256 -c SHA256SUMS
```

## Refresh procedure

For an approved upgrade, resolve an official `contracts-v*` tag to its full commit, download that
immutable commit archive, verify its digest, recompute the complete Solidity import closure from
`VRFConsumerBaseV2Plus.sol` and `VRFV2PlusClient.sol`, and replace the manifest and license together.
Then run `npm audit`, `forge fmt --check`, `forge build --sizes`, all unit/fuzz/invariant tests, and a
final bytecode/deployment-gas comparison. Never update one imported file without its closure.
