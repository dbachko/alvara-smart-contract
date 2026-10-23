// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import { Test } from "forge-std/Test.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import { AlvaraStorage } from "../contracts/AlvaraStorage.sol";
import { AlvaraStorageHarness } from "./helpers/AlvaraStorageHarness.sol";
import { VRFCoordinatorV2PlusMock } from "./mocks/VRFCoordinatorV2PlusMock.sol";

contract CallbackProbe is IERC721Receiver {
    AlvaraStorage public immutable target;
    bool public refundBlocked;
    bool public rerollBlocked;
    bool public mintBlocked;

    constructor(AlvaraStorage target_) {
        target = target_;
    }

    function buy() external payable {
        target.mint{ value: msg.value }(1);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        (bool refundOk,) =
            address(target).call(abi.encodeCall(AlvaraStorage.refundReserved, (tokenId)));
        (bool rerollOk,) = address(target).call(abi.encodeCall(AlvaraStorage.reroll, (tokenId)));
        (bool mintOk,) = address(target).call{ value: target.TOKEN_PRICE() }(
            abi.encodeCall(AlvaraStorage.mint, (1))
        );
        refundBlocked = !refundOk;
        rerollBlocked = !rerollOk;
        mintBlocked = !mintOk;
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable { }
}

contract RejectingReceiver is IERC721Receiver {
    AlvaraStorage public immutable target;

    constructor(AlvaraStorage target_) {
        target = target_;
    }

    function buy() external payable {
        target.mint{ value: msg.value }(1);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return bytes4(0);
    }
}

contract AlvaraStorageTest is Test, IERC721Receiver {
    event MetadataUpdate(uint256 tokenId);
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

    uint256 internal constant PRICE = 0.001 ether;
    uint256 internal constant SEED = 0xA11CE;
    address internal constant CHARITY = address(0xCA11);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    VRFCoordinatorV2PlusMock internal coordinator;
    AlvaraStorageHarness internal token;

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function setUp() public {
        coordinator = new VRFCoordinatorV2PlusMock();
        token = new AlvaraStorageHarness(address(coordinator), PRICE, CHARITY, true);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
    }

    function _seed() internal returns (uint256 requestId) {
        requestId = token.requestVRFRandomness();
        coordinator.fulfill(requestId, SEED);
    }

    function _openSeededPublicSale() internal {
        _seed();
        token.openPublicSale();
    }

    function testRandomnessLifecycleRejectsUnauthorizedInitialAndDuplicateCalls() public {
        vm.prank(ALICE);
        vm.expectRevert();
        token.requestVRFRandomness();

        uint256 requestId = token.requestVRFRandomness();
        assertEq(uint256(token.randomnessState()), 1);
        vm.expectRevert(AlvaraStorage.RandomnessAlreadyRequested.selector);
        token.requestVRFRandomness();

        vm.prank(ALICE);
        vm.expectRevert();
        token.rawFulfillRandomWords(requestId, _word(SEED));

        vm.expectRevert(
            abi.encodeWithSelector(
                AlvaraStorage.UnexpectedRandomnessRequest.selector, requestId + 1
            )
        );
        coordinator.fulfill(requestId + 1, SEED);

        coordinator.fulfill(requestId, SEED);
        assertEq(uint256(token.randomnessState()), 2);
        assertEq(token.randomSeed(), SEED);
    }

    function testMintRequiresReadyRandomness() public {
        token.openPublicSale();
        vm.prank(ALICE);
        vm.expectRevert(AlvaraStorage.RandomnessNotReady.selector);
        token.mint{ value: PRICE }(1);
    }

    function testImmutableFinancialGateKeepsPaidSaleOff() public {
        AlvaraStorageHarness gated =
            new AlvaraStorageHarness(address(coordinator), PRICE, CHARITY, false);
        vm.expectRevert(AlvaraStorage.FinancialFeaturesDisabled.selector);
        gated.openPublicSale();
        address[] memory accounts = new address[](1);
        accounts[0] = ALICE;
        vm.expectRevert(AlvaraStorage.FinancialFeaturesDisabled.selector);
        gated.reserveForPreSale(accounts, 1);
    }

    function testTraitDataManifestBindsBackendSchema() public view {
        (
            uint256 schemaVersion,
            bytes32 categoriesSha256,
            bytes32 wordsSha256,
            uint256 totalSize,
            uint256 randomCategoryCount
        ) = token.traitDataManifest();
        assertEq(schemaVersion, 1);
        assertEq(
            categoriesSha256, 0x111233cde9dd315253ab7db062f1ae406d9acf2d29262b4bdc05bd8697d7c4bc
        );
        assertEq(wordsSha256, 0xfbb44e26fbd4652a25c32c1a2e89f18b15ca54d683fa6324f52373866e535f77);
        assertEq(totalSize, 10_000);
        assertEq(randomCategoryCount, 10);
    }

    function testBaseDeploymentStaysWithinGasAndRuntimeLimits() public {
        uint256 gasBefore = gasleft();
        AlvaraStorage deployed = new AlvaraStorage(
            address(coordinator),
            1,
            bytes32(uint256(1)),
            500_000,
            3,
            false,
            0,
            CHARITY,
            "ipfs://alvara/",
            false
        );
        uint256 deploymentGas = gasBefore - gasleft();

        emit log_named_uint("AlvaraStorage deployment gas", deploymentGas);
        emit log_named_uint("AlvaraStorage runtime bytes", address(deployed).code.length);
        assertLt(deploymentGas, 5_000_000);
        assertLt(address(deployed).code.length, 24_576);
        assertFalse(deployed.legacyFinancialFeaturesEnabled());
    }

    function testExactPaymentAndPublicBeforeDeveloperRefundTokenZero() public {
        _openSeededPublicSale();
        vm.startPrank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(AlvaraStorage.IncorrectPayment.selector, PRICE, PRICE - 1)
        );
        token.mint{ value: PRICE - 1 }(1);
        vm.expectRevert(
            abi.encodeWithSelector(AlvaraStorage.IncorrectPayment.selector, PRICE, PRICE + 1)
        );
        token.mint{ value: PRICE + 1 }(1);

        token.mint{ value: PRICE }(1);
        assertEq(token.ownerOf(0), ALICE);
        assertTrue(token.refundableToken(0));
        assertEq(token.reservePool(), PRICE / 2);
        assertEq(token.donationLiability(), PRICE - PRICE / 2);
        uint256 before = ALICE.balance;
        token.refundReserved(0);
        assertEq(ALICE.balance - before, PRICE / 2);
        vm.stopPrank();

        assertEq(token.totalSupply(), 0);
        assertEq(token.lifetimeMinted(), 1);
        assertEq(token.refundableSupply(), 0);
        assertEq(token.reservePool(), 0);
        assertEq(address(token).balance, token.donationLiability());
        assertEq(token.getData(0), 0x1ffffffffff);
    }

    function testOddWeiRoundingPreservesReserveBeforeDonationSplit() public {
        AlvaraStorageHarness oddPrice =
            new AlvaraStorageHarness(address(coordinator), 3 wei, CHARITY, true);
        uint256 requestId = oddPrice.requestVRFRandomness();
        coordinator.fulfill(requestId, SEED);
        oddPrice.openPublicSale();

        vm.prank(ALICE);
        oddPrice.mint{ value: 3 wei }(1);

        assertEq(oddPrice.reservePool(), 2 wei);
        assertEq(oddPrice.donationLiability(), 1 wei);
    }

    function testReservationsCannotBeConsumedByPublicMint() public {
        _seed();
        address[] memory accounts = new address[](1);
        accounts[0] = BOB;
        vm.expectRevert(AlvaraStorage.SupplyExceeded.selector);
        token.reserveForPreSale(accounts, 10_001);
        token.reserveForPreSale(accounts, 9_999);
        token.openPublicSale();

        vm.prank(ALICE);
        vm.expectRevert(AlvaraStorage.SupplyExceeded.selector);
        token.mint{ value: PRICE * 2 }(2);
        vm.prank(ALICE);
        token.mint{ value: PRICE }(1);
        assertEq(token.outstandingPreSaleReservations(), 9_999);
        assertEq(token.lifetimeMinted(), 1);
    }

    function testPresaleMintConsumesOutstandingReservation() public {
        _seed();
        address[] memory accounts = new address[](1);
        accounts[0] = ALICE;
        token.reserveForPreSale(accounts, 2);
        token.openPreSale();

        vm.prank(ALICE);
        token.mint{ value: PRICE * 2 }(2);

        assertEq(token.presaleReservations(ALICE), 0);
        assertEq(token.outstandingPreSaleReservations(), 0);
        assertEq(token.lifetimeMinted(), 2);
    }

    function testDonateReservedAndDonationConserveLiabilities() public {
        _openSeededPublicSale();
        vm.startPrank(ALICE);
        token.mint{ value: PRICE * 2 }(2);
        token.donateReserved(0);
        vm.stopPrank();

        assertEq(CHARITY.balance, PRICE / 2);
        assertEq(token.reservePool(), PRICE / 2);
        assertEq(token.donationLiability(), PRICE);
        assertEq(token.refundableSupply(), 1);
        assertEq(address(token).balance, PRICE + PRICE / 2);

        token.donate();
        assertEq(CHARITY.balance, PRICE + PRICE / 2);
        assertEq(token.donationLiability(), 0);
        assertEq(address(token).balance, token.reservePool());

        vm.prank(ALICE);
        token.refundReserved(1);
        assertEq(token.reservePool(), 0);
        assertEq(address(token).balance, 0);
    }

    function testDeveloperTokensAreExplicitlyNonRefundable() public {
        _seed();
        token.developersMint();
        assertEq(token.totalSupply(), 5);
        for (uint256 i = 0; i < 5; ++i) {
            assertTrue(token.developerToken(i));
            assertFalse(token.refundableToken(i));
        }
        vm.expectRevert(abi.encodeWithSelector(AlvaraStorage.NotRefundableToken.selector, 0));
        token.refundReserved(0);
    }

    function testOneRerollOnly() public {
        _openSeededPublicSale();
        vm.startPrank(ALICE);
        token.mint{ value: PRICE }(1);
        uint256 original = token.getData(0);
        vm.expectEmit(false, false, false, true);
        emit MetadataUpdate(0);
        token.reroll(0);
        uint256 rerolled = token.getData(0);
        assertNotEq(rerolled, original);
        assertEq((rerolled >> 40) & 1, 1);
        token.reroll(0);
        assertEq(token.getData(0), rerolled);
        vm.stopPrank();
    }

    function testMetadataBoundariesFreezeAndTransfers() public {
        _openSeededPublicSale();
        vm.prank(ALICE);
        token.mint{ value: PRICE }(1);
        assertEq(token.tokenURI(0), "ipfs://alvara/0");
        vm.expectRevert();
        token.tokenURI(1);

        assertTrue(token.supportsInterface(0x49064906));
        vm.expectEmit(false, false, false, true);
        emit BatchMetadataUpdate(0, 0);
        token.setBaseURI("ipfs://final/");
        vm.expectEmit(false, false, false, true);
        emit BatchMetadataUpdate(0, 0);
        token.freezeBaseURI();
        vm.expectRevert(AlvaraStorage.MetadataAlreadyFrozen.selector);
        token.setBaseURI("ipfs://other/");

        vm.prank(ALICE);
        token.transferFrom(ALICE, BOB, 0);
        assertEq(token.ownerOf(0), BOB);
        assertEq(token.tokenURI(0), "ipfs://final/0");
    }

    function testReceiverCallbackCannotRefundRerollOrReenterMint() public {
        _openSeededPublicSale();
        CallbackProbe receiver = new CallbackProbe(token);
        vm.deal(address(receiver), PRICE * 2);
        receiver.buy{ value: PRICE }();
        assertTrue(receiver.refundBlocked());
        assertTrue(receiver.rerollBlocked());
        assertTrue(receiver.mintBlocked());
        assertEq(token.ownerOf(0), address(receiver));
        assertEq(token.refundableSupply(), 1);
        assertEq(token.reservePool(), PRICE / 2);
    }

    function testRejectingReceiverRollsBackAllEffects() public {
        _openSeededPublicSale();
        RejectingReceiver receiver = new RejectingReceiver(token);
        vm.deal(address(receiver), PRICE);
        vm.expectRevert();
        receiver.buy{ value: PRICE }();
        assertEq(token.lifetimeMinted(), 0);
        assertEq(token.totalSupply(), 0);
        assertEq(token.refundableSupply(), 0);
        assertEq(token.reservePool(), 0);
        assertEq(token.donationLiability(), 0);
    }

    function testGeneratedNormalOptionsExcludeReservedAndIgnoredCombinations() public {
        _seed();
        for (uint16 category = 0; category < 10; category += 2) {
            for (uint256 i = 0; i < 64; ++i) {
                uint256 options = token.generateForCategory(category);
                assertTrue(token.normalAllowed(category >> 1, options));
            }
        }
        for (uint16 category = 1; category < 10; category += 2) {
            for (uint256 i = 0; i < 12; ++i) {
                uint256 options = token.generateForCategory(category);
                assertTrue(token.specialAllowed(category >> 1, options));
            }
        }
    }

    function testWeightedRemainingSelectionExactlyFillsEveryQuota() public {
        _seed();
        for (uint256 tokenId = 0; tokenId < 10_000; ++tokenId) {
            token.drawCategory(tokenId);
        }
        for (uint256 category = 0; category < 10; ++category) {
            assertEq(token.categoryMinted(category), token.categoryCapacity(category));
        }
        vm.expectRevert(AlvaraStorage.SupplyExceeded.selector);
        token.drawCategory(10_000);
    }

    function testFuzzWrongPaymentAlwaysReverts(uint96 supplied) public {
        _openSeededPublicSale();
        vm.assume(supplied != PRICE);
        vm.deal(ALICE, uint256(supplied));
        vm.prank(ALICE);
        vm.expectRevert();
        token.mint{ value: supplied }(1);
    }

    function _word(uint256 value) private pure returns (uint256[] memory words) {
        words = new uint256[](1);
        words[0] = value;
    }
}
