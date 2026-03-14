// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/Test.sol";

contract ScriptHelper is Script {
    using stdJson for string;

    address internal constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    address internal constant OPTIMISM_POOL_MANAGER = 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3;
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address internal constant ARBITRUM_ONE_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant POLYGON_POOL_MANAGER = 0x67366782805870060151383F4BbFF9daB53e5cD6;
    address internal constant BLAST_POOL_MANAGER = 0x1631559198A9e474033433b2958daBC135ab6446;
    address internal constant ZORA_POOL_MANAGER = 0x0575338e4C17006aE181B47900A84404247CA30f;
    address internal constant WORLDCHAIN_POOL_MANAGER = 0xb1860D529182ac3BC1F51Fa2ABd56662b7D13f33;
    address internal constant INK_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant SONEIUM_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant AVALANCHE_POOL_MANAGER = 0x06380C0e0912312B5150364B9DC4542BA0DbBc85;
    address internal constant BNB_SMART_CHAIN_POOL_MANAGER = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    address internal constant CELO_POOL_MANAGER = 0x288dc841A52FCA2707c6947B3A777c5E56cd87BC;
    address internal constant MONAD_POOL_MANAGER = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
    address internal constant MEGAETH_POOL_MANAGER = 0xaCB7e78fa05D562e0A5D3089ec896D57D057d38E;
    address internal constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant ARBITRUM_SEPOLIA_POOL_MANAGER = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
    address internal constant UNICHAIN_SEPOLIA_CHRONICLE_ETH_USD = 0x1a16742c2f612eC46f52687BE5d1731EC12cBD89;
    address internal constant UNICHAIN_SEPOLIA_SELF_KISSER = 0x7AB42CC558fc92EC990B22E663E5a7bc5879fc9f;

    enum SelectChain {
        Anvil,
        UnichainSepolia,
        Unichain,
        Mainnet,
        Optimism,
        Base,
        ArbitrumOne,
        Polygon,
        Blast,
        Zora,
        Worldchain,
        Ink,
        Soneium,
        Avalanche,
        BnbSmartChain,
        Celo,
        Monad,
        MegaEth,
        Sepolia,
        BaseSepolia,
        ArbitrumSepolia
    }

    enum RunMode {
        Broadcast,
        DryRun
    }

    function _selectedChain() internal view returns (SelectChain) {
        string memory chainName = vm.envOr("CHAIN", string("anvil"));
        bytes32 value = keccak256(bytes(chainName));
        if (value == keccak256(bytes("anvil"))) return SelectChain.Anvil;
        if (value == keccak256(bytes("unichain-sepolia"))) return SelectChain.UnichainSepolia;
        if (value == keccak256(bytes("unichain"))) return SelectChain.Unichain;
        if (value == keccak256(bytes("mainnet"))) return SelectChain.Mainnet;
        if (value == keccak256(bytes("optimism"))) return SelectChain.Optimism;
        if (value == keccak256(bytes("base"))) return SelectChain.Base;
        if (value == keccak256(bytes("arbitrum-one"))) return SelectChain.ArbitrumOne;
        if (value == keccak256(bytes("polygon"))) return SelectChain.Polygon;
        if (value == keccak256(bytes("blast"))) return SelectChain.Blast;
        if (value == keccak256(bytes("zora"))) return SelectChain.Zora;
        if (value == keccak256(bytes("worldchain"))) return SelectChain.Worldchain;
        if (value == keccak256(bytes("ink"))) return SelectChain.Ink;
        if (value == keccak256(bytes("soneium"))) return SelectChain.Soneium;
        if (value == keccak256(bytes("avalanche"))) return SelectChain.Avalanche;
        if (value == keccak256(bytes("bnb-smart-chain"))) return SelectChain.BnbSmartChain;
        if (value == keccak256(bytes("celo"))) return SelectChain.Celo;
        if (value == keccak256(bytes("monad"))) return SelectChain.Monad;
        if (value == keccak256(bytes("megaeth"))) return SelectChain.MegaEth;
        if (value == keccak256(bytes("sepolia"))) return SelectChain.Sepolia;
        if (value == keccak256(bytes("base-sepolia"))) return SelectChain.BaseSepolia;
        if (value == keccak256(bytes("arbitrum-sepolia"))) return SelectChain.ArbitrumSepolia;
        revert("UNSUPPORTED_CHAIN");
    }

    function _selectedRunMode() internal view returns (RunMode) {
        string memory modeName = vm.envOr("RUN_MODE", string("broadcast"));
        bytes32 value = keccak256(bytes(modeName));
        if (value == keccak256(bytes("broadcast"))) return RunMode.Broadcast;
        if (value == keccak256(bytes("dry-run"))) return RunMode.DryRun;
        revert("UNSUPPORTED_RUN_MODE");
    }

    function _chainFolder(SelectChain selectedChain) internal pure returns (string memory) {
        if (selectedChain == SelectChain.Anvil) return "31337";
        if (selectedChain == SelectChain.UnichainSepolia) return "1301";
        if (selectedChain == SelectChain.Unichain) return "130";
        if (selectedChain == SelectChain.Mainnet) return "1";
        if (selectedChain == SelectChain.Optimism) return "10";
        if (selectedChain == SelectChain.Base) return "8453";
        if (selectedChain == SelectChain.ArbitrumOne) return "42161";
        if (selectedChain == SelectChain.Polygon) return "137";
        if (selectedChain == SelectChain.Blast) return "81457";
        if (selectedChain == SelectChain.Zora) return "7777777";
        if (selectedChain == SelectChain.Worldchain) return "480";
        if (selectedChain == SelectChain.Ink) return "57073";
        if (selectedChain == SelectChain.Soneium) return "1868";
        if (selectedChain == SelectChain.Avalanche) return "43114";
        if (selectedChain == SelectChain.BnbSmartChain) return "56";
        if (selectedChain == SelectChain.Celo) return "42220";
        if (selectedChain == SelectChain.Monad) return "143";
        if (selectedChain == SelectChain.MegaEth) return "4326";
        if (selectedChain == SelectChain.Sepolia) return "11155111";
        if (selectedChain == SelectChain.BaseSepolia) return "84532";
        if (selectedChain == SelectChain.ArbitrumSepolia) return "421614";
        revert("UNSUPPORTED_CHAIN");
    }

    function _broadcastPath(string memory scriptName, RunMode mode, SelectChain selectedChain)
        internal
        view
        returns (string memory)
    {
        string memory root = vm.projectRoot();
        string memory base = string.concat(root, "/broadcast/", scriptName, ".s.sol/", _chainFolder(selectedChain), "/");

        if (mode == RunMode.DryRun) {
            return string.concat(base, "dry-run/run-latest.json");
        }
        return string.concat(base, "run-latest.json");
    }

    function _broadcastPath(string memory scriptName) internal view virtual returns (string memory) {
        return _broadcastPath(scriptName, _selectedRunMode(), _selectedChain());
    }

    function _readDeployedContractAddress(string memory scriptName, uint256 txIndex)
        internal
        view
        virtual
        returns (address)
    {
        string memory json = vm.readFile(_broadcastPath(scriptName));
        string memory key = string.concat(".transactions[", vm.toString(txIndex), "].contractAddress");
        return json.readAddress(key);
    }

    function _deployedAsyncSwap() internal view virtual returns (address) {
        if (vm.envExists("ASYNCSWAP_ADDRESS")) {
            return vm.envAddress("ASYNCSWAP_ADDRESS");
        }
        return _readDeployedContractAddress("00_DeployAsyncSwap", 1);
    }

    function _deployedAsyncToken() internal view virtual returns (address) {
        if (vm.envExists("ASYNC_TOKEN_ADDRESS")) {
            return vm.envAddress("ASYNC_TOKEN_ADDRESS");
        }
        return _readDeployedContractAddress("01_DeployGovernance", 0);
    }

    function _deployedTimelock() internal view virtual returns (address) {
        if (vm.envExists("TIMELOCK_ADDRESS")) {
            return vm.envAddress("TIMELOCK_ADDRESS");
        }
        return _readDeployedContractAddress("01_DeployGovernance", 1);
    }

    function _deployedGovernor() internal view virtual returns (address) {
        if (vm.envExists("GOVERNOR_ADDRESS")) {
            return vm.envAddress("GOVERNOR_ADDRESS");
        }
        return _readDeployedContractAddress("01_DeployGovernance", 2);
    }

    function _deployedOracleAdapter() internal view returns (address) {
        if (vm.envExists("ORACLE_ADAPTER_ADDRESS")) {
            return vm.envAddress("ORACLE_ADAPTER_ADDRESS");
        }
        return _readDeployedContractAddress("11_DeployChronicleOracleAdapter", 0);
    }

    function _deployedDemoToken0() internal view returns (address) {
        if (vm.envExists("TOKEN0_ADDRESS")) {
            return vm.envAddress("TOKEN0_ADDRESS");
        }
        return _readDeployedContractAddress("07_DeployDemoTokens", 0);
    }

    function _deployedDemoToken1() internal view returns (address) {
        if (vm.envExists("TOKEN1_ADDRESS")) {
            return vm.envAddress("TOKEN1_ADDRESS");
        }
        return _readDeployedContractAddress("07_DeployDemoTokens", 1);
    }

    function _poolManagerAddress() internal view returns (address) {
        if (vm.envExists("POOLMANAGER_ADDRESS")) {
            return vm.envAddress("POOLMANAGER_ADDRESS");
        }

        SelectChain selectedChain = _selectedChain();
        if (selectedChain == SelectChain.Anvil) {
            return _readDeployedContractAddress("00_DeployAsyncSwap", 0);
        }
        if (selectedChain == SelectChain.UnichainSepolia) {
            return UNICHAIN_SEPOLIA_POOL_MANAGER;
        }
        if (selectedChain == SelectChain.Unichain) {
            return UNICHAIN_POOL_MANAGER;
        }
        if (selectedChain == SelectChain.Mainnet) {
            return MAINNET_POOL_MANAGER;
        }
        if (selectedChain == SelectChain.Optimism) return OPTIMISM_POOL_MANAGER;
        if (selectedChain == SelectChain.Base) return BASE_POOL_MANAGER;
        if (selectedChain == SelectChain.ArbitrumOne) return ARBITRUM_ONE_POOL_MANAGER;
        if (selectedChain == SelectChain.Polygon) return POLYGON_POOL_MANAGER;
        if (selectedChain == SelectChain.Blast) return BLAST_POOL_MANAGER;
        if (selectedChain == SelectChain.Zora) return ZORA_POOL_MANAGER;
        if (selectedChain == SelectChain.Worldchain) return WORLDCHAIN_POOL_MANAGER;
        if (selectedChain == SelectChain.Ink) return INK_POOL_MANAGER;
        if (selectedChain == SelectChain.Soneium) return SONEIUM_POOL_MANAGER;
        if (selectedChain == SelectChain.Avalanche) return AVALANCHE_POOL_MANAGER;
        if (selectedChain == SelectChain.BnbSmartChain) return BNB_SMART_CHAIN_POOL_MANAGER;
        if (selectedChain == SelectChain.Celo) return CELO_POOL_MANAGER;
        if (selectedChain == SelectChain.Monad) return MONAD_POOL_MANAGER;
        if (selectedChain == SelectChain.MegaEth) return MEGAETH_POOL_MANAGER;
        if (selectedChain == SelectChain.Sepolia) return SEPOLIA_POOL_MANAGER;
        if (selectedChain == SelectChain.BaseSepolia) return BASE_SEPOLIA_POOL_MANAGER;
        if (selectedChain == SelectChain.ArbitrumSepolia) return ARBITRUM_SEPOLIA_POOL_MANAGER;
        revert("UNSUPPORTED_CHAIN");
    }

    function _chronicleOracleAddress() internal view returns (address) {
        if (vm.envExists("CHRONICLE_ORACLE")) {
            return vm.envAddress("CHRONICLE_ORACLE");
        }
        if (_selectedChain() == SelectChain.UnichainSepolia) {
            return UNICHAIN_SEPOLIA_CHRONICLE_ETH_USD;
        }
        revert("MISSING_CHRONICLE_ORACLE");
    }

    function _chronicleSelfKisserAddress() internal view returns (address) {
        if (vm.envExists("CHRONICLE_SELF_KISSER")) {
            return vm.envAddress("CHRONICLE_SELF_KISSER");
        }
        if (_selectedChain() == SelectChain.UnichainSepolia) {
            return UNICHAIN_SEPOLIA_SELF_KISSER;
        }
        revert("MISSING_CHRONICLE_SELF_KISSER");
    }
}
