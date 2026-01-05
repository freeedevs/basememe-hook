// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IBasememeHook {
    function initializePool(
        address token,
        address pairedToken,
        int24 tickSpacing,
        address lpFeeManager,
        uint24 lpFee,
        uint160 initialSqrtPriceX96
    ) external returns (PoolKey memory);

    function setTokenGraduated(PoolKey calldata poolKey, bool graduated) external;
}

interface IBasememeHookErrors {
    error ETHPoolNotAllowed();
    error WethCannotBeClanker();
    error UnsupportedInitializePath();
    error OnlyFactory();
    error PoolNotFound();
    error PoolAlreadyExists();
    error InvalidTokenPair();
    error TokenNotGraduated();
    error TokenCannotBeUngraduated();
    error OnlyProtocolCanAddInitialLiquidity(address,address);
    error LpManagerNotSet();
    error InvalidLpFee();
    error OnlyLpManagerCanAddInitialLiquidity(address required, address actual);
}

interface IBasememeHookEvents {
    event PoolCreated(
        address indexed token,
        address indexed pairedToken,
        PoolKey poolKey,
        address indexed lpFeeManager,
        PoolId poolId,
        uint160 initialSqrtPriceX96
    );

    event ProtocolFeesCollected(
        address indexed token,
        address indexed currency,
        uint256 amount
    );

    event TokenGraduationUpdated(PoolId indexed poolId, bool graduated);

    event LpFeeCollectionTriggered(
        address indexed token,
        address indexed lpFeeManager
    );

    event InitialLiquidityAdded(
        address indexed token,
        address indexed pairedToken,
        uint256 amount0,
        uint256 amount1
    );
}
