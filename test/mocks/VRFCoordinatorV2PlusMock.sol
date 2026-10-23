// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {
    VRFV2PlusClient
} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

interface IVRFV2PlusConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

contract VRFCoordinatorV2PlusMock {
    uint256 public nextRequestId = 1;
    address public lastConsumer;

    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata)
        external
        returns (uint256 requestId)
    {
        requestId = nextRequestId++;
        lastConsumer = msg.sender;
    }

    function fulfill(uint256 requestId, uint256 seed) external {
        uint256[] memory words = new uint256[](1);
        words[0] = seed;
        IVRFV2PlusConsumer(lastConsumer).rawFulfillRandomWords(requestId, words);
    }
}
