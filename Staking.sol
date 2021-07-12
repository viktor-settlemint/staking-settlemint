// SPDX-License-Identifier: MIT
/**
 * Copyright (C) SettleMint NV - All Rights Reserved
 *
 * Use of this file is strictly prohibited without an active license agreement.
 * Distribution of this file, via any medium, is strictly prohibited.
 *
 * For license inquiries, contact hello@settlemint.com
 */

pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
// https://docs.openzeppelin.com/contracts/4.x/api/proxy#transparent-vs-uups
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract StakingV2 is Initializable, UUPSUpgradeable, AccessControlUpgradeable, PausableUpgradeable {
  using Counters for Counters.Counter;
  using EnumerableSet for EnumerableSet.AddressSet;

  IERC20 dtxToken;
  Counters.Counter private payoutCounter;
  EnumerableSet.AddressSet private stakeholders;

  struct Stake {
    uint256 lockedDTX;
    uint256 startTimestamp;
  }

  bytes32 private  SUPER_ADMIN_ROLE;
  bytes32 private  ADMIN_ROLE;
  uint256 private lastPayoutTimestamp;
  uint256 private totalStakes;

  mapping(address => Stake) private stakeholderToStake;
  mapping(address => uint256) private claimRewards;
  mapping(uint256 => mapping(address => uint256)) private payoutCredits;

  event StakeTransactions(
    address indexed stakeholder,
    uint256 amount,
    uint8 txType,
    uint256 txTimestamp
  );
  event Rewards(address indexed stakeholder, uint256 amount, uint256 timestamp);

  modifier hasSuperAdminRole() {
    require(
      hasRole(SUPER_ADMIN_ROLE, msg.sender),
      "Caller is not a super admin"
    );
    _;
  }

  modifier hasAdminRole() {
    require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
    _;
  }

  function initialize(
    address superAdmin,
    address admin,
    address _dtxToken
  ) public initializer {
		AccessControlUpgradeable.__AccessControl_init();
		PausableUpgradeable.__Pausable_init(); 

		SUPER_ADMIN_ROLE = keccak256("SUPER_ADMIN_ROLE");
		ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Set up roles
    _setupRole(SUPER_ADMIN_ROLE, superAdmin);
    _setupRole(ADMIN_ROLE, superAdmin);
    _setupRole(ADMIN_ROLE, admin);

    dtxToken = IERC20(_dtxToken);
  }

	function _authorizeUpgrade(address) internal override hasSuperAdminRole {}

  function isStakeholder(address stakeholder) public view returns (bool) {
    return stakeholders.contains(stakeholder);
  }

  function addStakeholder(address stakeholder) internal whenNotPaused() {
    bool _isStakeholder = stakeholders.contains(stakeholder);

    if (!_isStakeholder) stakeholders.add(stakeholder);
  }

  function getLockedStakeDetails(address stakeholder)
    public
    view
    returns (Stake memory)
  {
    return 
      stakeholderToStake[stakeholder];
  }

  function getPayoutCredits(uint256 payoutCycle, address stakeholder)
    public
    view
    returns (uint256)
  {
    return payoutCredits[payoutCycle][stakeholder];
  }

  function createStake(address stakeholder, uint256 stake) public whenNotPaused() {
    bool transferResult = dtxToken.transferFrom(
      stakeholder,
      address(this),
      stake
    );

    require(transferResult, "DTX transfer failed");

    totalStakes += stake;

    bool _isStakeholder = stakeholders.contains(stakeholder);
    uint256 currTimestamp = block.timestamp;
    uint256 stakeStartTime;

    if (lastPayoutTimestamp > stakeholderToStake[stakeholder].startTimestamp) {
      stakeStartTime = lastPayoutTimestamp;
    } else {
      stakeStartTime = stakeholderToStake[stakeholder].startTimestamp;
    }

    if (_isStakeholder) {
      // update the payout credit for existing stake and stake duration
      payoutCredits[payoutCounter.current()][stakeholder] =
        payoutCredits[payoutCounter.current()][stakeholder] +
        ((stakeholderToStake[stakeholder].lockedDTX) *
          ((currTimestamp) - (stakeStartTime)));

      // update the stake
      stakeholderToStake[stakeholder].lockedDTX =
        (stakeholderToStake[stakeholder].lockedDTX) +
        (stake);
      stakeholderToStake[stakeholder].startTimestamp = currTimestamp;
    } else {
      addStakeholder(stakeholder);

      stakeholderToStake[stakeholder] = Stake({
        lockedDTX: stake,
        startTimestamp: currTimestamp
      });
    }

    emit StakeTransactions(stakeholder, stake, 0, currTimestamp);
  }

  function removeStake(uint256 stake) public whenNotPaused() {
    require(
      stakeholderToStake[msg.sender].lockedDTX >= stake,
      "Not enough staked!"
    );

    bool transferResult = dtxToken.transfer(msg.sender, stake);
    require(transferResult, "DTX transfer failed");

    uint256 currTimestamp = block.timestamp;
    uint256 stakeStartTime;

    if (lastPayoutTimestamp > stakeholderToStake[msg.sender].startTimestamp) {
      stakeStartTime = lastPayoutTimestamp;
    } else {
      stakeStartTime = stakeholderToStake[msg.sender].startTimestamp;
    }

    // update the payout credit for existing stake and stake duration
    payoutCredits[payoutCounter.current()][msg.sender] =
      payoutCredits[payoutCounter.current()][msg.sender] +
      ((stakeholderToStake[msg.sender].lockedDTX) *
        ((currTimestamp) - (stakeStartTime)));
    // update the stake
    stakeholderToStake[msg.sender].lockedDTX =
      (stakeholderToStake[msg.sender].lockedDTX) -
      (stake);
    stakeholderToStake[msg.sender].startTimestamp = currTimestamp;

    totalStakes -= stake;

    emit StakeTransactions(msg.sender, stake, 1, currTimestamp);
  }

  function stakeOf(address stakeholder) public view returns (uint256) {
    return stakeholderToStake[stakeholder].lockedDTX;
  }

  function getTotalStakes() public view returns (uint256) {
    return totalStakes;
  }

  function totalCredits(uint256 payoutCycle) public view returns (uint256) {
    uint256 totalCredits = 0;

    for (uint256 s = 0; s < stakeholders.length(); s += 1) {
      totalCredits =
        totalCredits +
        (payoutCredits[payoutCycle][stakeholders.at(s)]);
    }

    return totalCredits;
  }

  function rewardOf(address stakeholder) public view returns (uint256) {
    return claimRewards[stakeholder];
  }

  function totalRewards() public view returns (uint256) {
    uint256 totalRewards = 0;
    for (uint256 s = 0; s < stakeholders.length(); s += 1) {
      totalRewards = totalRewards + (claimRewards[stakeholders.at(s)]);
    }
    return totalRewards;
  }

  function monthlyReward() public view returns (uint256) {
    uint256 _totalRewards = totalRewards();
    require(
      dtxToken.balanceOf(address(this)) >= totalStakes + (_totalRewards),
      "Rewards are not available yet"
    );

    uint256 monthReward = dtxToken.balanceOf(address(this)) -
      (totalStakes) -
      (_totalRewards);

    return monthReward;
  }

  function calculatePayoutCredit(address stakeholder, uint256 currTimestamp)
    internal
    returns (address)
  {
    uint256 stakeStartTime;

    if (
      payoutCredits[payoutCounter.current()][stakeholder] == 0 &&
      stakeholderToStake[stakeholder].lockedDTX == 0
    ) {
      return stakeholder;
    }

    if (lastPayoutTimestamp > stakeholderToStake[stakeholder].startTimestamp) {
      stakeStartTime = lastPayoutTimestamp;
    } else {
      stakeStartTime = stakeholderToStake[stakeholder].startTimestamp;
    }

    payoutCredits[payoutCounter.current()][stakeholder] =
      payoutCredits[payoutCounter.current()][stakeholder] +
      ((stakeholderToStake[stakeholder].lockedDTX) *
        ((currTimestamp) - (stakeStartTime)));

    return address(0);
  }

  function calculateReward(
    address stakeholder,
    uint256 monthlyReward,
    uint256 totalCredits
  ) internal returns (uint256) {
    uint256 stakeholderRatio = ((
      payoutCredits[payoutCounter.current()][stakeholder]
    ) * (1000000000000000000)) / (totalCredits);

    return (monthlyReward * (stakeholderRatio)) / (1000000000000000000);
  }

  function distributeRewards() public hasAdminRole {
    uint256 monthlyReward = monthlyReward();
    uint256 currTimestamp = block.timestamp;
    address[] memory stakeholdersToRemove = new address[](
      stakeholders.length()
    );
    uint256 stakeholdersToRemoveIndex = 0;

    require(monthlyReward > 0, "Not enough rewards to distribute");

    // update payout credits
    for (uint256 s = 0; s < stakeholders.length(); s += 1) {
      address stakeholder = stakeholders.at(s);
      address staker = calculatePayoutCredit(stakeholder, currTimestamp);

      if (stakeholder != address(0)) {
        stakeholdersToRemove[stakeholdersToRemoveIndex] = staker;
        stakeholdersToRemoveIndex += 1;
      }
    }

    // Remove non-stakeholders
    for (uint256 s = 0; s < stakeholdersToRemove.length; s += 1) {
      stakeholders.remove(stakeholdersToRemove[s]);
    }

    uint256 totalCredits = totalCredits(payoutCounter.current());
    require(totalCredits > 0, "Total credits is 0");

    // Calculate rewards
    for (uint256 s = 0; s < stakeholders.length(); s += 1) {
      address stakeholder = stakeholders.at(s);
      uint256 rewards = calculateReward(
        stakeholder,
        monthlyReward,
        totalCredits
      );
      claimRewards[stakeholder] = claimRewards[stakeholder] + (rewards);
    }

    payoutCounter.increment();
    lastPayoutTimestamp = block.timestamp;
  }

  function withdrawAllReward() public hasAdminRole {
    for (uint256 s = 0; s < stakeholders.length(); s += 1) {
      address stakeholder = stakeholders.at(s);
      uint256 reward = claimRewards[stakeholder];
      bool transferResult = dtxToken.transfer(stakeholder, reward);

      require(transferResult, "DTX transfer failed");

      claimRewards[stakeholder] = 0;

      emit Rewards(stakeholder, reward, block.timestamp);
    }
  }

  function withdrawReward() public whenNotPaused() {
    uint256 reward = claimRewards[msg.sender];
    require(reward > 0, "No reward to withdraw");
    claimRewards[msg.sender] = 0;
    bool transferResult = dtxToken.transfer(msg.sender, reward);

    require(transferResult, "DTX transfer failed");

    emit Rewards(msg.sender, reward, block.timestamp);
  }

  function getTotalStakeholders() public view returns (uint256) {
    return stakeholders.length();
  }

  function refundLockedDTX() public hasSuperAdminRole {
    for (uint256 s = 0; s < stakeholders.length(); s += 1) {
      dtxToken.transfer(
        stakeholders.at(s),
        stakeholderToStake[stakeholders.at(s)].lockedDTX
      );
    }

    // Return remaining DTX to owner (platform commission)
    uint256 balance = dtxToken.balanceOf(address(this));
    dtxToken.transfer(msg.sender, balance);
  }

	function pauseContract() public hasSuperAdminRole {
		_pause();
	}

	function unPauseContract() public hasSuperAdminRole {
		_unpause();
	}

  function newGetTotalStakeholders() public view returns (uint256) {
    return stakeholders.length() + 100;
  }
}
