// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./PriceConverter.sol";

error Raffle__NotEnoughETHEntered();
error Raffle__TransferFailed();
error Raffle__NotOpen();
error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);

/**
 * @title Raffle/Lottery Contract
 * @author Menno Martens
 * @notice This contract allows to create a temperproof decentralized lottery, the contract also reserves a commision to cover the costs of upkeep
 * @dev The contract implements Chainlink VRF v2 and Chainlink Keepers
 */

contract Raffle is VRFConsumerBaseV2, KeeperCompatibleInterface {
    /* Type Declarations */
    enum RaffleState {
        OPEN,
        CALCULATING
    }

    /* State Variables */
    using PriceConverter for uint256;
    AggregatorV3Interface private s_priceFeed;

    uint256 private immutable i_entranceFee;
    address payable[] private s_players;
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_gasLane;
    uint64 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;
    uint32 private constant NUM_WORDS = 1;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint256 private s_lastTimestamp;

    // Lottery Variables
    address private s_recentWinner;
    RaffleState private s_raffleState;
    uint256 private immutable i_interval;
    uint256 private s_contractCost;

    /* Events */
    event RaffleEnter(address indexed player);
    event RequestRaffleWinner(uint256 indexed requestId);
    event WinnerPicked(address indexed winner);

    constructor(
        address vrfCoordinatorV2,
        address priceFeedAddress,
        uint256 entranceFee,
        bytes32 gasLane,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        uint256 interval,
        uint256 contractCost
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_entranceFee = entranceFee;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_gasLane = gasLane;
        i_callbackGasLimit = callbackGasLimit;
        i_subscriptionId = subscriptionId;
        s_raffleState = RaffleState.OPEN;
        s_lastTimestamp = block.timestamp;
        i_interval = interval;
        s_contractCost = contractCost;
        s_priceFeed = AggregatorV3Interface(priceFeedAddress);
    }

    function getPriceFeed() public view returns (AggregatorV3Interface) {
        return s_priceFeed;
    }

    function enterRaffle() public payable {
        if (msg.value < i_entranceFee) {
            revert Raffle__NotEnoughETHEntered();
        }
        if (s_raffleState != RaffleState.OPEN) {
            revert Raffle__NotOpen();
        }
        s_players.push(payable(msg.sender));
        emit RaffleEnter(msg.sender);
    }

    function performUpkeep(
        bytes calldata /* performData */
    ) external override {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_raffleState)
            );
        }
        s_raffleState = RaffleState.CALCULATING;
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            NUM_WORDS
        );
        setContractCost();
        emit RequestRaffleWinner(requestId);
    }

    function setContractCost() private {
        s_contractCost = s_contractCost;
        // write custom function to calculate contract cost
    }

    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        override
        returns (
            bool upkeepNeeded,
            bytes memory /* performData */
        )
    {
        bool isOpen = (RaffleState.OPEN == s_raffleState);
        bool timePassed = ((block.timestamp - s_lastTimestamp) > i_interval);
        bool hasPlayers = (s_players.length > 0);
        bool hasBalance = address(this).balance > 0;
        bool hasEnoughBalance = (address(this).balance > (s_contractCost * s_players.length));
        bool upkeepNeeded = (isOpen && timePassed && hasBalance && hasPlayers && hasEnoughBalance);
        return (upkeepNeeded, "0x0");
    }

    function fulfillRandomWords(
        uint256, /* requestId */
        uint256[] memory randomWords
    ) internal override {
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable recentWinner = s_players[indexOfWinner];
        s_recentWinner = recentWinner;
        s_raffleState = RaffleState.OPEN;
        s_players = new address payable[](0);
        s_lastTimestamp = block.timestamp;
        (bool success, ) = recentWinner.call{
            value: address(this).balance - (s_players.length * s_contractCost)
        }("");
        if (!success) {
            revert Raffle__TransferFailed();
        }
        emit WinnerPicked(recentWinner);
    }

    function getEntranceFee() public view returns (uint256) {
        return i_entranceFee;
    }

    function getPlayer(uint256 index) public view returns (address) {
        return s_players[index];
    }

    function getRecentWinner() public view returns (address) {
        return s_recentWinner;
    }

    function getRaffleState() public view returns (RaffleState) {
        return s_raffleState;
    }

    function getNumWords() public pure returns (uint256) {
        return NUM_WORDS;
    }

    function getNumberOfPlayers() public view returns (uint256) {
        return s_players.length;
    }

    function getLatestTimestamp() public view returns (uint256) {
        return s_lastTimestamp;
    }

    function getRequestConfirmations() public pure returns (uint256) {
        return REQUEST_CONFIRMATIONS;
    }

    function getInterval() public view returns (uint256) {
        return i_interval;
    }

    function getSubscriptionId() public view returns (uint64) {
        return i_subscriptionId;
    }

    function getContractCost() public view returns (uint256) {
        return s_contractCost;
    }

    function getAmountEthtoWin() public view returns (uint256) {
        return (address(this).balance - (s_contractCost * s_players.length));
    }

    function getUsdtoWin() public view returns (uint256) {
        // Get USD value of ETH

        return
            (address(this).balance - (s_contractCost * s_players.length)).getConversionRate(
                s_priceFeed
            );
    }
}