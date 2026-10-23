// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { AlvaraStorageHarness } from "./helpers/AlvaraStorageHarness.sol";
import { VRFCoordinatorV2PlusMock } from "./mocks/VRFCoordinatorV2PlusMock.sol";

contract AlvaraHandler is Test {
    AlvaraStorageHarness public immutable token;
    uint256 public immutable price;

    constructor(AlvaraStorageHarness token_, uint256 price_) {
        token = token_;
        price = price_;
    }

    function mintOne() external {
        if (token.lifetimeMinted() >= token.MAX_TOKENS()) return;
        vm.deal(address(this), address(this).balance + price);
        token.mint{ value: price }(1);
    }

    function refund(uint256 tokenId) external {
        if (tokenId >= token.lifetimeMinted()) return;
        try token.ownerOf(tokenId) returns (address currentOwner) {
            if (currentOwner == address(this) && token.refundableToken(tokenId)) {
                token.refundReserved(tokenId);
            }
        } catch { }
    }

    receive() external payable { }
}

contract AlvaraStorageInvariantTest is StdInvariant, Test {
    uint256 internal constant PRICE = 0.001 ether;
    AlvaraStorageHarness internal token;

    function setUp() public {
        VRFCoordinatorV2PlusMock coordinator = new VRFCoordinatorV2PlusMock();
        token = new AlvaraStorageHarness(address(coordinator), PRICE, address(0xCA11), true);
        uint256 requestId = token.requestVRFRandomness();
        coordinator.fulfill(requestId, 0xA11CE);
        token.openPublicSale();

        AlvaraHandler handler = new AlvaraHandler(token, PRICE);
        targetContract(address(handler));
    }

    function invariantSupplyAndAccountingRemainConserved() public view {
        assertLe(token.lifetimeMinted(), token.MAX_TOKENS());
        assertEq(token.totalSupply(), token.refundableSupply());
        assertEq(address(token).balance, token.reservePool() + token.donationLiability());

        uint256 categorized;
        for (uint256 i = 0; i < token.RCATEGORIES_COUNT(); ++i) {
            uint256 minted = token.categoryMinted(i);
            assertLe(minted, token.categoryCapacity(i));
            categorized += minted;
        }
        assertEq(categorized, token.lifetimeMinted());
    }
}
