// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IBasememeLpManager, IBasememeLpManagerErrors, IBasememeLpManagerEvents} from "./interfaces/IBasememeLpManager.sol";
import {IProtocolRewards} from "../rewards/interfaces/IProtocolRewards.sol";
import {TokenConstants} from "../utils/TokenConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v3-core/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/libraries/FixedPoint96.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

contract BasememeLpManager is
    IBasememeLpManager,
    IBasememeLpManagerErrors,
    IBasememeLpManagerEvents,
    Ownable,
    ReentrancyGuard,
    IERC721Receiver,
    TokenConstants
{
    error TickOutOfBounds();
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    uint256 public constant MAX_LP_POSITIONS = 10;
    uint256 public constant BASIS_POINTS = 10_000;

    // Immutable addresses
    address public immutable factory;
    address public immutable weth;
    address public immutable protocolRewards;
    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IPermit2 public immutable permit2;
    address public immutable hook;

    // State
    mapping(address token => TokenRewardInfo rewardInfo) internal _tokenRewards;

    // Guard to stop recursive collection calls
    bool internal _inCollect;

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert Unauthorized();
        _;
    }

    constructor(
        address _owner,
        address _factory,
        address _protocolRewards,
        address _poolManager, // address of the pool manager
        address _positionManager, // Address of the position manager
        address _weth,
        address permit2_, // address of the permit2 contract
        address _hook // address of the hook
    ) Ownable(_owner) {
        factory = _factory;
        protocolRewards = _protocolRewards;
        weth = _weth;
        poolManager = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);
        permit2 = IPermit2(permit2_);
        hook = _hook;
    }

    function tokenRewards(
        address token
    ) external view returns (TokenRewardInfo memory) {
        return _tokenRewards[token];
    }

    /**
     * @dev Places single-sided liquidity in a V4 pool based on the provided liquidity configuration
     * @param token The freee token address
     * @param poolKey The V4 pool key
     * @param lpConfig Liquidity configuration containing token amounts and pricing data
     * @param rewardConfig Reward configuration for fee distribution
     * @return positionId The ID of the created liquidity position
     */
    function placeLiquidity(
        address token,
        PoolKey memory poolKey,
        LiquidityConfig memory lpConfig,
        RewardConfig memory rewardConfig
    ) external onlyFactory nonReentrant returns (uint256) {
        return _placeLiquidity(token, poolKey, lpConfig, rewardConfig);
    }

    /**
     * @dev Alternative entrypoint that accepts flattened parameters instead of nested structs.
     *      This helps reduce IR/Yul stack complexity at the caller side.
     */
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
    ) external onlyFactory nonReentrant returns (uint256) {
        LiquidityConfig memory lpConfig = LiquidityConfig({
            tokenAmount: tokenAmount,
            collateralAmount: collateralAmount,
            pairedToken: pairedToken,
            tokenSource: tokenSource,
            graduationPoolPrice: graduationPoolPrice,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionTokenBps: positionTokenBps,
            positionPairedTokenBps: positionPairedTokenBps
        });

        RewardConfig memory rewardConfig = RewardConfig({
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            rewardsReasons: rewardsReasons
        });

        return _placeLiquidity(token, poolKey, lpConfig, rewardConfig);
    }

    /**
     * @dev Core implementation for placing single-sided liquidity.
     */
    function _placeLiquidity(
        address token,
        PoolKey memory poolKey,
        LiquidityConfig memory lpConfig,
        RewardConfig memory rewardConfig
    ) internal returns (uint256) {
        // Validate inputs
        if (token == address(0)) {
            revert InvalidToken();
        }
        if (lpConfig.tokenAmount == 0 || lpConfig.collateralAmount == 0) {
            revert InvalidAmounts();
        }
        if (rewardConfig.rewardRecipients.length == 0) {
            revert InvalidRewardRecipients();
        }
        if (rewardConfig.rewardBps.length != rewardConfig.rewardRecipients.length) {
            revert InvalidRewardBps();
        }

        uint256 totalBps = 0;
        for (uint256 i = 0; i < rewardConfig.rewardBps.length; i++) {
            totalBps += rewardConfig.rewardBps[i];
        }
        if (totalBps != MAX_BPS) {
            revert InvalidRewardBps();
        }

        // ensure that we don't already have a reward for this token
        if (_tokenRewards[token].positionId != 0) {
            revert LiquidityAlreadyExists();
        }

        // create the reward info
        TokenRewardInfo memory tokenRewardInfo = TokenRewardInfo({
            token: token,
            poolKey: poolKey,
            positionId: 0, 
            numPositions: 0,
            rewardBps: rewardConfig.rewardBps,
            rewardRecipients: rewardConfig.rewardRecipients,
            rewardsReasons: rewardConfig.rewardsReasons,
            pairedToken: lpConfig.pairedToken
        });

        // pull in the token and mint liquidity
        IERC20(token).safeTransferFrom(lpConfig.tokenSource, address(this), lpConfig.tokenAmount);
        IERC20(lpConfig.pairedToken).safeTransferFrom(lpConfig.tokenSource, address(this), lpConfig.collateralAmount);

        (uint256 positionId, uint256 positionCount, uint256 tokenDust, uint256 pairedDust) = _mintLiquidity(
            token,
            poolKey,
            lpConfig
        );

        // store the reward info
        tokenRewardInfo.positionId = positionId;
        tokenRewardInfo.numPositions = positionCount;
        _tokenRewards[token] = tokenRewardInfo;

        emit LiquidityPlaced(
            token,
            lpConfig.pairedToken,
            positionId,
            lpConfig.tokenAmount,
            lpConfig.collateralAmount,
            positionCount
        );

        // Emit detailed diagnostics for consumption vs provided
        unchecked {
            uint256 usedToken = lpConfig.tokenAmount - tokenDust;
            uint256 usedPaired = lpConfig.collateralAmount - pairedDust;
            emit LiquidityPlacementDetails(
                token,
                lpConfig.pairedToken,
                positionId,
                positionCount,
                lpConfig.tokenAmount,
                usedToken,
                tokenDust,
                lpConfig.collateralAmount,
                usedPaired,
                pairedDust
            );
        }
        return positionId;
    }

    
    /**
     * @dev Collects rewards for a token (without pool unlock, for hook calls)
     * @param token The token address
     * @param tradeReferral The trade referral address
     */
    function collectRewardsWithoutUnlock(
        address token,
        address tradeReferral
    ) external onlyHook {
        _collectRewards(token, tradeReferral);
    }

    /**
     * @dev Internal function to collect rewards (always without unlock for hook calls)
     * @param token The token address
     * @param tradeReferral The trade referral address
     */
    function _collectRewards(
        address token,
        address tradeReferral
    ) internal {
        if (_inCollect) {
            // stop recursive call
            return;
        }
        _inCollect = true;

        TokenRewardInfo storage info = _tokenRewards[token];

        // Validate token exists
        if (info.positionId == 0) {
            _inCollect = false;
            return;
        }

        // Collect fees from LP position
        (uint256 amount0, uint256 amount1) = _bringFeesIntoContract(
            info.poolKey,
            info.positionId,
            info.numPositions
        );

        IERC20 rewardToken0 = IERC20(Currency.unwrap(info.poolKey.currency0));
        IERC20 rewardToken1 = IERC20(Currency.unwrap(info.poolKey.currency1));

        // Convert all fees to paired token
        uint256 totalPairedRewards = 0;

        if (amount0 > 0) {
            totalPairedRewards += _handleFees(
                token,
                address(rewardToken0),
                amount0
            );
        }

        if (amount1 > 0) {
            totalPairedRewards += _handleFees(
                token,
                address(rewardToken1),
                amount1
            );
        }

        // Distribute rewards to recipients based on BPS
        if (totalPairedRewards > 0) {
            _distributePairedTokenRewards(
                info,
                totalPairedRewards,
                tradeReferral
            );
        }

        _inCollect = false;
    }

    function _bringFeesIntoContract(
        PoolKey memory poolKey,
        uint256 positionId,
        uint256 numPositions
    ) internal returns (uint256 amount0, uint256 amount1) {
        bytes memory actions;
        bytes[] memory params = new bytes[](numPositions + 1);

        for (uint256 i = 0; i < numPositions; i++) {
            actions = abi.encodePacked(
                actions,
                uint8(Actions.DECREASE_LIQUIDITY)
            );
            // Collecting fees is achieved with liquidity=0
            params[i] = abi.encode(positionId + i, 0, 0, 0, abi.encode());
        }

        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        actions = abi.encodePacked(actions, uint8(Actions.TAKE_PAIR));
        params[numPositions] = abi.encode(currency0, currency1, address(this));

        uint256 balance0Before = IERC20(Currency.unwrap(currency0)).balanceOf(
            address(this)
        );
        uint256 balance1Before = IERC20(Currency.unwrap(currency1)).balanceOf(
            address(this)
        );

        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);

        uint256 balance0After = IERC20(Currency.unwrap(currency0)).balanceOf(
            address(this)
        );
        uint256 balance1After = IERC20(Currency.unwrap(currency1)).balanceOf(
            address(this)
        );

        return (balance0After - balance0Before, balance1After - balance1Before);
    }

    // Handle fees for a token - automatically convert to paired token
    function _handleFees(
        address token,
        address rewardToken,
        uint256 amount
    ) internal returns (uint256 pairedTokenAmount) {
        if (amount == 0) return 0;

        TokenRewardInfo storage info = _tokenRewards[token];
        address pairedToken = info.pairedToken;

        // If rewardToken is already paired token, no swap needed
        if (rewardToken == pairedToken) {
            return amount;
        }

        // Otherwise, swap to paired token (always use unlocked swap since called from hook)
        uint256 swapAmountOut = _uniSwapUnlocked(
            info.poolKey,
            rewardToken,
            pairedToken,
            uint128(amount)
        );

        emit FeesSwapped(
            token,
            rewardToken,
            amount,
            pairedToken,
            swapAmountOut
        );

        return swapAmountOut;
    }

    // Swap in unlocked state (called from within a hook)
    function _uniSwapUnlocked(
        PoolKey memory poolKey,
        address tokenIn,
        address tokenOut,
        uint128 amountIn
    ) internal returns (uint256) {
        bool zeroForOne = tokenIn < tokenOut;

        // Build swap request
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(int128(amountIn)),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        // Record before token balance
        uint256 tokenOutBefore = IERC20(tokenOut).balanceOf(address(this));

        // Execute the swap
        BalanceDelta delta = poolManager.swap(
            poolKey,
            swapParams,
            abi.encode()
        );

        // Determine swap outcomes
        int128 deltaOut = delta.amount0() < 0
            ? delta.amount1()
            : delta.amount0();

        // Pay the input token
        poolManager.sync(Currency.wrap(tokenIn));
        Currency.wrap(tokenIn).transfer(address(poolManager), amountIn);
        poolManager.settle();

        // Take out the converted token
        poolManager.take(
            Currency.wrap(tokenOut),
            address(this),
            uint256(uint128(deltaOut))
        );

        uint256 tokenOutAfter = IERC20(tokenOut).balanceOf(address(this));
        return tokenOutAfter - tokenOutBefore;
    }

    
    function _distributePairedTokenRewards(
        TokenRewardInfo storage info,
        uint256 totalAmount,
        address tradeReferral
    ) internal {
        uint256 recipientsLength = info.rewardRecipients.length;
        if (totalAmount == 0 || recipientsLength == 0) return;

        address pairedToken = info.pairedToken;
        address[] memory actualRecipients = new address[](recipientsLength);
        uint256[] memory distributedAmounts = new uint256[](recipientsLength);
        uint256 distributed = 0;

        // Distribute to all recipients except the last
        for (uint256 i = 0; i < recipientsLength - 1; i++) {
            uint16 bps = info.rewardBps[i];
            address storedRecipient = info.rewardRecipients[i];
            address recipient = storedRecipient;

            if (storedRecipient == address(0)) {
                // If no trade referral is provided, skip this slot
                // and let its theoretical share roll into the remainder
                if (tradeReferral == address(0)) {
                    actualRecipients[i] = address(0);
                    continue;
                }
                recipient = tradeReferral;
            }

            actualRecipients[i] = recipient;

            if (bps == 0) {
                continue;
            }

            uint256 distributeAmount = (totalAmount * bps) / MAX_BPS;
            if (distributeAmount == 0) {
                continue;
            }

            distributed += distributeAmount;
            distributedAmounts[i] = distributeAmount;

            if (pairedToken == weth) {
                IWETH(weth).withdraw(distributeAmount);
                IProtocolRewards(protocolRewards).deposit{
                    value: distributeAmount
                }(payable(recipient), info.rewardsReasons[i], "");
            } else {
                IERC20(pairedToken).safeTransfer(recipient, distributeAmount);
                emit FeeDistributed(
                    info.token,
                    recipient,
                    pairedToken,
                    distributeAmount
                );
            }
        }

        // Last recipient gets the remainder (handles precision loss)
        uint256 lastIdx = recipientsLength - 1;
        address lastRecipient = info.rewardRecipients[lastIdx];
        actualRecipients[lastIdx] = lastRecipient;

        uint256 remainingAmount = totalAmount - distributed;
        if (remainingAmount > 0) {
            if (pairedToken == weth) {
                IWETH(weth).withdraw(remainingAmount);
                IProtocolRewards(protocolRewards).deposit{
                    value: remainingAmount
                }(payable(lastRecipient), info.rewardsReasons[lastIdx], "");
            } else {
                IERC20(pairedToken).safeTransfer(lastRecipient, remainingAmount);

                emit FeeDistributed(
                    info.token,
                    lastRecipient,
                    pairedToken,
                    remainingAmount
                );
            }

            distributedAmounts[lastIdx] = remainingAmount;
        }

        // Emit aggregated claim event with precise per-recipient amounts and
        // rewardRecipients array reflecting actual recipients (with tradeReferral applied)
        emit ClaimedRewards(
            info.token,
            info.poolKey,
            info.positionId,
            info.numPositions,
            info.rewardBps,
            actualRecipients,
            info.rewardsReasons,
            pairedToken,
            totalAmount,
            distributedAmounts
        );
    }

    function _mintLiquidity(
        address token,
        PoolKey memory poolKey,
        LiquidityConfig memory config
    ) internal returns (uint256, uint256, uint256, uint256) {
        bool isFreeeTokenToken0 = Currency.unwrap(poolKey.currency0) == token;

        uint256 positionCount = config.tickLower.length;

        // encode actions
        bytes[] memory params = new bytes[](positionCount + 1);
        bytes memory actions;

        uint256 amount0 = isFreeeTokenToken0 ? config.tokenAmount : config.collateralAmount;
        uint256 amount1 = isFreeeTokenToken0 ? config.collateralAmount : config.tokenAmount;
        for (uint256 i = 0; i < positionCount; i++) {
            // add mint action
            actions = abi.encodePacked(actions, uint8(Actions.MINT_POSITION));

            uint16 positionToken0Bps = isFreeeTokenToken0 ? config.positionTokenBps[i] : config.positionPairedTokenBps[i];
            uint16 positionToken1Bps = isFreeeTokenToken0 ? config.positionPairedTokenBps[i] : config.positionTokenBps[i];

            // determine token amount for this position
            uint256 token0Amount = amount0 * positionToken0Bps / BASIS_POINTS;
            uint256 token1Amount = amount1 * positionToken1Bps / BASIS_POINTS;

            // determine tick bounds for this position
            int24 tickLower_ =
                isFreeeTokenToken0 ? config.tickLower[i] : -config.tickLower[i];
            int24 tickUpper_ =
                isFreeeTokenToken0 ? config.tickUpper[i] : -config.tickUpper[i];
            int24 tickLower = isFreeeTokenToken0 ? tickLower_ : tickUpper_;
            int24 tickUpper = isFreeeTokenToken0 ? tickUpper_ : tickLower_;
            uint160 lowerSqrtPrice = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 upperSqrtPrice = TickMath.getSqrtPriceAtTick(tickUpper);

            // determine liquidity amount
            uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                config.graduationPoolPrice, lowerSqrtPrice, upperSqrtPrice, token0Amount, token1Amount
            );

            params[i] = abi.encode(
                poolKey,
                tickLower, // tick lower
                tickUpper, // tick upper
                liquidity, // liquidity
                token0Amount, // amount0Max
                token1Amount, // amount1Max
                address(this), // recipient of position
                abi.encode(address(this))
            );
        }

        // add settle action
        actions = abi.encodePacked(actions, uint8(Actions.SETTLE_PAIR));
        params[positionCount] = abi.encode(poolKey.currency0, poolKey.currency1);

        // approvals
        {
            // Only approve Permit2 if needed. Some ERC20 implementations report an "infinite" allowance
            // and may revert if asked to set a smaller allowance.
            if (IERC20(token).allowance(address(this), address(permit2)) < config.tokenAmount) {
                IERC20(token).forceApprove(address(permit2), config.tokenAmount);
            }
            permit2.approve(
                token, address(positionManager), uint160(config.tokenAmount), uint48(block.timestamp)
            );

            if (IERC20(config.pairedToken).allowance(address(this), address(permit2)) < config.collateralAmount) {
                IERC20(config.pairedToken).forceApprove(address(permit2), config.collateralAmount);
            }
            permit2.approve(
                config.pairedToken, address(positionManager), uint160(config.collateralAmount), uint48(block.timestamp)
            );
        }

        // grab position id we're about to mint
        uint256 startPositionId = positionManager.nextTokenId();
        // add liquidity
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        uint256 tokenDust = IERC20(token).balanceOf(address(this));
        if (tokenDust > 0) {
            IERC20(token).safeTransfer(config.tokenSource, tokenDust);
        }
        uint256 pairedDust = IERC20(config.pairedToken).balanceOf(address(this));
        if (pairedDust > 0) {
            IERC20(config.pairedToken).safeTransfer(config.tokenSource, pairedDust);
        }

        return (startPositionId, positionCount, tokenDust, pairedDust);  // Return position ID, positions, and dust
    }

    // Detailed diagnostics for single-sided liquidity placement
    event LiquidityPlacementDetails(
        address indexed token,
        address indexed pairedToken,
        uint256 positionId,
        uint256 numPositions,
        uint256 providedTokenAmount,
        uint256 usedTokenAmount,
        uint256 tokenDust,
        uint256 providedPairedAmount,
        uint256 usedPairedAmount,
        uint256 pairedDust
    );
    /**
     * @dev Required for IERC721Receiver
     */
    function onERC721Received(
        address ,
        address ,
        uint256 ,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {
        if (msg.sender != weth) {
            revert OnlyWeth();
        }
    }
}
