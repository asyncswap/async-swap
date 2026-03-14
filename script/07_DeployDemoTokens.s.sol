// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ScriptHelper} from "./ScriptHelper.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract DeployDemoTokensScript is ScriptHelper {
    MockERC20 public token0;
    MockERC20 public token1;

    function run() public {
        address user = vm.envAddress("USER_ADDRESS");
        address filler = vm.envAddress("FILLER_ADDRESS");
        uint256 mintAmount = vm.envOr("DEMO_MINT_AMOUNT", uint256(1_000_000e18));

        vm.startBroadcast();

        token0 = new MockERC20("Async Demo Token 0", "ADT0", 18);
        token1 = new MockERC20("Async Demo Token 1", "ADT1", 18);

        token0.mint(user, mintAmount);
        token1.mint(user, mintAmount);
        token0.mint(filler, mintAmount);
        token1.mint(filler, mintAmount);

        vm.stopBroadcast();
    }
}
