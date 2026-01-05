// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ProtocolRewards} from "../src/rewards/ProtocolRewards.sol";

contract DeployProtocolRewards is Script {
    function run() external returns (address protocolRewards) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        ProtocolRewards rewards = new ProtocolRewards();
        vm.stopBroadcast();

        protocolRewards = address(rewards);
        console2.log("ProtocolRewards:", protocolRewards);
    }
}

