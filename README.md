# Basememe Uniswap v4 Hook

This is the Foundry project for Basememe’s Uniswap v4 hook module and the on-chain components it invokes during hook
execution (fee collection, reward distribution, and LP position management).

Dependencies are managed as git submodules under `lib/` (Foundry default). The first install requires network access.

## Requirements

- Foundry (`forge`)

## Quickstart

```bash
# Option A: clone with submodules
# git clone --recurse-submodules <repo>

# Option B: after cloning normally
./script/install-deps.sh
forge build
```

## Configuration

Deployment scripts read env vars. For convenience:

```bash
cp .env.example .env
set -a && source .env && set +a
```

## Repository Layout

- Hook: `src/v4/BasememeHook.sol`
- Fee & liquidity manager: `src/v4/BasememeLpManager.sol`
- ETH rewards vault (used for WETH unwrap payouts): `src/rewards/ProtocolRewards.sol`
- Deployment scripts: `script/`

## Hook Permissions

`BasememeHook` enables the following Uniswap v4 hook permissions (see `src/v4/BasememeHook.sol:getHookPermissions()`):

- `beforeInitialize`: prevents third parties from calling `PoolManager.initialize(...)` to create pools with this hook;
  initialization is only allowed when initiated by the hook itself via `initializePool(...)` (which is `onlyFactory`).
- `beforeAddLiquidity`: gates liquidity provisioning until the token/pool is marked “graduated”.
- `afterSwap`: triggers fee collection and reward distribution via the configured `BasememeLpManager`.

## Overview

### Architecture

- Hook responsibilities:
  - Pool creation helper: `initializePool(...)` constructs a `PoolKey` and calls `poolManager.initialize(...)`.
  - Lifecycle gating: `beforeAddLiquidity` reverts unless the pool is marked “graduated”.
  - Fee collection trigger: `afterSwap` calls the pool’s configured `BasememeLpManager` to collect/distribute fees.
- LP manager: `src/v4/BasememeLpManager.sol`
  - Holds/mints v4-periphery `PositionManager` LP positions (owned by the contract).
  - Collects fees and (if needed) swaps them into the configured paired token.
  - Distributes rewards to recipients and optionally via `ProtocolRewards` for ETH payouts.
- Rewards vault: `src/rewards/ProtocolRewards.sol`
  - Simple ETH accounting contract used when rewards are distributed as ETH (via WETH unwrap).

### Core Flows

- Pool creation:
  - `factory -> BasememeHook.initializePool(...) -> PoolManager.initialize(...) -> BasememeHook.beforeInitialize(...)`
- Swap (fee collection):
  - `PoolManager.swap(...) -> BasememeHook.afterSwap(...) -> BasememeLpManager.collectRewardsWithoutUnlock(...)`

### Security Model & Trust Boundaries

- `BasememeHook.initializePool(...)` and `BasememeHook.setTokenGraduated(...)` are restricted by `onlyFactory`.
  - The `factory` address is an immutable set at hook deployment time.
  - `setTokenGraduated` is one-way: once `true` it cannot be set back to `false`.
- `BasememeHook.afterSwap(...)`:
  - Looks up `lpManagers[poolId]`. If unset, it returns without side effects.
  - Decodes an optional `tradeReferral` from `hookData` iff `hookData.length == 32`.
  - Calls `BasememeLpManager.collectRewardsWithoutUnlock(...)`.
- `BasememeLpManager.collectRewardsWithoutUnlock(...)` is restricted by `onlyHook` (immutable hook address).

### Swap Path Call Graph

1. `PoolManager.swap(...)` triggers `BasememeHook.afterSwap(...)`.
2. `BasememeHook.afterSwap(...)` calls `BasememeLpManager.collectRewardsWithoutUnlock(...)`.
3. `BasememeLpManager` collects fees from its positions via `PositionManager.modifyLiquiditiesWithoutUnlock(...)`.
4. If fee tokens are not already the paired token, `BasememeLpManager` swaps fees via `PoolManager.swap(...)` and settles
   by paying the input token and taking the output token.
5. Rewards are distributed:
   - If paired token is WETH: unwrap and deposit ETH into `ProtocolRewards.deposit(...)`.
   - Otherwise: ERC20 transfers directly to recipients.

### Reentrancy / Recursion Notes

- `BasememeLpManager` uses:
  - `ReentrancyGuard` on its factory entrypoints.
  - An internal `_inCollect` guard inside `_collectRewards(...)` to avoid recursive collection loops (important because the
    fee conversion swap can itself trigger hook execution).

## Deploy (Hook)

Set env vars:

- `PRIVATE_KEY`: deployer EOA private key (hex, no `0x` is ok)
- `RPC_URL`: JSON-RPC URL for the target chain
- `POOL_MANAGER`: Uniswap v4 `PoolManager` address on the target chain
- `FACTORY`: your factory address that is allowed to call `initializePool` / `setTokenGraduated`

Run:

```bash
FOUNDRY_HOME=./.foundry forge script script/DeployBasememeHook.s.sol:DeployBasememeHook --rpc-url "$RPC_URL" --broadcast
```

Notes:

- `BasememeHook` inherits `BaseHook`, which validates Uniswap v4 permission bits encoded in the deployed hook address.
  `script/DeployBasememeHook.s.sol` mines a CREATE2 salt so the deployed address encodes the expected permissions.
- The deploy script uses an intermediate `BasememeHookDeployer` contract to deploy the hook with CREATE2 and then transfer
  ownership to your EOA.
- After deploying, record addresses/tx hashes in `DEPLOYMENTS.md`.

## Deploy (ProtocolRewards)

If you use WETH unwrap payouts, deploy `ProtocolRewards` (or point to an existing instance).

Set env vars:

- `PRIVATE_KEY`
- `RPC_URL`

Run:

```bash
FOUNDRY_HOME=./.foundry forge script script/DeployProtocolRewards.s.sol:DeployProtocolRewards --rpc-url "$RPC_URL" --broadcast
```

## Deploy (BasememeLpManager)

`BasememeLpManager` is called by the hook on the swap path to collect fees and distribute rewards.

Set env vars:

- `PRIVATE_KEY`
- `RPC_URL`
- `FACTORY`
- `HOOK`
- `POOL_MANAGER`
- `POSITION_MANAGER`
- `PERMIT2`
- `WETH`
- `PROTOCOL_REWARDS`

Run:

```bash
FOUNDRY_HOME=./.foundry forge script script/DeployBasememeLpManager.s.sol:DeployBasememeLpManager --rpc-url "$RPC_URL" --broadcast
```

## Development

- Format: `forge fmt`
- Tip: set `FOUNDRY_HOME=./.foundry` to keep all Foundry cache/config local to this repo (useful for CI or restricted
  environments).
