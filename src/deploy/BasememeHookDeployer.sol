// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BasememeHook} from "../v4/BasememeHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract BasememeHookDeployer {
    function deploy(bytes32 salt, address poolManager, address factory, address owner) external returns (BasememeHook) {
        BasememeHook hook = new BasememeHook{salt: salt}(poolManager, factory);
        hook.transferOwnership(owner);
        return hook;
    }
}

