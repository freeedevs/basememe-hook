// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BasememeLpManager} from "../src/v4/BasememeLpManager.sol";

contract DeployBasememeLpManager is Script {
    function run() external returns (address lpManager) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerKey);

        address factory = vm.envAddress("FACTORY");
        address protocolRewards = vm.envAddress("PROTOCOL_REWARDS");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address weth = vm.envAddress("WETH");
        address permit2 = vm.envAddress("PERMIT2");
        address hook = vm.envAddress("HOOK");

        vm.startBroadcast(deployerKey);
        BasememeLpManager manager = new BasememeLpManager(
            owner, factory, protocolRewards, poolManager, positionManager, weth, permit2, hook
        );
        vm.stopBroadcast();

        lpManager = address(manager);
        console2.log("BasememeLpManager:", lpManager);
    }
}

