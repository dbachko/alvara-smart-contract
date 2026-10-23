# Alvara smart contract

This repository contains a modernized, locally testable reference implementation of the
historical Alvara ERC721 contract. It is **not approved for production deployment**. The legacy
paid sale, pooled refund reserve, and charity flow are preserved for compatibility but are
disabled immutably unless the constructor's `enableLegacyFinancialFeatures` argument is `true`.

No chain, live coordinator, subscription, price, charity wallet, metadata URI, owner wallet, or
deployment address is selected here. A deployment or broadcast is intentionally not provided.

## Toolchain

- Solidity `0.8.38` (exact)
- EVM target `prague`
- optimizer enabled with 200 runs
- OpenZeppelin Contracts `5.7.0`
- Chainlink EVM Contracts `contracts-v1.5.0` commit
  `86aa5a1d34b20eda8d18fe6eb0e4882948e545ba` (least-scope vendored VRF v2.5 sources)
- Foundry/Forge tests, including fuzz and invariant suites (`forge-std` `v1.17.0` commit
  `f3dae6e6ee381f25eb6a246f7da9b85c91a68219`)

OpenZeppelin and test dependency versions are exact direct development pins in `package.json`;
`forge-std` uses the immutable commit behind its official `v1.17.0` tag because that release is not
published as an npm semver. Chainlink's broad npm package was replaced with the eight exact upstream
source files reachable from the official VRF v2.5 consumer import graph. Their release, commit,
archive digest, file digests, and refresh procedure are recorded in
`lib/chainlink-evm/UPSTREAM.md`. This follows Chainlink's current Foundry source-pin guidance while
keeping unrelated JavaScript tooling out of the install and deployment supply chain.

The generated trait library is excluded from `forge fmt` so it remains byte-for-byte equal to the
generator output. After an authorized dependency installation, run:

```sh
forge fmt --check
forge build
forge test -vvv
```

The project contains no package lifecycle hooks and no Truffle, Ganache CLI, Rinkeby, mnemonic,
Infura, ngrok, or broadcast configuration.

## Safety defaults

- `saleState` begins closed.
- Use `enableLegacyFinancialFeatures = false` for every local or test deployment unless a test
  specifically exercises the quarantined legacy economics.
- All minting requires a completed VRF request. Tests use only the local coordinator mock.
- The base URI is constructor-supplied and can be frozen permanently without restricting holder
  transfers.
- Contract ownership comes from Chainlink's `ConfirmedOwner`, including two-step transfer.

The constructor requires explicit values for the coordinator, subscription ID, key hash, callback
gas, confirmations, native-payment choice, token price, charity destination, base URI, and legacy
financial gate. Never copy the local mock values into a deployment.

## ABI export

After a successful reviewed build, export the backend ABI to the stable integration path:

```sh
mkdir -p artifacts
forge inspect AlvaraStorage abi > artifacts/AlvaraStorage.abi.json
```

Do not create or infer a deployed-address manifest from this command. The backend must accept a
separate, reviewed chain/address configuration and must never treat the ABI as deployment proof.

## Release blockers

Before any public testnet or production action, resolve the token standard and chain, historical
buyer obligations, art/license rights, collection supply and price, charity and owner custody,
metadata permanence, randomness/reveal policy, and independent smart-contract security review.
The pooled reserve/redemption design is a financial mechanism and needs explicit legal/product
approval; retaining its code here is not approval to operate it.

See [MIGRATION.md](MIGRATION.md) for compatibility and behavioral changes.
