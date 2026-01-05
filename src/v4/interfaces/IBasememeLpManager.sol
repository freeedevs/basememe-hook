// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IBasememeLpManager {
    struct LiquidityConfig {
        uint256 tokenAmount;
        uint256 collateralAmount;
        address pairedToken;
        address tokenSource;
        uint160 graduationPoolPrice; // Pool price (token1/token0) at graduation
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionTokenBps;
        uint16[] positionPairedTokenBps;
    }

    struct RewardConfig {
        address[] rewardRecipients;
        uint16[] rewardBps;
        bytes4[] rewardsReasons;
    }

    struct TokenRewardInfo {
        address token;
        PoolKey poolKey;
        uint256 positionId;
        uint256 numPositions;
        uint16[] rewardBps;
        address[] rewardRecipients;
        bytes4[] rewardsReasons;
        address pairedToken;
    }

    struct PositionData {
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        bool isToken0;
    }

    function placeLiquidity(
        address token,
        PoolKey memory poolKey,
        LiquidityConfig memory lpConfig,
        RewardConfig memory rewardConfig
    ) external returns (uint256 positionId);

    /// @notice Alternative entrypoint that accepts flattened parameters instead of nested structs.
    /// @dev This exists primarily to reduce compiler IR/Yul stack complexity at the caller side.
    function placeLiquidityFlat(
        address token,
        PoolKey memory poolKey,
        uint256 tokenAmount,
        uint256 collateralAmount,
        address pairedToken,
        address tokenSource,
        uint160 graduationPoolPrice,
        int24[] memory tickLower,
        int24[] memory tickUpper,
        uint16[] memory positionTokenBps,
        uint16[] memory positionPairedTokenBps,
        address[] memory rewardRecipients,
        uint16[] memory rewardBps,
        bytes4[] memory rewardsReasons
    ) external returns (uint256 positionId);

    function collectRewardsWithoutUnlock(address token, address tradeReferral) external;

    function tokenRewards(address token) external view returns (TokenRewardInfo memory);

    function hook() external view returns (address);
}

interface IBasememeLpManagerErrors {
    error InvalidToken();
    error InvalidPoolKey();
    error InvalidAmounts();
    error LiquidityAlreadyExists();
    error LiquidityNotFound();
    error InitialReservesNotSet();
    error Unauthorized();
    error RewardNotFound();
    error InsufficientRewards();
    error CollectionInProgress();
    error InvalidRewardRecipients();
    error InvalidRewardBps();
    error FeeConversionFailed();
    error OnlyWeth();
}

interface IBasememeLpManagerEvents {
    event LiquidityPlaced(
        address indexed token,
        address indexed pairedToken,
        uint256 indexed positionId,
        uint256 tokenAmount,
        uint256 collateralAmount,
        uint256 positionCount
    );

    
    event RewardInfoUpdated(
        address indexed token,
        address[] rewardRecipients,
        uint16[] rewardBps
    );

    event FeeCollectionFailed(
        address indexed token,
        string reason
    );

    event ClaimedRewards(
        address indexed token,
        PoolKey poolKey,
        uint256 positionId,
        uint256 numPositions,
        uint16[] rewardBps,
        address[] rewardRecipients,
        bytes4[] rewardsReasons,
        address pairedToken,
        uint256 totalPairedRewards,
        uint256[] distributedAmounts
    );

    event FeesSwapped(
        address indexed token,
        address indexed fromToken,
        uint256 amountIn,
        address indexed toToken,
        uint256 amountOut
    );

    event FeeDistributed(
        address indexed token,
        address indexed recipient,
        address indexed pairedToken,
        uint256 amount
    );
}
