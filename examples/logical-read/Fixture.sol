// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

contract Implementation {
    uint256 immutable revision;
    constructor(uint256 value) { revision = value; }
    function stakedTokenId(address) external view returns (uint256) { return revision + 6; }
    function totalSupply() external view returns (uint256) { return revision * 100; }
    function balanceOf(address) external view returns (uint256) { return revision * 1000; }
    function ownerOf(uint256 id) external pure returns (address) {
        return id == 7 ? address(0xdead) : address(0xbeef);
    }
}

// Test-only proxy: upgrade is deliberately unrestricted for branch-change fixtures.
contract Proxy {
    bytes32 constant SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    constructor(address implementation) { assembly { sstore(SLOT, implementation) } }
    function upgrade(address implementation) external { assembly { sstore(SLOT, implementation) } }
    fallback() external payable {
        assembly {
            let implementation := sload(SLOT)
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

contract Multicall {
    struct Call { address target; bool allowFailure; bytes callData; }
    struct Result { bool success; bytes returnData; }
    function aggregate3(Call[] calldata calls) external payable returns (Result[] memory results) {
        results = new Result[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            (bool success, bytes memory data) = calls[i].target.call(calls[i].callData);
            require(success || calls[i].allowFailure, "call failed");
            results[i] = Result(success, data);
        }
    }
}
