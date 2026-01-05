// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

abstract contract TokenConstants {
    uint256 public constant MAX_BPS = 10_000;
    uint24 public constant MAX_LP_FEE = 300_000;               // LP fee capped at 30%

    uint256 public constant TRADE_TOKEN_CREATOR_FEE_BPS = 5000;
    uint256 public constant TRADE_PROTOCOL_FEE_BPS = 3000;
    uint256 public constant TRADE_PLATFORM_REFERRER_FEE_BPS = 1000;
    uint256 public constant TRADE_REFERRER_FEE_BPS = 1000;

    uint256 public constant LIQUIDITY_TOKEN_CREATOR_FEE_BPS = 5000;
    uint256 public constant LIQUIDITY_PROTOCOL_FEE_BPS = 3000;
    uint256 public constant LIQUIDITY_PLATFORM_REFERRER_FEE_BPS = 1000;
    uint256 public constant LIQUIDITY_TRADE_REFERRER_FEE_BPS = 1000;
}
