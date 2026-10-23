// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { AlvaraStorage } from "../../contracts/AlvaraStorage.sol";

contract AlvaraStorageHarness is AlvaraStorage {
    constructor(address coordinator, uint256 price, address charity, bool financialFeatures)
        AlvaraStorage(
            coordinator,
            1,
            bytes32(uint256(1)),
            500_000,
            3,
            false,
            price,
            charity,
            "ipfs://alvara/",
            financialFeatures
        )
    { }

    function drawCategory(uint256 tokenId) external returns (uint16) {
        return _chooseCategory(tokenId);
    }

    function generateForCategory(uint16 category) external returns (uint256) {
        return _generateOptions(category);
    }

    function normalAllowed(uint16 collection, uint256 options) external pure returns (bool) {
        return _normalOptionsAllowed(collection, options);
    }

    function specialAllowed(uint16 collection, uint256 options) external pure returns (bool) {
        return _specialOptionsAllowed(collection, options);
    }
}
