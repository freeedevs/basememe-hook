// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IBasememeHook, IBasememeHookErrors, IBasememeHookEvents} from "./interfaces/IBasememeHook.sol";
import {IBasememeLpManager} from "./interfaces/IBasememeLpManager.sol";

import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BasememeHook is BaseHook, Ownable, IBasememeHook, IBasememeHookErrors, IBasememeHookEvents {
    using TickMath for int24;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    using PoolIdLibrary for PoolKey;

    address public immutable factory;

    mapping(PoolId => bool) internal token0IsFreee;
    mapping(PoolId => address) public lpManagers;

    mapping(PoolId => bool) public tokenGraduated;

    modifier onlyFactory() {
        if (msg.sender != factory) {
            revert OnlyFactory();
        }
        _;
    }

    constructor(
        address _poolManager,
        address _factory
    ) BaseHook(IPoolManager(_poolManager)) Ownable(msg.sender) {
        factory = _factory;
    }

    function initializePool(
        address token,
        address pairedToken,
        int24 tickSpacing,
        address lpManager,
        uint24 lpFee,
        uint160 initialSqrtPriceX96
    ) external onlyFactory returns (PoolKey memory) {
        // Validate inputs
        if (token == address(0) || pairedToken == address(0)) {
            revert ETHPoolNotAllowed();
        }
        if (token == pairedToken) {
            revert InvalidTokenPair();
        }
        if (lpFee >= LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidLpFee();
        }

        bool isToken0Freee = token < pairedToken;

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(isToken0Freee ? token : pairedToken),
            currency1: Currency.wrap(isToken0Freee ? pairedToken : token),
            fee: lpFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });

        PoolId poolId = poolKey.toId();

        poolManager.initialize(poolKey, initialSqrtPriceX96);

        token0IsFreee[poolId] = isToken0Freee;
        lpManagers[poolId] = lpManager;

        emit PoolCreated(token, pairedToken, poolKey, lpManager, poolId, initialSqrtPriceX96);

        return poolKey;
    }

    function setTokenGraduated(PoolKey calldata poolKey, bool graduated) external onlyFactory {
        PoolId poolId = poolKey.toId();

        if (lpManagers[poolId] == address(0)) {
            revert PoolNotFound();
        }

        if (!graduated && tokenGraduated[poolId]) {
            revert TokenCannotBeUngraduated();
        }

        tokenGraduated[poolId] = graduated;

        emit TokenGraduationUpdated(poolId, graduated);
    }

    function _getTradeReferral(bytes calldata hookData) internal pure returns (address) {
        return hookData.length == 32 ? abi.decode(hookData, (address)) : address(0);
    }

    function _isTokenGraduated(PoolId poolId) internal view returns (bool) {
        return tokenGraduated[poolId];
    }

    function _afterSwap(
        address,
        PoolKey calldata poolKey,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        PoolId poolId = poolKey.toId();

        address lpManager = lpManagers[poolId];
        if (lpManager == address(0)) {
            return (BaseHook.afterSwap.selector, 0);
        }

        address freeeToken = token0IsFreee[poolId] ?
            Currency.unwrap(poolKey.currency0) :
            Currency.unwrap(poolKey.currency1);

        address tradeReferral = _getTradeReferral(hookData);

        IBasememeLpManager(lpManager).collectRewardsWithoutUnlock(freeeToken, tradeReferral);

        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160)
        internal
        virtual
        override
        returns (bytes4)
    {
        // PoolManager passes the original caller of `PoolManager.initialize(...)` as `sender`.
        // We only allow pool initialization when it is initiated by this hook contract itself
        // (i.e., via `initializePool(...)`, which is restricted by `onlyFactory`).
        if (sender != address(this)) {
            revert UnsupportedInitializePath();
        }

        return BaseHook.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual override returns (bytes4) {
        if (!_isTokenGraduated(poolKey.toId())) {
            revert TokenNotGraduated();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
