// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { AsyncSwap } from "@async-swap/AsyncSwap.sol";
import { AsyncOrder } from "@async-swap/types/AsyncOrder.sol";
import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/Test.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

contract FFIHelper is Script {

  enum SelectChain {
    Anvil,
    UnichainSepolia,
    Unichain,
    Mainnet
  }

  SelectChain chain = SelectChain.Unichain;
  address OWNER = 0xb1F0982E02f9F71E60512fd47471d76610CcB556;
  address ANVIL_OWNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

  using stdJson for string;

  function _getDeployedPoolManager() internal returns (address poolManagerAddress) {
    if (chain == SelectChain.UnichainSepolia) {
      poolManagerAddress = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    }
    if (chain == SelectChain.Mainnet) {
      poolManagerAddress = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    }
    if (chain == SelectChain.Unichain) {
      poolManagerAddress = 0x1F98400000000000000000000000000000000004;
    }
    if (chain == SelectChain.Anvil) {
      OWNER = ANVIL_OWNER;
      string memory root = vm.projectRoot();
      string memory path = string.concat(root, "/broadcast/00_DeployPoolManager.s.sol/31337/run-latest.json");
      string memory json = vm.readFile(path);
      poolManagerAddress = json.readAddress(".transactions[0].contractAddress");
    }
  }

  function _getDeployedHook() internal returns (address hookAddress, address routerAddress) {
    string memory root = vm.projectRoot();
    string memory broadcastUrl = "/broadcast/01_DeployHook.s.sol/";
    if (chain == SelectChain.UnichainSepolia) {
      broadcastUrl = string.concat(broadcastUrl, "1301/run-latest.json");
    }
    if (chain == SelectChain.Unichain) {
      broadcastUrl = string.concat(broadcastUrl, "130/run-latest.json");
    }
    if (chain == SelectChain.Mainnet) {
      broadcastUrl = string.concat(broadcastUrl, "1/run-latest.json");
    }
    if (chain == SelectChain.Anvil) {
      OWNER = ANVIL_OWNER;
      broadcastUrl = string.concat(broadcastUrl, "31337/run-latest.json");
    }
    string memory path = string.concat(root, broadcastUrl);
    string memory json = vm.readFile(path);
    hookAddress = json.readAddress(".transactions[0].contractAddress");
    routerAddress = json.readAddress(".transactions[1].contractAddress");
  }

  function _getPoolTopics() internal returns (uint256[] memory) {
    string memory root = vm.projectRoot();
    string memory broadcastUrl = "/broadcast/02_InitilizePool.s.sol/";
    if (chain == SelectChain.UnichainSepolia) {
      broadcastUrl = string.concat(broadcastUrl, "1301/run-latest.json");
    }
    if (chain == SelectChain.Unichain) {
      broadcastUrl = string.concat(broadcastUrl, "130/run-latest.json");
    }
    if (chain == SelectChain.Mainnet) {
      broadcastUrl = string.concat(broadcastUrl, "1/run-latest.json");
    }
    if (chain == SelectChain.Anvil) {
      OWNER = ANVIL_OWNER;
      broadcastUrl = string.concat(broadcastUrl, "31337/run-latest.json");
    }
    string memory path = string.concat(root, broadcastUrl);
    string memory json = vm.readFile(path);
    uint256[] memory topics = json.readUintArray(".receipts[4].logs[0].topics");
    return topics;
  }

  struct OrderData {
    PoolId poolId;
    address owner;
  }

  function _getAsyncOrder() internal returns (AsyncOrder memory) {
    string memory root = vm.projectRoot();
    string memory broadcastUrl = "/broadcast/04_Swap.s.sol/";
    if (chain == SelectChain.UnichainSepolia) {
      broadcastUrl = string.concat(broadcastUrl, "1301/run-latest.json");
    }
    if (chain == SelectChain.Unichain) {
      broadcastUrl = string.concat(broadcastUrl, "130/run-latest.json");
    }
    if (chain == SelectChain.Mainnet) {
      broadcastUrl = string.concat(broadcastUrl, "1/run-latest.json");
    }
    if (chain == SelectChain.Anvil) {
      OWNER = ANVIL_OWNER;
      broadcastUrl = string.concat(broadcastUrl, "31337/run-latest.json");
    }
    string memory path = string.concat(root, broadcastUrl);
    string memory json = vm.readFile(path);
    bytes memory data = json.readBytes(".receipts[1].logs[1].data");

    uint256[] memory topics = json.readUintArray(".receipts[1].logs[1].topics");
    OrderData memory orderData = abi.decode(data, (OrderData));
    bool zeroForOne = topics[1] == 0 ? false : true;
    uint256 amountIn = uint256(topics[2]);
    PoolKey memory key = _getPoolKey();

    AsyncOrder memory order = AsyncOrder(key, orderData.owner, zeroForOne, amountIn, 2 ** 96);
    return order;
  }

  function _getPoolKey() internal returns (PoolKey memory) {
    uint256[] memory keyTopics = _getPoolTopics();
    (address hook,) = _getDeployedHook();
    Currency currency0 = Currency.wrap(address(uint160(keyTopics[2])));
    Currency currency1 = Currency.wrap(address(uint160(keyTopics[3])));
    PoolKey memory key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, AsyncSwap(hook));
    return key;
  }

}
