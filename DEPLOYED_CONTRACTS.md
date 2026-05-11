# SuperEarn — In-Scope Deployed Contracts

This file lists every contract that is **in scope** for the [SuperEarn Bug Bounty Program](./BUG_BOUNTY.md). Out-of-scope deployed contracts (off-vault helpers, the Ethereum Yearn-attached path, the funded but external-yield-bounded Ethereum `CustomStrategy` deployments, `StrategyMorphoV1Vault`, Pendle PT Diamond and its facets / swappers, Yearn V2 Vyper vaults, external protocols, off-chain components) are intentionally not listed here — see [BUG_BOUNTY.md → Out of Scope — Contracts](./BUG_BOUNTY.md) for the full list and rationale.

Most listed contracts are upgradeable TransparentUpgradeableProxy instances with `ProxyAdmin` ownership held by the Governance Gnosis Safe on each chain. The two **non-proxy** in-scope contracts on Kaia — `StrategyOriginVault` and `CustomYearnStrategy` — are Yearn V2 strategies deployed as plain (non-upgradeable) contracts; replacement happens by deploying a new strategy and re-binding it through the Yearn vault's strategy management surface.

> **Implementation addresses.** The addresses below are **proxy** addresses. The currently-active implementation behind each proxy can be queried via the EIP-1967 implementation slot:
>
> ```bash
> # cast (Foundry)
> cast storage <PROXY> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url <RPC>
> ```
>
> A snapshot of the active implementations as of the latest upgrade is maintained in the [Implementation Snapshot](#implementation-snapshot) section below. For findings that depend on the implementation bytecode (storage collisions, upgrade-introduced regressions), reproduce against the *current* implementation rather than this snapshot.

---

## Kaia Mainnet (Chain ID: 8217)

| Contract | Address | Bounty Tier |
|----------|---------|-------------|
| OriginVault | [`0x3B37DB3AC2a58f2daBA1a7d66d023937d61Fc95b`](https://kaiascan.io/address/0x3B37DB3AC2a58f2daBA1a7d66d023937d61Fc95b) | Critical |
| BridgeAccountant | [`0x55CEd8F290256E165d3f50EDa0b60E261ec38f55`](https://kaiascan.io/address/0x55CEd8F290256E165d3f50EDa0b60E261ec38f55) | Critical |
| CrosschainAdapter | [`0x8E53CdAa89381c203a074fB3388f65936358f200`](https://kaiascan.io/address/0x8E53CdAa89381c203a074fB3388f65936358f200) | Critical |
| SuperEarnMessageAgent | [`0xd8acFF2E2B8B1Cf052aca4Ba331743F73C569E68`](https://kaiascan.io/address/0xd8acFF2E2B8B1Cf052aca4Ba331743F73C569E68) | Critical |
| CooldownVault | [`0x4E4654cE4Ca7ff0ba66a0A4a588A4bd55A6f9A33`](https://kaiascan.io/address/0x4E4654cE4Ca7ff0ba66a0A4a588A4bd55A6f9A33) | Critical |
| SuperEarnRouter | [`0x7437892A3e2E658038758dD7CA638334C0c2006C`](https://kaiascan.io/address/0x7437892A3e2E658038758dD7CA638334C0c2006C) | High |
| StrategyOriginVault | [`0x650a4c074a58B18fbEEd48ae766e58a382D9E5F5`](https://kaiascan.io/address/0x650a4c074a58B18fbEEd48ae766e58a382D9E5F5) | Critical |
| CustomYearnStrategy | [`0x723d3422788f47f5DaE153515A3C277293dbd8f3`](https://kaiascan.io/address/0x723d3422788f47f5DaE153515A3C277293dbd8f3) | Critical |
| CustomVault | [`0x7876a2faf6Aad1F6F8E47AD612D9472a4821DfDa`](https://kaiascan.io/address/0x7876a2faf6Aad1F6F8E47AD612D9472a4821DfDa) | Critical |
| USDOKycedCA | [`0x4Bfc1773280689d17c8c00B2514A5C28c8c2b021`](https://kaiascan.io/address/0x4Bfc1773280689d17c8c00B2514A5C28c8c2b021) | High |

---

## Ethereum Mainnet (Chain ID: 1)

> The Ethereum-side stack downstream of `RemoteVault` is **out of scope** for this bounty round, and the table below lists only the bridge-receiving and crosschain-messaging contracts that remain in scope. Two distinct OOS reasons apply:
> - **Unfunded Yearn-attached path:** `SuperEarnRouter`, `CooldownVault` (USDC/USDT), `YearnVaultManager` (USDC/USDT), `StrategyMorphoV2Vault`. Capital is not currently routed through this pipeline.
> - **Funded but external-yield-bounded:** the live `CustomStrategy` deployments registered directly with `RemoteVault` (Multi-Morpho, Pendle, etc.; the exact set rotates operationally) — currently holding funds, but excluded as external-yield strategies bounded by strategist trust assumptions.
> - `USDOKycedCA` (Ethereum) is also OOS for this round.

| Contract | Address | Bounty Tier |
|----------|---------|-------------|
| RemoteVault | [`0x8c82B2feC291a43e41aA87669eaEf01F4efaA3B2`](https://etherscan.io/address/0x8c82B2feC291a43e41aA87669eaEf01F4efaA3B2) | Critical |
| BridgeAccountant | [`0x40FB0F9084828ADBc3dcd71840eA545BF243cD0F`](https://etherscan.io/address/0x40FB0F9084828ADBc3dcd71840eA545BF243cD0F) | Critical |
| CrosschainAdapter | [`0xC090e88bDAA823B7C1dd8d9e24CbacB0f35f2675`](https://etherscan.io/address/0xC090e88bDAA823B7C1dd8d9e24CbacB0f35f2675) | Critical |
| SuperEarnMessageAgent | [`0x4AFd6Ad5b924CD29513d1fb9b66728C4C5A1bd3e`](https://etherscan.io/address/0x4AFd6Ad5b924CD29513d1fb9b66728C4C5A1bd3e) | Critical |

---

## Multisig Addresses

| Role | Chain | Address | Threshold |
|------|-------|---------|-----------|
| `GOVERNANCE_ROLE` | Kaia | [`0x694B81Db6E16c75B6B9EF9F1b09aa3FD1F1d5f05`](https://kaiascan.io/address/0x694B81Db6E16c75B6B9EF9F1b09aa3FD1F1d5f05) | 4 of 5 |
| `GOVERNANCE_ROLE` | Ethereum | [`0xce6917FF9125fff7Da0e5Da5840989B7F3897f2f`](https://etherscan.io/address/0xce6917FF9125fff7Da0e5Da5840989B7F3897f2f) | 4 of 5 |
| `MANAGEMENT_ROLE` | Kaia | [`0xAf65b84B306b4a39EcCc3c915A9143956BC935C8`](https://kaiascan.io/address/0xAf65b84B306b4a39EcCc3c915A9143956BC935C8) | 2 of 3 |
| `MANAGEMENT_ROLE` | Ethereum | [`0xd85Ba41BFe1519813224Be0ba87974cADf3AD3A0`](https://etherscan.io/address/0xd85Ba41BFe1519813224Be0ba87974cADf3AD3A0) | 2 of 3 |
| `ProxyAdmin` | Kaia | [`0x9Ef977E4521ca735a870cBFA8bA225F558866B4B`](https://kaiascan.io/address/0x9Ef977E4521ca735a870cBFA8bA225F558866B4B) | (owned by Governance Safe) |
| `ProxyAdmin` | Ethereum | [`0x5732A7422a8f3631a28Ab9439fe9A872BD39418D`](https://etherscan.io/address/0x5732A7422a8f3631a28Ab9439fe9A872BD39418D) | (owned by Governance Safe) |

`ProxyAdmin` ownership on both chains is held by the corresponding Governance Safe. Every in-scope proxy listed above has been verified (`cast storage <PROXY> 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103`) to use the chain-wide `ProxyAdmin` shown here — no per-proxy admin drift was detected at the snapshot date.

---

## Implementation Snapshot

The implementation contract behind each in-scope proxy as of the most recent upgrade, verified against the EIP-1967 implementation slot on each proxy. The `ProxyAdmin` of every proxy on each chain has been verified to be the single chain-wide admin listed at the top of each table; that admin in turn is owned by the Governance Gnosis Safe (4-of-5).

**Snapshot date:** `2026-05-11` (verified via `cast storage`; no in-scope implementation upgrades between this date and the 2026-05-07 initial cast pass)

### Kaia Mainnet — Implementations

**ProxyAdmin (chain-wide):** [`0x9Ef977E4521ca735a870cBFA8bA225F558866B4B`](https://kaiascan.io/address/0x9Ef977E4521ca735a870cBFA8bA225F558866B4B) — owned by Governance Safe `0x694B81Db…d5f05`. **All Kaia in-scope proxies verified to use this admin.**

| Proxy | Implementation |
|-------|----------------|
| OriginVault | [`0x5BB9761D45C5057aC49C6cF77dC8546E25d9839f`](https://kaiascan.io/address/0x5BB9761D45C5057aC49C6cF77dC8546E25d9839f) |
| BridgeAccountant | [`0x217284bfa0A77e2410FE0297cF82A6834AEC4F8E`](https://kaiascan.io/address/0x217284bfa0A77e2410FE0297cF82A6834AEC4F8E) |
| CrosschainAdapter | [`0xdE597fB7Ee1De45fFe80881a4Ce2259f67CBd610`](https://kaiascan.io/address/0xdE597fB7Ee1De45fFe80881a4Ce2259f67CBd610) |
| SuperEarnMessageAgent | [`0x0f554fF1C806b9bbacEf88462e21d685e5D39c96`](https://kaiascan.io/address/0x0f554fF1C806b9bbacEf88462e21d685e5D39c96) |
| CooldownVault | [`0x570435b7ABCc8241Cfdbcbf05Ba960218acCd190`](https://kaiascan.io/address/0x570435b7ABCc8241Cfdbcbf05Ba960218acCd190) |
| SuperEarnRouter | [`0xA7E483Ec8696Cd2738c7d26927e13A778355B287`](https://kaiascan.io/address/0xA7E483Ec8696Cd2738c7d26927e13A778355B287) |
| CustomVault | [`0x90a2b553845bdc0f4c43554ed306d09fb632f259`](https://kaiascan.io/address/0x90a2b553845bdc0f4c43554ed306d09fb632f259) |
| USDOKycedCA | [`0x12f50Cd71164E84fB0D87984FDd6aD9009E41Ff0`](https://kaiascan.io/address/0x12f50Cd71164E84fB0D87984FDd6aD9009E41Ff0) |

> Non-proxy in-scope contracts (`StrategyOriginVault`, `CustomYearnStrategy`) have no proxy/implementation distinction — see the main table above.

### Ethereum Mainnet — Implementations

**ProxyAdmin (chain-wide):** [`0x5732A7422a8f3631a28Ab9439fe9A872BD39418D`](https://etherscan.io/address/0x5732A7422a8f3631a28Ab9439fe9A872BD39418D) — owned by Governance Safe `0xce6917FF…897f2f`. **All Ethereum in-scope proxies verified to use this admin.**

| Proxy | Implementation |
|-------|----------------|
| RemoteVault | [`0x9997dE3FA5F041679425f39Df5323cF11eA9BA16`](https://etherscan.io/address/0x9997dE3FA5F041679425f39Df5323cF11eA9BA16) |
| BridgeAccountant | [`0x0f4841B8b3796f406FA44B17D89465657533732c`](https://etherscan.io/address/0x0f4841B8b3796f406FA44B17D89465657533732c) |
| CrosschainAdapter | [`0x6172C5B4e42c13b41f82A8B58F08848F9D781BF2`](https://etherscan.io/address/0x6172C5B4e42c13b41f82A8B58F08848F9D781BF2) |
| SuperEarnMessageAgent | [`0x37887C5B3c9c9D8CD2113ABa6078f125cfA135a9`](https://etherscan.io/address/0x37887C5B3c9c9D8CD2113ABa6078f125cfA135a9) |

---

## External Dependencies (Out of Scope, Referenced)

The following external contracts are **out of scope** for the bug bounty (see [BUG_BOUNTY.md](./BUG_BOUNTY.md) → "Out of Scope — Contracts" and "Trust Assumptions") but are integrated by the in-scope contracts. Their addresses are listed here so that researchers can reason about cross-contract calls without having to reverse-engineer them from on-chain state.

A finding whose root cause is a defect in any of these external contracts is **not eligible** for a bounty unless the report demonstrates a SuperEarn-specific exploit path that the integration introduces.

### Kaia Mainnet — External

| Category | Asset / System | Address |
|----------|----------------|---------|
| Stablecoin | USDT (Kaia) | [`0xd077a400968890eacc75cdc901f0356c943e4fdb`](https://kaiascan.io/address/0xd077a400968890eacc75cdc901f0356c943e4fdb) |
| Stablecoin | USDO Express (OpenEden, used by `USDOKycedCA`) | [`0x3ac2b846711897f1c287a6489011dc2c5ef5c33c`](https://kaiascan.io/address/0x3ac2b846711897f1c287a6489011dc2c5ef5c33c) |
| Messaging | Chainlink CCIP Router (Kaia) | [`0x4Eb2a60AF37bC6bb05500F581c00E8EA3075f6E9`](https://kaiascan.io/address/0x4Eb2a60AF37bC6bb05500F581c00E8EA3075f6E9) |
| Oracle | Orakl Feed Proxy (read by `OraklAssetPriceConverter` → `OriginVault`) | [`0x2a6c17ec5639d495e78bfb0be145d8575bc9bf2`](https://kaiascan.io/address/0x2a6c17ec5639d495e78bfb0be145d8575bc9bf2) |
| Yield | Yearn V2 Vault (Kaia, USDT) | [`0x2e4e573D86c70688cD97D76bc5DDc1Bb265bF5D6`](https://kaiascan.io/address/0x2e4e573D86c70688cD97D76bc5DDc1Bb265bF5D6) |
| Yield | Yearn V2 Registry (Kaia) | [`0xea8e1872aDCE77eFBe5d6FE37b5C257Cc86eC786`](https://kaiascan.io/address/0xea8e1872aDCE77eFBe5d6FE37b5C257Cc86eC786) |
| Bridge | Bridge Deposit (current) | [`0x80cf92840cd12365c8a292967c30cc4040008eac`](https://kaiascan.io/address/0x80cf92840cd12365c8a292967c30cc4040008eac) — rotates; authoritative value is `CrosschainAdapter.bridgeDepositAddress()` |

### Ethereum Mainnet — External

| Category | Asset / System | Address |
|----------|----------------|---------|
| Stablecoin | USDC | [`0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`](https://etherscan.io/address/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) |
| Stablecoin | USDT (the only crosschain-bridged asset, via Rhino) | [`0xdAC17F958D2ee523a2206206994597C13D831ec7`](https://etherscan.io/address/0xdAC17F958D2ee523a2206206994597C13D831ec7) |
| Messaging | Chainlink CCIP Router (Ethereum) | [`0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D`](https://etherscan.io/address/0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D) |
| Oracle | Chainlink USDC/USD feed (read by `AssetPriceConverter` → `RemoteVault`) | [`0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6`](https://etherscan.io/address/0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6) |
| Oracle | Chainlink USDT/USD feed (read by `AssetPriceConverter` → `RemoteVault`) | [`0x3E7d1eAB13ad0104d2750B8863b489D65364e32D`](https://etherscan.io/address/0x3E7d1eAB13ad0104d2750B8863b489D65364e32D) |
| Bridge | Bridge Deposit (current, USDT outbound to Kaia) | [`0xc8a0b9d1c394d052214d030a5ecb8641960802fe`](https://etherscan.io/address/0xc8a0b9d1c394d052214d030a5ecb8641960802fe) — rotates; authoritative value is `CrosschainAdapter.bridgeDepositAddress()` |
| Swap | Uniswap V3 SwapRouter (referenced by `UniversalSwapRouter`) | [`0xE592427A0AEce92De3Edee1F18E0157C05861564`](https://etherscan.io/address/0xE592427A0AEce92De3Edee1F18E0157C05861564) |
| Swap | Uniswap V4 Pool Manager (referenced by `UniversalSwapRouter`) | [`0x000000000004444c5dc75cB358380D2e3dE08A90`](https://etherscan.io/address/0x000000000004444c5dc75cB358380D2e3dE08A90) |

> Yearn V2 vaults (USDC / USDT) on Ethereum are unfunded (the Yearn-attached path is dormant) and MetaMorpho / Morpho Blue / Pendle markets are referenced only by the funded `CustomStrategy` deployments which are out of scope for this round as external-yield strategies. Their addresses are intentionally omitted to keep this table focused on dependencies of the in-scope or compile-kept code paths.
