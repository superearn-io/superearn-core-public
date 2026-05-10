# SuperEarn

SuperEarn is a yield-aggregation protocol that lets users on **Kaia** access yield opportunities on both **Kaia** and **Ethereum** through an asynchronous request / fulfill / claim vault architecture. The Kaia-side Yearn V2 vault routes capital through `StrategyOriginVault` → `OriginVault`, which bridges capital to Ethereum via a state-piggybacked CCIP messaging layer (Runespear) and reconciles accounting through a self-correcting bridge accountant. On Ethereum, `RemoteVault` is the bridge counter-party.

This repository is the **public source release** for the [SuperEarn Bug Bounty Program](./BUG_BOUNTY.md). The bounty's current focus is the **internal vault system + crosschain accounting layer** — `OriginVault`, `RemoteVault`, the `CrosschainAdapter` / `BridgeAccountant` / `SuperEarnMessageAgent` plumbing, the Kaia-side `CooldownVault` / `SuperEarnRouter` user-entry flow, and the `CustomVault` / `CustomYearnStrategy` Kaia local-yield wrapper. Off-vault helpers (keepers, price converters, swap routers, asset providers, healthcheck), the Ethereum Yearn-vault-attached path (currently unfunded), the funded direct-registered `CustomStrategy` deployments on Ethereum (excluded as external-yield strategies bounded by strategist trust assumptions), and other external strategies whose risk is bounded by Yearn V2 + assets-provider semantics are **out of scope** for this round; those contract sources have been removed from this repository to reduce review surface. A small set of OOS helpers and a single reference `CustomStrategy` / `SimpleExternalAssetsProvider` pair are kept for compile / educational continuity (see §6).

The deployed addresses for every in-scope contract on Kaia and Ethereum mainnet are listed in [DEPLOYED_CONTRACTS.md](./DEPLOYED_CONTRACTS.md).

---

## Table of Contents

1. [Protocol Overview](#1-protocol-overview)
2. [System Architecture](#2-system-architecture)
3. [Core Components](#3-core-components)
4. [Crosschain Messaging & Bridging](#4-crosschain-messaging--bridging)
5. [Role-Based Access Control](#5-role-based-access-control)
6. [Repository Layout](#6-repository-layout)
7. [Build & Setup](#7-build--setup)
8. [Operational Workflows](#8-operational-workflows)
9. [Trust Assumptions](#9-trust-assumptions)
10. [References](#10-references)

---

## 1. Protocol Overview

SuperEarn is built as a layered stack:

```
SuperEarnRouter → CooldownVault → Yearn V2 Vault → Strategy → (Kaia-native CustomVault | OriginVault → Ethereum)
```

- **Users on Kaia** deposit USDT into a `SuperEarnRouter`, which routes the deposit through `CooldownVault` into the Kaia Yearn V2 vault.
- The Kaia Yearn vault allocates capital across two strategies:
  - **Kaia-native** — `CustomYearnStrategy` wraps `CustomVault` shares; `CustomVault.totalAssets()` aggregates `ICustomStrategy.totalAssets()` over its registered `customStrategies` array (each registered `ICustomStrategy` internally consults its own `IExternalAssetsProvider` — providers are **not** read directly by `CustomVault`). The bug-bounty surface here is the **vault accounting layer** (`CustomVault` ↔ `CustomYearnStrategy`); the registered strategies and their providers are operationally trusted and out of scope.
  - **Crosschain** — `StrategyOriginVault` bridges assets to Ethereum via `OriginVault` → `CrosschainAdapter`.
- On Ethereum, `RemoteVault` is the bridge-receiving counterparty and aggregates yield from `CustomStrategy` deployments (USDC Multi-Morpho, USDT Multi-Morpho, Pendle PT-USDG) registered directly with it. The bug-bounty surface on the Ethereum side is intentionally narrowed to **bridge plumbing** (`RemoteVault`, `CrosschainAdapter`, `BridgeAccountant`, `SuperEarnMessageAgent`): (a) the **Yearn-vault-attached path** through `SuperEarnRouter` (ETH) → `CooldownVault` USDC/USDT → Ethereum Yearn vaults → `StrategyMorphoV2Vault` is currently **unfunded** and excluded; (b) the funded direct-registered `CustomStrategy` deployments are excluded as external-yield strategies bounded by strategist trust assumptions (Morpho V2, Morpho Blue, Pendle).
- Yield is mark-to-market on each side: Kaia-native strategies report directly to the Kaia Yearn vault; Ethereum-side P&L (when funded) is reflected back via state-piggybacked CCIP messages. Both flows surface to users through the share price of the Kaia-side `CooldownVault`.

Key properties:

- **Two-step withdrawal** at the Kaia entry layer to absorb async bridge timing and protect against front-running. Concrete entry points: `CooldownVault.withdraw(...)` or `CooldownVault.redeem(...)` (which return a `requestId`, **not** assets/shares — this deviates from strict ERC4626) → cooldown elapses → `CooldownVault.claim(requestId)`. The crosschain leg uses `OriginVault.requestRedeem(...)` (ERC-7540-style on the bridge boundary).
- **Eventual consistency** — the protocol prioritises asset safety and operational resilience over real-time accuracy. Bridge and message races are reconciled by a dual pending-nonce system.
- **State piggybacking** — every CCIP message carries a complete snapshot of vault and bridge state, so accounting self-corrects on every round-trip.
- **Permissioned entry points** — `OriginVault` is whitelist-gated (`onlyWhitelistedShareholder` on entry; redemption side uses ERC-7540 controller checks), `CooldownVault` is gated by its own `_authorizedAddresses` `EnumerableSet` (queried via `getAuthorizedAddresses()`) — the router and the in-scope strategies sit in this set. `RemoteVault` uses `SuperEarnAccessControl` roles: `GOVERNANCE_ROLE`, `MANAGEMENT_ROLE`, `KEEPER_ROLE`, `SYSTEM_CONTRACT_ROLE` (there is no "Router" role in the codebase; `SUPEREARN_ROUTER_ROLE` does not exist either — the `SuperEarnRouter` contract is registered into `RemoteVault.superEarnRouter` storage and called directly without going through a dedicated role).

---

## 2. System Architecture

```
Kaia (Origin)  — IN SCOPE                      Ethereum (Remote) — bridge-only IN SCOPE
┌──────────────────────────────────┐           ┌──────────────────────────────────┐
│  SuperEarnRouter (user entry)    │           │  RemoteVault                     │
│    └─ CooldownVault              │           │                                  │
│         └─ YearnVault (Kaia)     │           │  CrosschainAdapter               │
│              ├─ StrategyOrigin   │           │    └─ BridgeAccountant           │
│              │    Vault          │           │    └─ SuperEarnMessageAgent      │
│              │     └─ OriginVault│           │                                  │
│              │                   │           │    ├─ CustomStrategy x3 (USDC MM,│
│              └─ CustomYearn      │           │    │   USDT MM, Pendle PT-USDG;  │
│                   Strategy       │           │    │   funded, OOS as external-  │
│                     └─ CustomVlt │           │    │   yield strategies)         │
│                                  │           │                                  │
│  CrosschainAdapter               │           │  ─ unfunded Yearn path (OOS) ─ ─ │
│    └─ BridgeAccountant           │           │    SuperEarnRouter (ETH)         │
│    └─ SuperEarnMessageAgent      │           │      → CooldownVault USDC/USDT   │
│                                  │           │        → Yearn → StrategyMorphoV2│
│  USDOKycedCA                     │           │                                  │
└──────────────────────────────────┘           └──────────────────────────────────┘
              ◀──────────  CCIP / Runespear  ──────────▶
              ◀──────────  Bridge (Rhino, USDT-only)  ──▶
```

> Off-chain keepers (LightKeeper, CrosschainKeeper) drive harvest / bridge / redemption-fulfillment cadence operationally, but their contracts are out of scope and have been removed from this repository. Helper contracts (price converters, swap router) are out of scope as standalone targets but a few remain in-tree because in-scope vaults import them by concrete type.

### Design principles

1. **Separation of concerns** — vaults are pure state machines; the `SuperEarnMessageAgent` routes business payloads; the `CrosschainAdapter` owns all bridge and messaging plumbing.
2. **Universal state piggybacking** — every CCIP envelope carries a `StateSnapshot { vaultState, bridgeState }` captured at the same timestamp, so the receiving chain always has a fresh, consistent view.
3. **Dual pending nonce system** — the adapter tracks outbound (assets we sent) and inbound-awaiting-delivery (notifications we received) nonces independently, which lets it recover regardless of whether the CCIP message or the bridge delivery arrives first.
4. **Asynchronous reconciliation** — bridge callbacks and CCIP messages are both treated as best-effort; the protocol converges via `processPendingBridgeAssets()` and the next round-trip's piggybacked snapshot.
5. **FIFO redemption queue** — `OriginVault` locks `requestedAssets` at the time of `requestRedeem()` and fulfills strictly in order, so redemption price is predictable and head-of-queue cannot be overtaken.

---

## 3. Core Components

### 3.1 Single-Chain Vaults & Strategies (in scope)

| Contract | Chain | Role |
|----------|-------|------|
| `SuperEarnRouter` | Kaia | User-facing entry. Implements the flow `underlying → CooldownVault → yVault` for deposits and `yVault → CooldownVault.redeem (initiates cooldown, returns requestId)` for redemptions. Gated by a `whitelistedVaults[yVault]` check (governance-managed) plus per-vault `_checkDepositAllowed` / `_checkDepositorAllowed` hooks. On Ethereum the same contract has an additional `if (remoteVault != address(0) && sender != remoteVault) revert Unauthorized()` clause; the Kaia deployment (the in-scope one) has `remoteVault == address(0)`, so it is callable by anyone subject to the per-vault checks. To call `CooldownVault.deposit` (which is `onlyAuthorized`), the router must be present in `CooldownVault`'s `_authorizedAddresses` set; this is configured by governance. Supports ERC-2612 permit on the deposit side (`depositWithPermit`, `depositWithPermitAndReferral`); the redeem path uses the standard non-permit signature. |
| `CooldownVault` | Kaia | `ERC20WrapperUpgradeable` around the Yearn vault, exposing the `IERC4626Upgradeable` interface for compatibility (see SUA-10 — not a strict ERC4626 implementation). Two-step withdraw flow: `withdraw(assets, receiver, owner)` / `redeem(shares, receiver, owner)` initiate the cooldown and return a **`requestId`** (deviation from standard ERC4626 which returns assets/shares); `claim(requestId, maxLossBps)` releases the assets after `cooldownPeriod`. FIFO claim reservation in `_initiateRedemption` / `_claim`. Strategy-side surface — gates are NOT uniform: `predeposit` / `instantRedeem` / `retrieveShortfall` are gated by `onlyStrategy` (caller is a registered strategy in `_strategiesSet`, governance-managed via `addStrategy` / `removeStrategy`); `retrieveDebt(predepositId)` uses `_requireOnlyKeepers(strategy, caller)` instead, which requires the strategy to be registered AND the caller to be one of `strategy.keeper()` / `strategy.strategist()` / `management` / `governance`. The `_authorizedAddresses` allowlist (separate `EnumerableSet`, governance-managed) gates the `onlyAuthorized` ERC4626 user paths (`deposit` / `mint` / `withdraw` / `redeem` / `depositFor` / `withdrawTo`). |
| `BaseCooldownStrategy` | Kaia | Abstract base for strategies whose `want` is a `CooldownVault` share. Provides strategy-side **wrappers** that call into the underlying `CooldownVault` primitives — `premintCooldownVault(sharesNeeded)` (which internally calls `cooldownVault.deposit` and `cooldownVault.predeposit`), `repayPredepositDebt(predepositId)` (which calls `cooldownVault.retrieveDebt`), `predepositDebtRetrievable(...)` view, and a strategy-tracked `strategyShortfall` mirroring `cooldownVault.retrieveShortfall`. Also provides `estimatedTotalAssets()` view. Yearn V2 lifecycle hooks (`adjustPosition`, `prepareReturn`, `liquidatePosition`, `tendTrigger` / `harvestTrigger`) are inherited from the vendored Yearn `BaseStrategy` and overridden by concrete strategies. |
| `StrategyOriginVault` | Kaia | Yearn strategy that holds capital in `CooldownVault` shares and forwards them to `OriginVault` for crosschain deployment. **Crosschain core**. |
| `CustomYearnStrategy` | Kaia | Yearn strategy that wraps `CustomVault` shares and lets governance/strategists rebalance under the same harvest/tend lifecycle as a normal Yearn strategy. |
| `CustomVault` | Kaia | Configurable `ERC4626Upgradeable` vault. ERC4626 user paths (`deposit` / `mint` / `withdraw` / `redeem`) are gated by `onlyCustomYearnStrategy` (single bound address). Operator-side fund-routing functions (`depositToCustomStrategy(strategy, token, amount)`, `withdrawFromCustomStrategy(strategy, token, amount)`) push idle USDT into / pull from a registered `ICustomStrategy`; both are gated by CustomVault's local `onlyOperator` modifier (its own `operators` mapping + governance fallback — not the codebase-wide `onlyOperators`) and use `forceApprove(strategy, 0)` post-call to clear residual allowance (per SSA-09). `totalAssets` aggregates `ICustomStrategy(strategy).totalAssets()` over `customStrategies` array (each `ICustomStrategy` internally consults its own `IExternalAssetsProvider` — those providers are **not** directly read by `CustomVault`). The vault aggregation, registry-gating, and approval-residue handling are in scope; the registered strategies and their providers are out of scope. |
| `USDOKycedCA` | Kaia | KYC-aware mint/redeem queue for USDO. Public entries: `deposit(usdcAmt, receiver)` (`onlyStrategy nonReentrant whenNotPaused` — mints USDO via OpenEden's `USDOExpress.instantMint` internally; the `_mint` helper is internal), `redeem(usdoAmt, owner)` returning `requestId` (`onlyStrategy nonReentrant whenNotPaused`), `claim(redeemRequestId)` (no `onlyStrategy` — `nonReentrant whenNotPaused` only; takes a single `requestId` argument and has no slippage parameter — internally walks `_tryRedeemQueued` and checks dust-free / fallback paths). The `claim` function deliberately violates strict CEI; its `nonReentrant` is documented as security-critical in-source. Depends on OpenEden's KYC list — the protocol address must remain on it (SUA-37). |

> **Reference samples kept in-tree but out of scope:** `CustomStrategy.sol` (canonical `ICustomStrategy` impl) and `SimpleExternalAssetsProvider.sol` (clean `IExternalAssetsProvider` reference) are retained so reviewers can trace `RemoteVault.totalAssets()` aggregation and `CustomVault` provider semantics. They are **not** deployed in the in-scope path; findings against them must demonstrate impact propagating into an in-scope vault.

### 3.2 Crosschain Vaults & Adapter (in scope)

| Contract | Chain | Role |
|----------|-------|------|
| `OriginVault` | Kaia | ERC-7540-style async vault (deviates from the ERC-7540 spec: `redeem()` takes `requestId` rather than `shares`). Only accepts deposits from whitelisted shareholders via `onlyWhitelistedShareholder` (in practice, `StrategyOriginVault`). Bridges assets to Ethereum via `depositToRemote()` and runs the FIFO redemption queue (`requestRedeem` → `processRedemptionQueue` → `batchFulfillRedemptions`). |
| `RemoteVault` | Ethereum | Counter-party vault on Ethereum. Receives bridged **USDT** (the only crosschain-routed asset) and aggregates yield from `CustomStrategy` deployments (USDC Multi-Morpho, USDT Multi-Morpho, Pendle PT-USDG) registered directly via `_calculateCustomStrategyAssets()`. Holds both `idleUsdc` and `idleUsdt` balances; **USDC is sourced by swapping bridged USDT via `UniversalSwapRouter`** when a USDC-denominated CustomStrategy needs to be funded (no USDC ever crosses chains directly). The Yearn-vault-attached forwarding path (`SuperEarnRouter` ETH → `CooldownVault` → Yearn → `StrategyMorphoV2Vault`) is **currently unfunded**. The bridge-receiving (USDT), USDT↔USDC swap glue, custom-strategy aggregation accounting, and emergency-exit surface on `RemoteVault` are in scope; the registered `CustomStrategy` implementations themselves are out of scope (external-yield, trust-bounded). |
| `CrosschainAdapter` | both | Owns all crosschain communication. Calls `RunespearProtocol` for messaging, manages bridge initiation and tracking, encodes/decodes the universal state snapshot. |
| `BridgeAccountant` | both | Tracks inbound/outbound bridge nonces, in-transit amounts, and reconciles them against incoming `SYNC_BRIDGED` notifications. Library `BridgeQueue` handles queue mechanics. |
| `SuperEarnMessageAgent` | both | Selector-dispatched message router. Outbound: in-scope vaults call `prepareAndSendAssets` / `sendMessage` / `sendBridgedAssets` here, which forwards to `CrosschainAdapter`. Inbound: `delegate(uint256 sourceChainId, bytes4 predicate, bytes args, bytes32 messageId, RunespearMessageEnvelope envelope)` is gated to the adapter (`OnlyAdapter`) and dispatches by `predicate`. The `args` parameter is unused — the actual payload is read from `envelope.payload`. Currently the only routed handler is the `WITHDRAW` predicate (`_routeWithdraw → RemoteVault.handleWithdrawRequest`); any other predicate emits `UnknownPredicateReceived` (does not revert). Deposits do NOT go through a handler function (they arrive as direct ERC20 transfers paired with a SYNC_BRIDGED notification). |

> **OOS helpers kept in-tree (compile dep of in-scope vaults):** `OraklAssetPriceConverter` (Kaia) and `AssetPriceConverter` / `UniversalSwapRouter` (Ethereum) are imported by concrete type from `OriginVault` / `RemoteVault`. They are **out of scope** as standalone targets; defects that propagate into vault accounting are evaluated under the affected vault.

### 3.3 Messaging Layer

`Runespear` is SuperEarn's CCIP wrapper. It splits the CCIP receiver/sender pattern into:

- `RunespearTransceiver` — the `RunespearReceiver` + `RunespearSender` mixin a contract inherits to send and receive Runespear messages.
- `RunespearProtocol` — encodes/decodes the `RunespearMessageEnvelope { payload, stateSnapshot }`.
- `RunespearLib` — pure helpers (selectors, encoding, etc.).
- `CCIPReceiverUpgradeable` — upgradeable variant of Chainlink's `CCIPReceiver`.

All messages flow as plain envelopes through `RunespearProtocol.RunespearMessageEnvelope { payload, stateSnapshot }`. There are no callback or round-limit semantics in the messaging layer.

---

## 4. Crosschain Messaging & Bridging

> Steps in `[brackets]` are driven by an **off-chain keeper service** (contract source out of scope; not in this repo). The bridge plumbing called by those steps — `OriginVault`, `RemoteVault`, `CrosschainAdapter`, `BridgeAccountant`, `SuperEarnMessageAgent` — is in scope.

### 4.1 Deposit flow (Kaia → Ethereum)

```
User → SuperEarnRouter (Kaia) → CooldownVault → YearnVault (Kaia)
     ↓ [keeper: harvest / tend]
     → StrategyOriginVault.adjustPosition()    (internal Yearn lifecycle hook)
       → OriginVault.deposit()                 (only StrategyOriginVault is whitelisted)
     ↓ [keeper: OriginVault.depositToRemote(amount)]
     → SuperEarnMessageAgent.prepareAndSendAssets(asset, amount)
     → CrosschainAdapter.sendAssets(token, amount, destChainId)
                                                (Bridge: USDT only via Rhino smart-deposit;
                                                 `bridgeToken` is `immutable address` set at
                                                 constructor — CrosschainAdapter does NOT route USDC.
                                                 paired SYNC_BRIDGED CCIP message piggybacked)
=========================================== Ethereum
     ── Asset arrival is NOT a contract callback — the Rhino bridge service executes a plain
        ERC20 transfer of USDT to the RemoteVault address. The
        `CrosschainAdapter.onBridgeReceived(...)` external function exists for interface
        compatibility but currently `revert NotImplemented()` and is never called by the bridge.
     ── The paired SYNC_BRIDGED CCIP envelope flows: CCIP → CrosschainAdapter._handle
        → _handleBridged → _tryProcessBridgeNotification. If the local balance already covers the
        notification, `_processBridgeReceived` settles immediately; otherwise it is queued in
        `BridgeAccountant._awaitingAssetQueue` and `processPendingBridgeAssets()` (`onlyOperators`)
        reconciles later — the system is order-independent w.r.t. asset arrival vs. SYNC_BRIDGED.
     ↓ [keeper: route the bridged USDT into a registered CustomStrategy:
        - if the strategy is USDT-base: deposit directly
        - if the strategy is USDC-base: swap USDT→USDC via UniversalSwapRouter, then deposit
        (RemoteVault may transiently hold idle USDT/USDC between steps, but this is just an
         intermediate state, not the destination.)
        (The Yearn-attached path via SuperEarnRouter→CooldownVault→Yearn→Strategy is currently
         UNFUNDED and not used.)]
```

### 4.2 Withdrawal flow (Ethereum → Kaia)

```
User → SuperEarnRouter.redeem(yVault, yShares, receiver, minAssetsOut)
                                                  (Kaia user entry; returns requestId)
     → IVault(yVault).withdraw(yShares, address(router), 10_000)
                                                  (Yearn vault returns CooldownVault shares to
                                                   the router; if Yearn idle is insufficient, the
                                                   Yearn lifecycle pulls from strategies — see
                                                   sibling chain below)
     → CooldownVault.redeem(cooldownShares, receiver, address(router))
                                                  (initiates cooldown; returns requestId; CooldownVault
                                                   `redeem`/`withdraw` return a `requestId` rather than
                                                   assets — this is the deviation from standard ERC4626;
                                                   gated by `onlyAuthorized` so router must be in the
                                                   `_authorizedAddresses` set)

  Sibling chain (Yearn-vault → strategies, when idle is insufficient at withdraw time):

     → StrategyOriginVault.liquidatePosition(...)   (internal Yearn lifecycle hook)
       → OriginVault.requestRedeem(shares, controller, owner)
                                                    [ERC-7540-style async; locks `requestedAssets`
                                                     via `convertToAssets(shares)` at request time]
     ↓ [keeper: OriginVault.processRedemptionQueue(maxAmountUsdt, maxCount)
        — sends WITHDRAW envelope via CrosschainAdapter.sendMessage]
=========================================== Ethereum
     → CCIP delivery → CrosschainAdapter._handle → SuperEarnMessageAgent._routeWithdraw
     → RemoteVault.handleWithdrawRequest(neededUsdt)   [increments unfulfilledWithdrawalAmount]
     ↓ [keeper: source USDT liquidity — RemoteVault's idle USDT balance, or unwind a registered
        CustomStrategy via its withdraw path (proceeds may need a swap to USDT before bridging
        since only USDT is crosschain-routed). The Yearn-attached pipeline is unfunded.]
     ↓ [keeper: RemoteVault.fulfillPendingWithdrawals()
        → CrosschainAdapter.sendAssets(...)           (bridge USDT back to Kaia)]
=========================================== Kaia
     ── USDT arrives at the OriginVault address via the bridge service (Rhino) as a plain ERC20
        transfer — no contract callback. The Kaia-side `CrosschainAdapter.onBridgeReceived(...)`
        also `revert NotImplemented()`. The paired SYNC_BRIDGED CCIP envelope is reconciled the
        same way as the Ethereum side: `_handleBridged` → `_tryProcessBridgeNotification` →
        `_awaitingAssetQueue` → `processPendingBridgeAssets()` if needed.
     ↓ [keeper: OriginVault.batchFulfillRedemptions(maxAmountUsdt, maxCount)]
     ↓ [keeper: CooldownVault.claim(requestId, maxLossBps) — keeper drives the final claim
        for matured redemptions; assets transfer to the original `request.receiver` (the user's
        chosen `receiver` from the initial `SuperEarnRouter.redeem(...)` call). The `claim`
        function is not gated by `onlyAuthorized`, but high-slippage claims (`maxLossBps >
        maxLossThresholdBps`) revert unless `_msgSender() == request.receiver`.]
     → User receives the underlying asset at `receiver` (no further user action required)
```

### 4.3 Bridge accounting

`BridgeAccountant` (with `BridgeQueue` library) tracks two independent nonce streams per chain:

- **Outbound pending** — nonces of bridges this chain initiated, awaiting a `SYNC_BRIDGED` ack from the peer.
- **Inbound awaiting delivery** — `SYNC_BRIDGED` notifications received from the peer whose corresponding ERC20 transfer has not yet been credited to the local vault's balance. Held in `_awaitingAssetQueue` and drained by `processPendingBridgeAssets()` once the balance covers the notification (recall: `CrosschainAdapter.onBridgeReceived(...)` is currently `revert NotImplemented()` — there is no callback from the bridge service, so detection is purely balance-based).

Properties:

- The CCIP `SYNC_BRIDGED` notification and the bridge ERC20 transfer can arrive in either order. The system is order-independent: if the transfer arrives first, the notification's `_tryProcessBridgeNotification` settles it immediately; if the notification arrives first, it is parked in `_awaitingAssetQueue` and `processPendingBridgeAssets()` (`onlyOperators`) drains the queue once balances cover it.
- The Rhino bridge service does **not** call back into SuperEarn — it performs a plain ERC20 transfer of USDT to the destination vault. The `CrosschainAdapter.onBridgeReceived(...)` external function is currently a no-op (`revert NotImplemented()`) kept for interface compatibility only.
- Each inbound notification requires `totalBalance >= notification.amount` exactly (`_tryProcessBridgeNotification`). Bridge-fee variance is absorbed at the protocol level by the operator's deposit-balance buffer.
- `SYNC_BRIDGED` notifications cannot double-credit because each operation nonce is tracked once in `BridgeQueue` and the lists are piggybacked-synchronized via `StateSnapshot` on every message.

---

## 5. Role-Based Access Control

| Role | Holder | Power |
|------|--------|-------|
| `GOVERNANCE_ROLE` | 4-of-5 Gnosis Safe (Kaia: `0x694B81Db...d5f05`, Ethereum: `0xce6917FF...897f2f`) | Critical settings, upgrades, role assignments, emergency exits. Also owns `ProxyAdmin` on both chains. |
| `MANAGEMENT_ROLE` | 2-of-3 Gnosis Safe | Operational role gating `onlyManagers` (and the manager-side branch of `onlyOperators`). For the exact set of guarded entry points, see `SuperEarnAccessControl` and the per-contract source. |
| `KEEPER_ROLE` | Off-chain keeper service (contracts `LightKeeper` / `CrosschainKeeper` are out of scope and not included in this repo) | Automated maintenance — `harvest`, `tend`, claim cooldowns, bridge initiation, redemption fulfillment. |
| `STRATEGIST_ROLE` | Management Safe | Builds calldata for `CustomStrategy.submitExecution()` within the registered execution allowlist and `assetsChangeTolerance`. The role operates on **all** `CustomStrategy` deployments (Kaia Yield8 + the funded Ethereum USDC/USDT Multi-Morpho and Pendle PT-USDG deployments) — those strategies are out of scope for this bounty round, but the role still operates on them in production. |
| `SYSTEM_CONTRACT_ROLE` | Internal contracts | Cross-contract entry points used by other in-scope SuperEarn contracts (e.g. `CrosschainAdapter ↔ SuperEarnMessageAgent ↔ vault` dispatch via `delegate` / `sendMessage`; `RemoteVault.handleWithdrawRequest` is gated to the agent). Externally-callable surfaces are OOS unless an unauthorized address can reach them. |

**Two-step governance transfers** are required throughout the codebase. The accept-side function name is **not uniform** — most contracts (`CooldownVault`, `USDOKycedCA`, `CustomStrategy`) use `acceptGovernanceTransfer()`, while `CustomVault` uses `acceptGovernance()`. Either way the new governance must explicitly accept; pending → effective is never automatic. There is **no on-chain timelock** on top of the multisig — this trade-off is documented and out of scope for the bug-bounty (see [BUG_BOUNTY.md](./BUG_BOUNTY.md)).

### Keeper responsibilities (off-chain service, contracts OOS)

The `LightKeeper` (Yearn-layer maintenance — harvest / tend / `quickClaims` / `quickRetrieveDebts` / `harvestWithRatioManagement`) and `CrosschainKeeper` (bridge initiation, redemption-queue processing, fulfillment, swap routing, CCIP retry) drive operational cadence. Both contracts and their function surfaces are **out of scope** for this bug bounty and have been **removed from this repository**. They are listed here only so reviewers understand which entry points the bridge / vault contracts in scope expect to be called by `KEEPER_ROLE`. A finding where an unauthorized address can call a keeper-only function on an in-scope contract (`OriginVault`, `RemoteVault`, `CrosschainAdapter`, `BridgeAccountant`, `SuperEarnMessageAgent`) is in scope; a finding that requires the keeper itself to act maliciously is out of scope (see [BUG_BOUNTY.md → Trust Assumptions](./BUG_BOUNTY.md)).

---

## 6. Repository Layout

```
src/
├── superearn/
│   ├── api/
│   │   └── USDOExpressV2API.sol         # OpenEden USDOExpressV2 bindings (used by USDOKycedCA)
│   ├── core/
│   │   ├── CooldownVault.sol            # ✅ Two-step withdraw vault (Kaia, in scope)
│   │   ├── lib/
│   │   │   └── TimelockExecutionLib.sol # Used by BaseCooldownStrategy
│   │   ├── minter/
│   │   │   └── USDOKycedCA.sol          # ✅ KYC-aware USDO mint/redeem queue (Kaia, in scope)
│   │   └── strategy/
│   │       ├── BaseCooldownStrategy.sol # Abstract base for in-scope Yearn strategies
│   │       ├── StrategyOriginVault.sol  # ✅ Crosschain bridge strategy (Kaia, in scope)
│   │       └── custom/
│   │           ├── CustomVault.sol      # ✅ Composable ERC4626 (Kaia, in scope)
│   │           ├── CustomYearnStrategy.sol         # ✅ CustomVault → Yearn wrapper (Kaia, in scope)
│   │           ├── CustomStrategy.sol              # ⓘ reference impl (OOS, kept for review continuity)
│   │           └── SimpleExternalAssetsProvider.sol # ⓘ reference IExternalAssetsProvider impl (OOS)
│   ├── external/
│   │   └── orakl/                       # Orakl feed interfaces (transitive dep of OraklAssetPriceConverter)
│   ├── interface/                       # Cross-cutting interfaces (IVault, IStrategy, IHealthCheck, …)
│   ├── periphery/
│   │   ├── SuperEarnRouter.sol          # ✅ User-facing deposit/withdraw entry (Kaia, in scope — High)
│   │   └── TransparentUpgradeableProxy.sol
│   └── v2/
│       ├── base/                        # SuperEarnAccessControl, RemoteVaultStorageGap
│       ├── core/
│       │   ├── crosschain/              # ✅ CrosschainAdapter / BridgeAccountant / BridgeQueue / SuperEarnMessageAgent (in scope)
│       │   └── vaults/                  # ✅ OriginVault / OriginVaultBase / RemoteVault (in scope)
│       ├── interfaces/                  # ICrosschainAdapter, ICustomStrategy, IExternalAssetsProvider, …
│       ├── libraries/
│       │   └── VaultStateHelper.sol
│       ├── messaging/
│       │   ├── SuperEarnV2Protocol.sol
│       │   ├── ccip/CCIPReceiverUpgradeable.sol
│       │   └── runespear/               # ✅ Runespear envelope encode/decode + transceiver (in scope)
│       └── periphery/
│           ├── AssetPriceConverter.sol  # ⓘ OOS helper kept (RemoteVault concrete import)
│           ├── OraklAssetPriceConverter.sol # ⓘ OOS helper kept (OriginVault concrete import)
│           └── UniversalSwapRouter.sol  # ⓘ OOS helper kept (RemoteVault concrete import)
└── yearn-vaults/
    └── BaseStrategy.sol                 # Yearn V2 abstract strategy (vendored)
```

Legend: ✅ in scope · ⓘ kept in repo but out of scope (compile dep or reference sample). All other files are interfaces / base contracts / libraries that compile-support the in-scope contracts.

**Removed from this repo (out of scope):**
- Strategies: `StrategyUSDOExpressV2`, `StrategyMorphoV2Vault`
- CustomStrategy assets providers / helpers: `Yield8AssetsProvider`, `CustomStrategyHelper`, `morpho/`, `pendle-usdg/`
- Keepers and managers: `LightKeeper`, `CrosschainKeeper`, `YearnVaultManager`
- HealthCheck: concrete `HealthCheck.sol` and Yearn-vendored `CommonHealthCheck.sol` (only the `IHealthCheck` interface is kept; in-scope contracts import the interface only)
- Orphan interfaces: `IMorphoBlue`, `IPendle`, `IQuoterV2`, `INeutrl`, `IFluidDex`, `IStakedUSDe`, `IAssetSwapper`, `ICusdoToken`, `ICustomStrategyHelper`, `IYearnVaultManager`

The deployed `Vault.vy` and `Registry.vy` Vyper contracts are unmodified upstream Yearn V2 code and are explicitly **out of scope**. They are not included in this repository.

---

## 7. Build & Setup

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge` >= 0.2.0, with Solc 0.8.29 available)
- Node.js >= 18 and either `yarn` or `pnpm`
- Git (for submodule cloning)

### Install dependencies

```bash
# Clone with submodules (forge-std, metamorpho)
git submodule update --init --recursive

# Install npm packages (OpenZeppelin, Chainlink, Uniswap, Orakl, etc.)
yarn install
```

### Build

```bash
forge build
```

The default profile enables `via_ir = true`, which is required because several crosschain contracts (`CrosschainAdapter`, `BridgeAccountant`, `RemoteVault`) trip the legacy stack-too-deep limit. Compilation should finish without errors (a handful of `forge lint` notes about hashing and unused imports are expected).

### Configuration

- `foundry.toml` — pinned to Solc 0.8.29, EVM version `Cancun`, optimizer `runs = 250`, `via_ir = true`, line length 120.
- `remappings.txt` — includes `@superearn/`, `@yearn-vaults/`, `@external/`, `@runespear/` plus the OpenZeppelin / Chainlink / Uniswap / forge-std mappings.

### Targeted/incremental builds

```bash
# Only re-compile a specific file or directory while iterating
forge build src/superearn/v2/core/vaults/RemoteVault.sol
forge build src/superearn/core/strategy/custom/
```

### Reproducing PoCs

This repository ships with the contract source only — there is **no bundled test suite**. Researchers reporting a finding are expected to bring their own Foundry test, ideally executed against a forked chain so the on-chain state of the deployed system is part of the test fixture.

Suggested PoC layout:

```solidity
// test/PoC.t.sol
import "forge-std/Test.sol";

contract PoC is Test {
    address constant ORIGIN_VAULT = 0x3B37DB3AC2a58f2daBA1a7d66d023937d61Fc95b; // Kaia
    uint256 constant FORK_BLOCK    = <pinned-block-number>;

    function setUp() public {
        // Pin a specific block so the report stays replayable months later.
        vm.createSelectFork(vm.envString("KAIA_RPC_URL"), FORK_BLOCK);
    }

    function test_PoC() public {
        // 1. Reproduce the precondition (fund attacker, set state)
        // 2. Trigger the vulnerable path against the live deployed contract
        // 3. Assert the impact (drained balance, broken invariant, ...)
    }
}
```

Submission checklist:

- **Pin a fork block.** Reports that "worked at the time" but cannot be re-run are hard to triage.
- **Use the deployed proxy addresses** in [`DEPLOYED_CONTRACTS.md`](./DEPLOYED_CONTRACTS.md). Do not redeploy the contracts locally and exploit your own deployment — the trust assumptions only apply to the live deployment configuration.
- **Use `vm.prank` only for the role you claim the attacker controls.** Pranking `GOVERNANCE_ROLE` / `MANAGEMENT_ROLE` / `KEEPER_ROLE` / `STRATEGIST_ROLE` makes the finding out of scope (see [BUG_BOUNTY.md → Trust Assumptions](./BUG_BOUNTY.md)).
- **Match the build environment.** Solidity `0.8.29`, EVM `Cancun`, optimizer runs `250`, `via_ir = true` — see the Build Environment table in `BUG_BOUNTY.md`.
- **Include the test file** alongside the written report.

---

## 8. Operational Workflows

> The detailed daily ops, emergency exit, and manual intervention runbooks live in the protocol team's private operations repo. The summary below is intended as a high-level orientation for security researchers. Keeper contracts (`LightKeeper`, `CrosschainKeeper`) are out of scope and not included in this repository; the entry points they call on in-scope vaults are listed below for context.

### Daily flow (entry points the off-chain keeper service drives)

1. **Kaia harvest / tend / claim cycle** — keeper batches `harvest()` / `tend()` on Yearn strategies, processes matured `CooldownVault.claim()` redemptions, and pulls `predeposit` debt back via `retrieveDebt()`.
2. **Kaia → ETH bridging** — once `OriginVault` idle balance crosses the off-chain-policy threshold, keeper calls `OriginVault.depositToRemote(amount)` which triggers `CrosschainAdapter.sendAssets(token=USDT, amount, ETH)` (USDT via Rhino smart-deposit; `bridgeToken` is `immutable` and only USDT is supported) and a paired SYNC_BRIDGED CCIP message.
3. **Ethereum bridge reception** — bridge service performs a plain ERC20 transfer of USDC/USDT directly to `RemoteVault` (no contract callback); the paired `SYNC_BRIDGED` CCIP envelope is reconciled by `CrosschainAdapter._handle` → `_handleBridged` → `_tryProcessBridgeNotification`, with `processPendingBridgeAssets()` (`onlyOperators`) draining the `_awaitingAssetQueue` if the notification arrived before the assets. There is no `handleDeposit` handler and no separate `DEPOSIT` envelope — deposit-direction transfers are detected purely by `SYNC_BRIDGED` + balance reconciliation.
4. **Ethereum strategy deployment** — capital is held in `RemoteVault` and rebalanced by the keeper into the funded `CustomStrategy` deployments (USDC MM, USDT MM, Pendle PT-USDG). The Yearn-vault-attached path (`SuperEarnRouter` ETH → `CooldownVault` → Yearn → `StrategyMorphoV2Vault`) is **dormant**.
5. **Withdrawal cycle** — `StrategyOriginVault.liquidatePosition()` triggers `OriginVault.requestRedeem()` which enqueues. Keeper calls `OriginVault.processRedemptionQueue(maxAmountUsdt, maxCount)` to send the WITHDRAW envelope via CCIP. Once bridged USDT arrives on Kaia, keeper calls `OriginVault.batchFulfillRedemptions(maxAmountUsdt, maxCount)` and users claim via `CooldownVault.claim(requestId)`.

### Recovery handles (in-scope, governance/management gated)

- `CrosschainAdapter.processPendingBridgeAssets()` — reconcile when SYNC_BRIDGED arrives before the bridge transfer (callable by `onlyOperators`).
- `CrosschainAdapter.sendSyncNoop()` — force a fresh state-snapshot sync without payload.
- `CrosschainAdapter.retryFailedMessage(bytes32 messageId)` — re-execute a CCIP message that failed during dispatch (`onlyOperators`, `nonReentrant`).
- `CrosschainAdapter.removeFailedMessage(bytes32 messageId)` — abandon a failed CCIP message (`onlyManagers`).
- `CrosschainAdapter.forceProcessBridgeReceipt(...)` — manually replay a bridge receipt.
- `CrosschainAdapter.setBridgeDepositAddress(address)` — rotate Rhino smart-deposit destination (`onlyGovernance`).
- `CrosschainAdapter.sweepToken` / `sweepEth` — withdraw stranded balances (`onlyGovernance`).
- `RemoteVault.emergencyBridgeAssetsToOrigin(uint256 amount)` — Governance-only stuck-fund rescue path (push assets back to Kaia).
- `RemoteVault.emergencyRecoverToken(token, to, amount)` — recover stuck non-USDC/USDT tokens (`onlyGovernance`).
- `OriginVault.emergencyRecoverToken(token, to, amount)` — recover stuck non-vault tokens on the Kaia side (`onlyGovernance`).
- `OriginVault.withdrawFromRemote(uint256 usdtAmount)` — manually trigger a WITHDRAW message (`onlyOperators`).
- `CooldownVault.recover()` / `recoverClaimLoss()` — withdraw idle USDC respecting outstanding reservations / mint replacement shares to governance after a claim shortfall (`onlyGovernance`; SUA-01 acknowledged).

---

## 9. Trust Assumptions

- **Governance / Management multisigs** are trusted not to act maliciously. The protocol uses a 4/5 Gnosis Safe for `GOVERNANCE_ROLE` and a 2/3 Gnosis Safe for `MANAGEMENT_ROLE`. There is no on-chain timelock on top of the multisig.
- **Keepers** (`LightKeeper`, `CrosschainKeeper`) are trusted to call the operations they are authorized for in a timely manner.
- **Strategists** are trusted within the bounded `CustomStrategy` execution allowlist.
- **All strategies are internally developed and operated.** New external strategies undergo a separate review before being added to the `authorizedAddresses` allowlist on `CooldownVault`.
- **Yearn V2 `Vault.vy` / `Registry.vy`** are trusted and unmodified.
- **External protocols** (Morpho, Pendle, OpenEden, Curve, Uniswap, Chainlink CCIP, Orakl, Rhino) are trusted within their documented behaviour.
- **Stablecoin issuers** (USDT, USDC, USDO) are trusted; permanent depeg is treated as systemic risk and is out of scope.
- **OpenEden KYC** — `USDOKycedCA` requires the protocol's address to remain on OpenEden's KYC allowlist.

A finding that requires a privileged role to act adversarially, that only argues "no timelock", or that hinges on an external-dependency failure is generally out of scope. See [BUG_BOUNTY.md](./BUG_BOUNTY.md) for the full eligibility matrix.

### 9.1 Vault share decimals

Decimals across the vault stack are intentionally non-uniform. Findings that simply argue "decimals are inconsistent" without showing a concrete accounting drift are out of scope.

| Vault | Underlying | Underlying decimals | Share decimals | Rationale |
|-------|------------|---------------------|----------------|-----------|
| `OriginVault` (Kaia) | USDT | 6 | 18 | OZ ERC4626 + `_decimalsOffset = 18 − assetDecimals = 12` for first-depositor inflation defense. |
| `RemoteVault` (Ethereum) | USDC + USDT (multi-asset) | 6 / 6 | n/a (non-share-issuing) | Holds bridged balances and accounts for the funded `CustomStrategy` deployments via `_calculateCustomStrategyAssets()`. Does not mint user shares directly. The Yearn-vault-attached forwarding path is unfunded and out of scope. |
| `CooldownVault` (Kaia) | USDT | 6 | 6 | `ERC20WrapperUpgradeable` 1:1 model, share decimals match underlying. Inflation defense relied on `authorizedAddresses` allowlist, not virtual shares (see SE-P2). |
| `CustomVault` (Kaia) | Per-deployment | underlying | underlying | Standard `ERC4626Upgradeable`, share decimals follow underlying. |
| Yearn V2 vaults | Various | underlying | underlying | Out of scope — unmodified Yearn upstream. |

### 9.2 Reentrancy boundary

- **User-facing entry points** are wrapped in `nonReentrant`: `CooldownVault.deposit / mint / withdraw / redeem / claim / instantRedeem / predeposit / retrieveDebt / retrieveShortfall / recover / recoverClaimLoss`; `OriginVault.deposit / mint / redeem` overloads (note: `requestRedeem` itself does NOT have `nonReentrant` — it only enqueues, no external calls); `USDOKycedCA.deposit / redeem / claim` (note: there is no public `mint` — `_mint` is an internal helper called by `deposit`); `StrategyOriginVault.adjustPosition`; `CustomVault` ERC4626 user paths and `depositToCustomStrategy` / `withdrawFromCustomStrategy`; `CrosschainAdapter.retryFailedMessage`. `USDOKycedCA.claim()` deliberately violates strict CEI; its `nonReentrant` is documented as security-critical in-source.
- **Operator/keeper-only functions** (e.g. `OriginVault.depositToRemote`, `processRedemptionQueue`, `batchFulfillRedemptions`, `withdrawFromRemote`; `RemoteVault.depositToYearn`, `withdrawFromYearn`, `fulfillPendingWithdrawals`; `CrosschainAdapter.sendAssets`, `sendMessage`, `processPendingBridgeAssets`) are **not** universally wrapped in `nonReentrant` — reentrancy resistance there is provided by `KEEPER_ROLE` gating + the trusted-keeper assumption. A finding that requires the keeper itself to reenter is out of scope.
- **Bridge / CCIP receivers** (`CrosschainAdapter.onBridgeReceived`, `CCIPReceiverUpgradeable._ccipReceive`, `SuperEarnMessageAgent.delegate`) rely on the trusted-bridge / trusted-CCIP assumption rather than on `nonReentrant`. External protocols (Chainlink CCIP, Orakl, Rhino, plus the OpenEden USDOExpressV2 path used by `USDOKycedCA`) are trusted not to reenter SuperEarn through their callbacks; findings that require one of these protocols to behave adversarially toward its caller are out of scope per the trust assumptions above.
- **Cross-contract reentrancy** across `vault → strategy → external integration → vault` is structurally bounded by (a) `CooldownVault`'s separate accounting of `underlying` vs `totalLockedAssets`, (b) the per-strategy `nonReentrant` guards on the Yearn `BaseStrategy` lifecycle hooks, and (c) the bridge-side `BridgeAccountant` dual-nonce reconciliation that makes a single message non-replayable.

### 9.3 Bridge service failure recovery

Bridge-service-level failures (Rhino smart deposit address compromised, CCIP delivery never arrives) are recovered via governance-only paths:

- `RemoteVault.emergencyBridgeAssetsToOrigin()` — manually push assets from Ethereum back to Kaia.
- `OriginVault.emergencyRecoverToken()` — recover stuck non-vault tokens.
- `CrosschainAdapter.setBridgeDepositAddress()` — rotate deposit address mid-incident (covered by SUA-53).
- `CrosschainAdapter.retryFailedMessage(bytes32)` / `sendSyncNoop()` — replay or no-op-resync stuck CCIP messages.

The bridge services themselves are trusted dependencies; permanent service failure is treated as systemic risk and is out of scope.

### 9.4 Operational parameters

The following runtime parameters are deployment-specific and may be updated by Governance or Management. Values below were verified on-chain via `cast` on `2026-05-07`; researchers should re-query the live values when reasoning about thresholds, since each is mutable through the documented governance / management paths.

| Parameter | Contract | Description | Getter | Current value |
| --- | --- | --- | --- | --- |
| `cooldownPeriod` | `CooldownVault` (Kaia) | Delay between the cooldown-initiating call (`withdraw` / `redeem`, which return a `requestId`) and the matching `claim(requestId)` | `cooldownPeriod()` | **86 400 s (24 h)** |
| Authorized addresses | `CooldownVault` (Kaia) | Allowlist gating `onlyAuthorized` ERC4626 user paths (`deposit` / `mint` / `withdraw` / `redeem` / `depositFor` / `withdrawTo`). Storage is a private `EnumerableSet` `_authorizedAddresses` (governance-managed). | `getAuthorizedAddresses()` returns the full array. There is no per-address `isAuthorized(addr)` getter — to check a specific address, enumerate the array. | (enumerate via `getAuthorizedAddresses()`) |
| Registered strategies | `CooldownVault` (Kaia) | Strategy registry — gates `onlyStrategy` paths (`predeposit` / `instantRedeem` / `retrieveShortfall`) and feeds `_requireOnlyKeepers` (used by `retrieveDebt`). Storage is a separate private `EnumerableSet` `_strategiesSet` (governance-managed via `addStrategy` / `removeStrategy`). | `isStrategy(address)` returns `bool`; `getStrategies()` returns the full array. **Distinct from the authorized-addresses set above.** | (introspect per address) |
| Whitelisted shareholders | `OriginVault` | Allowlist gating `deposit` / `mint` / `redeem` (`onlyWhitelistedShareholder` modifier) | `whitelistedShareholders(address)` returns `bool` (auto-getter on the public mapping) | (introspect per address) |
| `customYearnStrategy` binding | `CustomVault` | Single address gate (`onlyCustomYearnStrategy`) — only the bound `CustomYearnStrategy` can call `deposit` / `mint` / `withdraw` / `redeem` | `customYearnStrategy()` returns `address` | (introspect — set via `setCustomYearnStrategy(address)`, `onlyGovernance`, callable **only when the current value is `address(0)`** — effectively single-set after initial binding) |
| `profitLimitRatio` | `HealthCheck` (Kaia, Yearn `CommonHealthCheck`) — out-of-scope helper, governs in-scope Kaia strategy harvests | Max strategy profit per harvest, scaled to `MAX_BPS = 10 000` | `profitLimitRatio()` | **7** (≈ 0.07%) |
| `lossLimitRatio` | `HealthCheck` (Kaia) | Max strategy loss per harvest. Set to `0` so that any harvest with a non-zero loss reverts. Transient losses are handled operationally by temporarily disabling the health check rather than relaxing the ratio — i.e. losses never silently absorb into the share price. | `lossLimitRatio()` | **0** |
| `bridgeDepositAddress` | `CrosschainAdapter` (Kaia) | Current Rhino smart-deposit destination for outbound USDT | `bridgeDepositAddress()` | `0x80cf92840CD12365C8A292967c30CC4040008eAC` (rotates) |
| `bridgeDepositAddress` | `CrosschainAdapter` (Ethereum) | Current Rhino destination for outbound USDT bridging from `RemoteVault` back to Kaia (the in-scope `CrosschainAdapter` only routes the immutable `bridgeToken = USDT`; USDC has no in-scope bridge path in this round) | `bridgeDepositAddress()` | `0xC8a0B9D1c394D052214d030A5eCB8641960802fE` (rotates) |

> `assetsChangeTolerance` on each `CustomStrategy` deployment is configured per-strategy and is not listed here; query `assetsChangeTolerance()` on the specific strategy if relevant. The Ethereum-side `CooldownVault` / `HealthCheck` / `UniversalSwapRouter` parameters are intentionally omitted because those contracts sit on the unfunded Yearn-attached path or are OOS helpers (see [BUG_BOUNTY.md](./BUG_BOUNTY.md)).

A finding whose impact depends on a specific parameter value should state both **the value at the time of analysis** and **the threshold at which the impact materializes**. "If `assetsChangeTolerance` were set to 50%" is not a finding; "at the current `assetsChangeTolerance` of `<X bps>`, an attacker can …" is.

---

## 10. References

- **Bug Bounty Program**: [BUG_BOUNTY.md](./BUG_BOUNTY.md)
- **Deployed Addresses (in scope)**: [DEPLOYED_CONTRACTS.md](./DEPLOYED_CONTRACTS.md)
- **Public Audit Reports**: [github.com/superearn-io/superearn-audit-reports](https://github.com/superearn-io/superearn-audit-reports)
  - Certik 2026-02-19 — base + crosschain layer (52 findings)
  - Certik 2026-04-07 — Pendle PT diamond + StrategyMorphoV2Vault + CustomStrategy + RemoteVault deltas (67 findings)
  - Certik 2026-04-28 — Strategy Audit (`CustomVault` + `CustomYearnStrategy`, 18 findings; SSA-* IDs in [BUG_BOUNTY.md](./BUG_BOUNTY.md) Known Issues)
- **Networks**: Kaia (chain id 8217), Ethereum (chain id 1)
- **Bridge** (in-scope): USDT only via Rhino.fi smart-deposit address, routed by `CrosschainAdapter.sendAssets`. The protocol's crosschain transfers are USDT-only by design.
- **Messaging**: Chainlink CCIP via the Runespear protocol wrapper
