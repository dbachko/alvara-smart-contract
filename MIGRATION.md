# Migration notes

## Baseline

The historical baseline is Git commit
`9e45980fdb8ccc22e914f63f4fe96fa30cbc30c6` from May 8, 2022. Git history remains the source for
the original Solidity 0.7/Truffle/Rinkeby code; duplicate JavaScript tests and live-network scripts
were removed from the working tree rather than carried into a deployable `legacy/` directory.

## Preserved interfaces and behavior

- ERC721 remains the token standard. No ERC1155 or chain switch is implied.
- `developersMint`, presale reservations, public mint, one reroll, refund, donate-reserved, charity
  donation, `getData`, `totalSupply`, and the packed 41-bit public DNA layout remain available.
- The generated trait table preserves the historical public DNA encoding but uses the canonical
  settings-derived layout and words. It is isolated in `contracts/generated/AlvaraTraitData.sol`
  so the maintained generator can replace it deterministically.
- `forDonation()` remains as an ABI-compatible view of the explicit donation liability.

## Intentional safety repairs

- All legacy financial entry points require an immutable constructor opt-in. Sale starts closed.
- VRF v2.5 has explicit `Unrequested`, `Requested`, and `Ready` states; all minting requires
  `Ready`, fulfillment must match the outstanding request, and timestamp/difficulty randomness is
  removed.
- Category selection is weighted by each bucket's remaining capacity, so all ten quotas close
  exactly without comparing one bucket against another bucket's limit.
- The corrected generated layout starts included combinations at bit 2525 (after all ignored
  entries), rather than the overlapping legacy offset 2455. Its 14 words match generator hash
  `fbb44e26fbd4652a25c32c1a2e89f18b15ca54d683fa6324f52373866e535f77`.
- Normal traits reject both included/reserved combinations and ignored combinations. Special
  traits use only the included table.
- Payment must equal price exactly. Lifetime minted supply never decreases after burns.
- Outstanding presale reservations are deducted when consumed and protected from public mints.
- Developer-token and refundable-token status are explicit mappings; refunds no longer assume
  token IDs 0-4 exist.
- `reservePool`, `donationLiability`, and `refundableSupply` replace balance-derived accounting.
- Mint/refund/donation/reroll use reentrancy protection. DNA and Alvara-specific effects are set
  before ERC721 receiver callbacks; burns/accounting happen before checked native-value calls.
- Metadata changes emit ERC-4906 signals, and the base URI can be frozen permanently without
  pausing token transfers. ERC-2981 is intentionally absent pending a royalty-policy decision.
- `totalSupply()` reports current circulating supply, while `lifetimeMinted()` enforces the cap and
  exposes gaps left by burns to indexers.

## Integration changes

The old backend expected a missing Truffle artifact named `AlvaraStorage.json`. The supported
contract artifact is now a reviewed ABI exported to `artifacts/AlvaraStorage.abi.json`; chain ID and
address belong in a separate runtime/deployment manifest. No deployed address exists in this repo.

Consumers must not iterate token IDs as `0..totalSupply-1`, because burned IDs are never reused.
Use `lifetimeMinted()` for the upper token-ID bound and tolerate nonexistent/burned IDs, or index
standard `Transfer` events.

## Unresolved product decisions

The modernization does not decide whether reserve/redemption, charity, reroll, DAO/game utility,
on-chain generation, or VRF should ship. Removing or redesigning them requires an explicit product
and obligations decision. Likewise, supply, price, allocation, metadata/reveal policy, owner and
charity custody, chain, and token standard remain unset.
