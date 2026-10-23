// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {
    VRFConsumerBaseV2Plus
} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {
    VRFV2PlusClient
} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC4906 } from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { AlvaraTraitData } from "./generated/AlvaraTraitData.sol";

/// @notice Modernized reference implementation of the historical Alvara ERC721 design.
/// @dev Legacy sale/refund/charity behavior is disabled immutably unless explicitly opted in.
contract AlvaraStorage is VRFConsumerBaseV2Plus, ERC721, IERC4906, ReentrancyGuard {
    enum RandomnessState {
        Unrequested,
        Requested,
        Ready
    }

    error FinancialFeaturesDisabled();
    error RandomnessNotReady();
    error RandomnessAlreadyRequested();
    error UnexpectedRandomnessRequest(uint256 requestId);
    error InvalidConfiguration();
    error InvalidSaleState();
    error InvalidMintQuantity();
    error IncorrectPayment(uint256 expected, uint256 actual);
    error SupplyExceeded();
    error PublicMintLimitExceeded();
    error InsufficientReservation();
    error InvalidReservation();
    error DeveloperMintMustBeFirst();
    error NotRefundableToken(uint256 tokenId);
    error NotTokenOwner(uint256 tokenId);
    error TransferFailed(address recipient, uint256 amount);
    error MetadataAlreadyFrozen();
    error TraitSearchExhausted(uint16 category);
    error InvalidTraitData();

    event SaleStateChanged(uint8 indexed previousState, uint8 indexed newState);
    event PreSaleReserved(address indexed account, uint256 quantity);
    event OutstandingPreSaleReservationsChanged(uint256 previousTotal, uint256 newTotal);
    event RandomnessRequested(uint256 indexed requestId);
    event RandomnessReady(uint256 indexed requestId, uint256 seed);
    event TokenRerolled(uint256 indexed tokenId, uint256 data);
    event ReserveRefunded(uint256 indexed tokenId, address indexed recipient, uint256 amount);
    event ReserveDonated(uint256 indexed tokenId, uint256 amount);
    event DonationPaid(uint256 amount);
    event BaseURIChanged(string previousURI, string newURI);
    event BaseURIFrozen(string uri);

    uint256 public constant MAX_TOKENS = 10_000;
    uint256 public constant DEVELOPERS_COUNT = 5;
    uint256 public constant RCATEGORIES_COUNT = 10;
    uint256 public constant MAX_TOKENS_PER_PUBLIC_MINT = 10;

    bytes4 private constant ERC4906_INTERFACE_ID = 0x49064906;
    uint256 private constant REROLL_FLAG = uint256(1) << 40;
    uint256 private constant PUBLIC_DATA_MASK = 0x1ffffffffff;
    uint256 private constant MISSING_DATA = PUBLIC_DATA_MASK;
    uint256 private constant MAX_TRAIT_SEARCH_ATTEMPTS = 128;

    uint256 public immutable TOKEN_PRICE;
    address public immutable CHARITY_ADDRESS;
    bool public immutable legacyFinancialFeaturesEnabled;
    uint256 public immutable vrfSubscriptionId;
    bytes32 public immutable vrfKeyHash;
    uint32 public immutable vrfCallbackGasLimit;
    uint16 public immutable vrfRequestConfirmations;
    bool public immutable vrfNativePayment;

    mapping(uint256 tokenId => uint256 packedData) private _data;
    mapping(address account => uint256 quantity) public presaleReservations;
    mapping(uint256 tokenId => bool refundable) public refundableToken;
    mapping(uint256 tokenId => bool developerOwned) public developerToken;

    uint32[RCATEGORIES_COUNT] internal _combinationCursor;
    uint16[RCATEGORIES_COUNT] internal _categoryMinted;

    uint256 public outstandingPreSaleReservations;
    uint256 public reservePool;
    uint256 public donationLiability;
    uint256 public refundableSupply;
    uint256 public lifetimeMinted;
    uint256 private _circulatingSupply;
    uint8 public saleState;
    bool public developersInitialized;
    bool public metadataFrozen;
    string private _baseTokenURI;

    RandomnessState public randomnessState;
    uint256 public randomnessRequestId;
    uint256 public randomSeed;

    modifier financialFeaturesEnabled() {
        if (!legacyFinancialFeaturesEnabled) revert FinancialFeaturesDisabled();
        _;
    }

    modifier randomnessReady() {
        if (randomnessState != RandomnessState.Ready) revert RandomnessNotReady();
        _;
    }

    constructor(
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        bool nativePayment,
        uint256 tokenPrice,
        address charityAddress,
        string memory initialBaseURI,
        bool enableLegacyFinancialFeatures
    ) ERC721("Alvara NFT", "Alvara") VRFConsumerBaseV2Plus(vrfCoordinator) {
        if (
            vrfCoordinator == address(0) || subscriptionId == 0 || keyHash == bytes32(0)
                || callbackGasLimit == 0 || requestConfirmations == 0
                || charityAddress == address(0)
                || (enableLegacyFinancialFeatures && tokenPrice == 0)
        ) revert InvalidConfiguration();

        vrfSubscriptionId = subscriptionId;
        vrfKeyHash = keyHash;
        vrfCallbackGasLimit = callbackGasLimit;
        vrfRequestConfirmations = requestConfirmations;
        vrfNativePayment = nativePayment;
        TOKEN_PRICE = tokenPrice;
        CHARITY_ADDRESS = charityAddress;
        legacyFinancialFeaturesEnabled = enableLegacyFinancialFeatures;
        _baseTokenURI = initialBaseURI;
        if (
            AlvaraTraitData.TOTAL_SIZE != MAX_TOKENS
                || AlvaraTraitData.RANDOM_CATEGORY_COUNT != RCATEGORIES_COUNT
                || AlvaraTraitData.CATEGORY_COUNT * 2 != RCATEGORIES_COUNT
                || AlvaraTraitData.ATTRIBUTE_COUNT != 7
                || AlvaraTraitData.MAX_REJECTION_RUN >= MAX_TRAIT_SEARCH_ATTEMPTS
                || _totalBucketCapacity() != MAX_TOKENS
        ) revert InvalidTraitData();
    }

    function requestVRFRandomness() external onlyOwner returns (uint256 requestId) {
        if (randomnessState != RandomnessState.Unrequested) revert RandomnessAlreadyRequested();
        randomnessState = RandomnessState.Requested;
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({ nativePayment: vrfNativePayment })
                )
            })
        );
        randomnessRequestId = requestId;
        emit RandomnessRequested(requestId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        if (
            randomnessState != RandomnessState.Requested || requestId != randomnessRequestId
                || randomWords.length != 1
        ) revert UnexpectedRandomnessRequest(requestId);

        uint256 seed = randomWords[0];
        randomSeed = seed;
        for (uint256 i = 0; i < RCATEGORIES_COUNT; ++i) {
            _combinationCursor[i] = uint32(uint256(keccak256(abi.encode(seed, i, address(this)))));
        }
        randomnessState = RandomnessState.Ready;
        emit RandomnessReady(requestId, seed);
    }

    function openPreSale() external onlyOwner financialFeaturesEnabled {
        _setSaleState(1);
    }

    function openPublicSale() external onlyOwner financialFeaturesEnabled {
        _setSaleState(2);
    }

    function closeSale() external onlyOwner {
        _setSaleState(0);
    }

    function reserveForPreSale(address[] calldata accounts, uint256 quantity)
        external
        onlyOwner
        financialFeaturesEnabled
    {
        if (quantity == 0 || accounts.length == 0) revert InvalidReservation();
        uint256 needed = quantity * accounts.length;
        if (lifetimeMinted + outstandingPreSaleReservations + needed > MAX_TOKENS) {
            revert SupplyExceeded();
        }
        for (uint256 i = 0; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) revert InvalidReservation();
            presaleReservations[accounts[i]] += quantity;
            emit PreSaleReserved(accounts[i], quantity);
        }
        uint256 previousTotal = outstandingPreSaleReservations;
        outstandingPreSaleReservations = previousTotal + needed;
        emit OutstandingPreSaleReservationsChanged(previousTotal, outstandingPreSaleReservations);
    }

    function developersMint()
        external
        nonReentrant
        onlyOwner
        financialFeaturesEnabled
        randomnessReady
    {
        if (lifetimeMinted != 0 || developersInitialized) {
            revert DeveloperMintMustBeFirst();
        }
        if (DEVELOPERS_COUNT + outstandingPreSaleReservations > MAX_TOKENS) {
            revert SupplyExceeded();
        }
        developersInitialized = true;
        for (uint256 i = 0; i < DEVELOPERS_COUNT; ++i) {
            uint256 tokenId = _prepareToken(false, true);
            _safeMint(owner(), tokenId);
        }
    }

    function mint(uint256 quantity)
        external
        payable
        nonReentrant
        financialFeaturesEnabled
        randomnessReady
    {
        if (quantity == 0) revert InvalidMintQuantity();
        if (saleState == 0) revert InvalidSaleState();
        uint256 expectedPayment = TOKEN_PRICE * quantity;
        if (msg.value != expectedPayment) revert IncorrectPayment(expectedPayment, msg.value);

        if (saleState == 1) {
            uint256 reservation = presaleReservations[msg.sender];
            if (reservation < quantity) revert InsufficientReservation();
            presaleReservations[msg.sender] = reservation - quantity;
            uint256 previousTotal = outstandingPreSaleReservations;
            outstandingPreSaleReservations -= quantity;
            emit OutstandingPreSaleReservationsChanged(
                previousTotal, outstandingPreSaleReservations
            );
        } else if (saleState == 2) {
            if (quantity > MAX_TOKENS_PER_PUBLIC_MINT) revert PublicMintLimitExceeded();
        } else {
            revert InvalidSaleState();
        }
        if (lifetimeMinted + quantity + outstandingPreSaleReservations > MAX_TOKENS) {
            revert SupplyExceeded();
        }

        uint256 donationContribution = expectedPayment / 2;
        uint256 reserveContribution = expectedPayment - donationContribution;
        reservePool += reserveContribution;
        donationLiability += donationContribution;
        refundableSupply += quantity;
        for (uint256 i = 0; i < quantity; ++i) {
            uint256 tokenId = _prepareToken(true, false);
            _safeMint(msg.sender, tokenId);
        }
    }

    function reroll(uint256 tokenId) external nonReentrant randomnessReady {
        if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if ((_data[tokenId] & REROLL_FLAG) != 0) return;
        uint16 category = uint16((_data[tokenId] >> 35) & 0x1f);
        uint256 options = _generateOptions(category);
        _data[tokenId] = REROLL_FLAG | (uint256(category) << 35) | options;
        emit MetadataUpdate(tokenId);
        emit TokenRerolled(tokenId, _data[tokenId]);
    }

    function refundReserved(uint256 tokenId)
        external
        nonReentrant
        financialFeaturesEnabled
        returns (uint256 amount)
    {
        if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (!refundableToken[tokenId]) revert NotRefundableToken(tokenId);
        amount = reservePool / refundableSupply;
        refundableToken[tokenId] = false;
        refundableSupply -= 1;
        reservePool -= amount;
        _burn(tokenId);
        delete _data[tokenId];
        emit ReserveRefunded(tokenId, msg.sender, amount);
        _sendValue(msg.sender, amount);
    }

    function donateReserved(uint256 tokenId)
        external
        nonReentrant
        financialFeaturesEnabled
        returns (uint256 amount)
    {
        if (_ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        if (!refundableToken[tokenId]) revert NotRefundableToken(tokenId);
        amount = reservePool / refundableSupply;
        refundableToken[tokenId] = false;
        refundableSupply -= 1;
        reservePool -= amount;
        _burn(tokenId);
        delete _data[tokenId];
        emit ReserveDonated(tokenId, amount);
        _sendValue(CHARITY_ADDRESS, amount);
    }

    function donate()
        external
        nonReentrant
        onlyOwner
        financialFeaturesEnabled
        returns (uint256 amount)
    {
        amount = donationLiability;
        donationLiability = 0;
        emit DonationPaid(amount);
        _sendValue(CHARITY_ADDRESS, amount);
    }

    function setBaseURI(string calldata newURI) external onlyOwner {
        if (metadataFrozen) revert MetadataAlreadyFrozen();
        string memory previous = _baseTokenURI;
        _baseTokenURI = newURI;
        _emitBatchMetadataUpdate();
        emit BaseURIChanged(previous, newURI);
    }

    function freezeBaseURI() external onlyOwner {
        if (metadataFrozen) revert MetadataAlreadyFrozen();
        metadataFrozen = true;
        _emitBatchMetadataUpdate();
        emit BaseURIFrozen(_baseTokenURI);
    }

    function totalSupply() external view returns (uint256) {
        return _circulatingSupply;
    }

    function forDonation() external view returns (uint256) {
        return donationLiability;
    }

    function getData(uint256 tokenId) public view returns (uint256) {
        if (_ownerOf(tokenId) == address(0)) return MISSING_DATA;
        return _data[tokenId] & PUBLIC_DATA_MASK;
    }

    function categoryMinted(uint256 category) external view returns (uint256) {
        if (category >= RCATEGORIES_COUNT) revert InvalidTraitData();
        return _categoryMinted[category];
    }

    function categoryCapacity(uint256 category) public pure returns (uint256) {
        if (category >= RCATEGORIES_COUNT) revert InvalidTraitData();
        uint256 packed = _load(
            AlvaraTraitData.RANDOM_CATEGORY_TABLE_OFFSET,
            AlvaraTraitData.RANDOM_CATEGORY_COUNT * AlvaraTraitData.RANDOM_CATEGORY_ENTRY_BITS
        );
        return (packed >> (AlvaraTraitData.RANDOM_CATEGORY_ENTRY_BITS * category)) & 0x1fff;
    }

    /// @notice Returns the exact generated trait schema consumed by this deployment.
    /// @dev The backend verifies this manifest before accepting chain data.
    function traitDataManifest()
        external
        pure
        returns (
            uint256 schemaVersion,
            bytes32 categoriesSha256,
            bytes32 wordsSha256,
            uint256 totalSize,
            uint256 randomCategoryCount
        )
    {
        return (
            AlvaraTraitData.SCHEMA_VERSION,
            AlvaraTraitData.CATEGORIES_SHA256,
            AlvaraTraitData.WORDS_SHA256,
            AlvaraTraitData.TOTAL_SIZE,
            AlvaraTraitData.RANDOM_CATEGORY_COUNT
        );
    }

    function _setSaleState(uint8 newState) private {
        uint8 previous = saleState;
        saleState = newState;
        emit SaleStateChanged(previous, newState);
    }

    function _prepareToken(bool isRefundable, bool isDeveloper) private returns (uint256 tokenId) {
        tokenId = lifetimeMinted;
        if (tokenId >= MAX_TOKENS) revert SupplyExceeded();
        lifetimeMinted = tokenId + 1;
        uint16 category = _chooseCategory(tokenId);
        uint256 options = _generateOptions(category);
        _data[tokenId] = (uint256(category) << 35) | options;
        refundableToken[tokenId] = isRefundable;
        developerToken[tokenId] = isDeveloper;
    }

    function _chooseCategory(uint256 tokenId) internal returns (uint16 selected) {
        uint256 remainingTotal = 0;
        uint256[RCATEGORIES_COUNT] memory remaining;
        for (uint256 i = 0; i < RCATEGORIES_COUNT; ++i) {
            uint256 capacity = categoryCapacity(i);
            uint256 minted = _categoryMinted[i];
            if (minted > capacity) revert InvalidTraitData();
            remaining[i] = capacity - minted;
            remainingTotal += remaining[i];
        }
        if (remainingTotal == 0) revert SupplyExceeded();
        uint256 roll =
            uint256(keccak256(abi.encode(randomSeed, tokenId, "ALVARA_CATEGORY"))) % remainingTotal;
        for (uint16 i = 0; i < RCATEGORIES_COUNT; ++i) {
            if (roll < remaining[i]) {
                _categoryMinted[i] += 1;
                return i;
            }
            roll -= remaining[i];
        }
        revert InvalidTraitData();
    }

    function _generateOptions(uint16 category) internal returns (uint256) {
        if ((category & 1) == 1) return _generateSpecial(category);
        return _generateNormal(category);
    }

    function _generateSpecial(uint16 category) private returns (uint256 options) {
        uint16 collection = category >> 1;
        (uint16 start, uint16 size) = _includedRange(collection);
        if (size == 0) revert InvalidTraitData();
        _combinationCursor[category] = uint32(
            (uint256(_combinationCursor[category]) + AlvaraTraitData.COMBINATION_CURSOR_DELTA)
                % size
        );
        options = _load(
            AlvaraTraitData.INCLUDED_TABLE_OFFSET + AlvaraTraitData.INCLUDE_ENTRY_BITS
                * (start + _combinationCursor[category]),
            AlvaraTraitData.OPTION_VECTOR_BITS
        );
    }

    function _generateNormal(uint16 category) private returns (uint256 options) {
        uint16 collection = category >> 1;
        uint256 info = _load(AlvaraTraitData.CATEGORY_ENTRY_BITS * collection + 31, 56);
        uint32 spaceSize = uint32(info);
        if (spaceSize == 0) revert InvalidTraitData();
        for (uint256 attempt = 0; attempt < MAX_TRAIT_SEARCH_ATTEMPTS; ++attempt) {
            _combinationCursor[category] = uint32(
                (uint256(_combinationCursor[category]) + AlvaraTraitData.COMBINATION_CURSOR_DELTA)
                    % spaceSize
            );
            options = _intToOptions(collection, _combinationCursor[category]);
            if (_normalOptionsAllowed(collection, options)) return options;
        }
        revert TraitSearchExhausted(category);
    }

    function _normalOptionsAllowed(uint16 collection, uint256 options)
        internal
        pure
        returns (bool)
    {
        (uint16 includedStart, uint16 includedSize) = _includedRange(collection);
        if (_isIncluded(
                AlvaraTraitData.INCLUDED_TABLE_OFFSET + AlvaraTraitData.INCLUDE_ENTRY_BITS
                    * includedStart,
                includedSize,
                options
            )) {
            return false;
        }
        (uint16 ignoredStart, uint16 ignoredSize) = _ignoredRange(collection);
        return !_isIgnored(
            AlvaraTraitData.IGNORED_TABLE_OFFSET + AlvaraTraitData.IGNORE_ENTRY_BITS * ignoredStart,
            ignoredSize,
            options
        );
    }

    function _specialOptionsAllowed(uint16 collection, uint256 options)
        internal
        pure
        returns (bool)
    {
        (uint16 includedStart, uint16 includedSize) = _includedRange(collection);
        return _isIncluded(
            AlvaraTraitData.INCLUDED_TABLE_OFFSET + AlvaraTraitData.INCLUDE_ENTRY_BITS
                * includedStart,
            includedSize,
            options
        );
    }

    function _includedRange(uint16 collection) private pure returns (uint16 start, uint16 size) {
        uint256 info = _load(AlvaraTraitData.CATEGORY_ENTRY_BITS * collection + 31, 56);
        size = uint16((info >> 32) & 0xf);
        start = uint16((info >> 36) & 0xff);
    }

    function _ignoredRange(uint16 collection) private pure returns (uint16 start, uint16 size) {
        uint256 info = _load(AlvaraTraitData.CATEGORY_ENTRY_BITS * collection + 31, 56);
        size = uint16((info >> 44) & 0xf);
        start = uint16((info >> 48) & 0xff);
    }

    function _intToOptions(uint16 collection, uint256 number)
        private
        pure
        returns (uint256 options)
    {
        uint16 attrInfo = uint16(_load(AlvaraTraitData.CATEGORY_ENTRY_BITS * collection + 20, 11));
        uint16 attrCount = attrInfo & 0x7;
        uint16 attrStart = attrInfo >> 3;
        if (attrCount == 0) revert InvalidTraitData();
        uint256 attrs = _load(
            AlvaraTraitData.ATTRIBUTE_TABLE_OFFSET + AlvaraTraitData.ATTRIBUTE_ENTRY_BITS
                * attrStart + 20,
            AlvaraTraitData.ATTRIBUTE_ENTRY_BITS * attrCount - 20
        );
        for (uint256 i = 0; i < attrCount; ++i) {
            uint16 placeMultiplier = uint16(attrs);
            if (placeMultiplier == 0) revert InvalidTraitData();
            attrs >>= AlvaraTraitData.ATTRIBUTE_ENTRY_BITS;
            options = (options << 5) + (number / placeMultiplier);
            number %= placeMultiplier;
        }
    }

    function _isIncluded(uint256 shift, uint16 size, uint256 options) private pure returns (bool) {
        for (uint256 i = 0; i < size; ++i) {
            if ((_load(shift, 35) ^ options) == 0) return true;
            shift += AlvaraTraitData.INCLUDE_ENTRY_BITS;
        }
        return false;
    }

    function _isIgnored(uint256 shift, uint16 size, uint256 options) private pure returns (bool) {
        for (uint256 i = 0; i < size; ++i) {
            uint256 entry = _load(shift, AlvaraTraitData.IGNORE_ENTRY_BITS);
            uint256 positionMask = entry & 0x7ffffffff;
            uint256 ignored = entry >> AlvaraTraitData.IGNORE_OPTIONS_LSB_SHIFT;
            if (((options & positionMask) ^ ignored) == 0) return true;
            shift += AlvaraTraitData.IGNORE_ENTRY_BITS;
        }
        return false;
    }

    function _totalBucketCapacity() private pure returns (uint256 total) {
        for (uint256 i = 0; i < RCATEGORIES_COUNT; ++i) {
            total += categoryCapacity(i);
        }
    }

    function _load(uint256 shift, uint256 bitSize) private pure returns (uint256) {
        uint256 end = shift + bitSize;
        uint256 startId = shift >> 8;
        uint256 finishId = end >> 8;
        if (startId >= AlvaraTraitData.WORD_COUNT || finishId >= AlvaraTraitData.WORD_COUNT) {
            revert InvalidTraitData();
        }
        if (startId == finishId) {
            return (AlvaraTraitData.word(startId) << uint8(shift)) >> (256 - bitSize);
        }
        uint8 leftShift = uint8(shift);
        uint8 endShift = uint8(end);
        return ((AlvaraTraitData.word(startId) << leftShift) >> (leftShift - endShift))
            + (AlvaraTraitData.word(finishId) >> (256 - endShift));
    }

    function _sendValue(address recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = payable(recipient).call{ value: amount }("");
        if (!success) revert TransferFailed(recipient, amount);
    }

    function _emitBatchMetadataUpdate() private {
        if (_circulatingSupply != 0) emit BatchMetadataUpdate(0, lifetimeMinted - 1);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, IERC165)
        returns (bool)
    {
        return interfaceId == ERC4906_INTERFACE_ID || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address from)
    {
        from = super._update(to, tokenId, auth);
        if (from == address(0)) _circulatingSupply += 1;
        else if (to == address(0)) _circulatingSupply -= 1;
    }
}
