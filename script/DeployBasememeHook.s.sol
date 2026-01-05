// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {BasememeHook} from "../src/v4/BasememeHook.sol";
import {BasememeHookDeployer} from "../src/deploy/BasememeHookDeployer.sol";

/// @notice Deploys BasememeHook to an address whose low bits match the hook permission flags.
/// @dev Uses a small deployer contract so BasememeHook ownership can be transferred to your EOA.
contract DeployBasememeHook is Script {
    function run() external returns (address hookAddress, bytes32 salt, address deployerContract) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerKey);

        address poolManager = vm.envAddress("POOL_MANAGER");
        address factory = vm.envAddress("FACTORY");

        vm.startBroadcast(deployerKey);

        BasememeHookDeployer deployer = new BasememeHookDeployer();
        deployerContract = address(deployer);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(poolManager, factory);
        (hookAddress, salt) = HookMiner.find(deployerContract, flags, type(BasememeHook).creationCode, constructorArgs);

        BasememeHook hook = deployer.deploy(salt, poolManager, factory, owner);
        require(address(hook) == hookAddress, "DeployBasememeHook: hook address mismatch");

        vm.stopBroadcast();

        console2.log("BasememeHookDeployer:", deployerContract);
        console2.log("BasememeHook:", hookAddress);
        console2.logBytes32(salt);
    }
}

