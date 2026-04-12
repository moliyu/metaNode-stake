// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract MetaNodeStake is Initializable, UUPSUpgradeable, PausableUpgradeable, AccessControlUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");
    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    uint256 public constant ETH_PID = 0;

    IERC20 public MetaNode;
    uint256 public startBlock; // 质押区块开始高度
    uint256 public endBlock; // 质押区块结束高度
    uint256 public MetaNodePerBlock; // 每个区块高度，MetaNode的奖励数量
    uint256 public totalPoolWeight; // 所有资金池的权重总和

    bool public withDrawPaused; // 是否暂停提现
    bool public claimPaused; // 是否暂停领取

    struct Pool {
        address stTokenAddress; // 质押代币的地址
        uint256 poolWeight;
        uint256 lastRewardBlock;
        uint256 accMetaNodePerST;
        uint256 stTokenAmount;
        uint256 minDepositAmount;
        uint256 unstakeLockedBlocks; // 解质押锁定的区块高度
    }

    struct UnstakeRequest {
        uint256 amount; // 用户取消质押代币的数量，要取出多少个token
        uint256 unlockBlocks; // 解质押的区块高度
    }

    struct User {
        uint256 stAmount; // 用户在当前资金池质押的代币数量
        uint256 finishedMetaNode; // 已领取的MetaNode数量
        uint256 pendingMetaNode; // 当前可领取的MetaNode数量
        UnstakeRequest[] requests; // 取消质押的记录
    }

    Pool[] public pool; // 奖金池列表

    mapping(uint256 => mapping(address => User)) public user;

    event SetMetaNode(IERC20 indexed metaNode);
    event PauseWithDraw();
    event UnPauseWithDraw();
    event PauseClaim();
    event UnPauseClaim();
    event SetStartBlock(uint256 indexed startBlock);
    event SetEndBlock(uint256 indexed endBlock);
    event SetMetaNodePerBlock(uint256 indexed endBlock);
    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositeAmount,
        uint256 unstakeLockedBlocks
    );
    event UpdatePoolInfo(
        uint256 indexed poolId,
        uint256 indexed minDepositeAmount,
        uint256 indexed unstakeLockedBlocks
    );
    event UpdatePool(uint256 indexed poolId, uint256 indexed lastRewardBlock, uint256 totalMetaNode);
    event SetPoolWeight(uint256 pid, uint256 poolWeight, uint256 totalPoolWeight);
    event Deposite(address indexed user, uint256 indexed poolId, uint256 amount);
    event RequestUnstake(address indexed user, uint256 indexed pid, uint256 amount);

    event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount, uint256 indexed blockNumber);

    event Claim(address indexed user, uint256 indexed poolId, uint256 MetaNodeReward);

    modifier checkPid(uint256 _pid) {
        require(_pid < pool.length, "invalid pid");
        _;
    }

    modifier whennotClaimPaused() {
        require(!claimPaused, "claim is paused");
        _;
    }

    modifier whennotWithdrawPaused() {
        require(!withDrawPaused, "withDraw is paused");
        _;
    }

    function initialize(
        IERC20 _MetaNode,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _MetaNodePerBlock
    ) public initializer {
        require(_startBlock < _endBlock && _MetaNodePerBlock > 0, "Invalid params");

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        setMetaNode(_MetaNode);

        startBlock = _startBlock;
        endBlock = _endBlock;
        MetaNodePerBlock = _MetaNodePerBlock;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADE_ROLE) {}

    function setMetaNode(IERC20 _MetaNode) public onlyRole(ADMIN_ROLE) {
        MetaNode = _MetaNode;

        emit SetMetaNode(_MetaNode);
    }

    function pauseWithDraw() public onlyRole(ADMIN_ROLE) {
        require(!withDrawPaused, "withDraw has already been paused");
        withDrawPaused = true;

        emit PauseWithDraw();
    }

    function unPauseWithDraw() public onlyRole(ADMIN_ROLE) {
        require(withDrawPaused, "withDraw has already been unpaused");
        withDrawPaused = false;

        emit UnPauseWithDraw();
    }

    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim has already been paused");
        claimPaused = true;

        emit PauseClaim();
    }

    function unPauseClaim() public onlyRole(ADMIN_ROLE) {
        require(claimPaused, "claim has already been unpaused");
        claimPaused = false;

        emit UnPauseClaim();
    }

    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(_startBlock < endBlock, "startBlock must smaller than endBlock");
        startBlock = _startBlock;

        emit SetStartBlock(_startBlock);
    }

    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(startBlock < _endBlock, "endBlock must bigger than startBlock");
        endBlock = _endBlock;

        emit SetEndBlock(_endBlock);
    }

    function setMetaNodePerBlock(uint256 _MetaNodePerBlock) public onlyRole(ADMIN_ROLE) {
        require(_MetaNodePerBlock > 0, "MetaNodePerBlock must be positive");
        MetaNodePerBlock = _MetaNodePerBlock;

        emit SetMetaNodePerBlock(_MetaNodePerBlock);
    }

    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositeAmount,
        uint256 _unstakeLockedBlocks,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
        if (pool.length > 0) {
            require(_stTokenAddress != address(0), "invalid staking token address");
        } else {
            require(_stTokenAddress == address(0), "invalid staking token address");
        }

        require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");
        require(block.number < endBlock, "Already ended");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;

        totalPoolWeight = totalPoolWeight + _poolWeight;
        pool.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewardBlock: lastRewardBlock,
                accMetaNodePerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositeAmount,
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );

        emit AddPool(_stTokenAddress, _poolWeight, lastRewardBlock, _minDepositeAmount, _unstakeLockedBlocks);
    }

    function massUpdatePools() public {
        uint256 size = pool.length;
        for (uint256 i = 0; i < size; i++) {
            updatePool(i);
        }
    }

    function updatePool(
        uint256 _pid,
        uint256 _minDepositeAmount,
        uint256 _unstakeLockedBlocks
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        Pool storage poolItem = pool[_pid];
        poolItem.minDepositAmount = _minDepositeAmount;
        poolItem.unstakeLockedBlocks = _unstakeLockedBlocks;

        emit UpdatePoolInfo(_pid, _minDepositeAmount, _unstakeLockedBlocks);
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256 multiplier) {
        require(_from <= _to, "invalid block");
        if (_from <= startBlock) {
            _from = startBlock;
        }
        if (_to > endBlock) {
            _to = endBlock;
        }
        require(_from <= _to, "end block must be greater than start");
        bool success;
        (success, multiplier) = (_to - _from).tryMul(MetaNodePerBlock);
        require(success, "multiplier overflow");
    }

    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage poolItem = pool[_pid];

        if (block.number <= poolItem.lastRewardBlock) {
            return;
        }

        uint256 totalMetaNode = (getMultiplier(poolItem.lastRewardBlock, block.number) * poolItem.poolWeight) /
            totalPoolWeight;

        uint256 stSupply = poolItem.stTokenAmount;
        if (stSupply > 0) {
            uint256 totalMetaNode_ = (totalMetaNode * 1 ether) / stSupply;
            poolItem.accMetaNodePerST += totalMetaNode_;
        }

        poolItem.lastRewardBlock = block.number;

        emit UpdatePool(_pid, poolItem.lastRewardBlock, totalMetaNode);
    }

    function setPoolWeight(uint256 _pid, uint256 _poolWeight, bool _withUpdate) public onlyRole(ADMIN_ROLE) {
        require(_poolWeight > 0, "invalid pool weight");

        if (_withUpdate) {
            massUpdatePools();
        }

        Pool storage pool_ = pool[_pid];
        totalPoolWeight = totalPoolWeight - pool_.poolWeight + _poolWeight;
        pool_.poolWeight = _poolWeight;

        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }

    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    function pendingMetaNodeByBlockNumber(
        uint256 _pid,
        address _user,
        uint256 _blockNumber
    ) public view checkPid(_pid) returns (uint256) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];
        uint256 accMetaNodePerST = pool_.accMetaNodePerST;
        uint256 stSupply = pool_.stTokenAmount;

        if (_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            uint256 multiplier = getMultiplier(pool_.lastRewardBlock, _blockNumber);
            uint256 MetaNodeForPool = (multiplier * pool_.poolWeight) / totalPoolWeight;
            accMetaNodePerST = accMetaNodePerST + (MetaNodeForPool * 1 ether) / stSupply;
        }

        return (user_.stAmount * accMetaNodePerST) / (1 ether) - user_.finishedMetaNode + user_.pendingMetaNode;
    }

    function pendingMetaNode(uint256 _pid, address _user) public view checkPid(_pid) returns (uint256) {
        return pendingMetaNodeByBlockNumber(_pid, _user, block.number);
    }

    function stakingBalance(uint256 _pid, address _user) external view checkPid(_pid) returns (uint256) {
        return user[_pid][_user].stAmount;
    }

    function withDrawAmount(
        uint256 _pid,
        address _user
    ) public view checkPid(_pid) returns (uint256 requestAmount, uint256 pendingWithdrawAmount) {
        User storage user_ = user[_pid][_user];

        for (uint256 i = 0; i < user_.requests.length; i++) {
            if (user_.requests[i].unlockBlocks < block.number) {
                pendingWithdrawAmount = pendingWithdrawAmount + user_.requests[i].amount;
            }
            requestAmount = requestAmount + user_.requests[i].amount;
        }
    }

    function depositeETH() public payable whenNotPaused {
        Pool storage pool_ = pool[ETH_PID];

        require(pool_.stTokenAddress == address(0), "invalid token address");
        uint256 amount = msg.value;
        require(amount > pool_.minDepositAmount, "deposite amount is too small");
        _deposite(ETH_PID, amount);
    }

    function _deposite(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid);

        if (user_.stAmount > 0) {
            // (bool success1, uint256 accST) = user_.stAmount.tryMul(
            //     pool_.poolWeight
            // );
            // require(success1, "overflow");
            // (success1, accST) = accST.tryDiv(1 ether);
            // require(success1, "overflow");

            // (bool success2, uint256 pendingMetaNode_) = accST.trySub(
            //     user_.finishedMetaNode
            // );
            // require(success2, "overflow");

            // if (pendingMetaNode_ > 0) {
            //     (bool success3, uint256 _pendingMetaNode) = user_
            //         .pendingMetaNode
            //         .tryAdd(pendingMetaNode_);
            //     require(success3, "overflow");
            //     user_.pendingMetaNode = _pendingMetaNode;
            // }
            uint256 pendingMetaNode_ = (user_.stAmount * pool_.poolWeight) / (1 ether) - user_.finishedMetaNode;
            if (pendingMetaNode_ > 0) {
                user_.pendingMetaNode = user_.pendingMetaNode + pendingMetaNode_;
            }
        }

        if (_amount > 0) {
            user_.stAmount += _amount;
        }

        pool_.stTokenAmount += _amount;

        user_.finishedMetaNode = (user_.stAmount * pool_.accMetaNodePerST) / (1 ether);

        emit Deposite(msg.sender, _pid, _amount);
    }

    function deposite(uint256 _pid, uint256 _amount) public whenNotPaused checkPid(_pid) {
        require(_pid != 0, "deposite not support ETH staking");
        Pool storage pool_ = pool[_pid];
        require(_amount > pool_.minDepositAmount, "deposite amount is too small");
        if (_amount > 0) {
            IERC20(pool_.stTokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }

        _deposite(_pid, _amount);
    }

    function unstake(uint256 _pid, uint256 _amount) public whenNotPaused checkPid(_pid) whennotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        require(user_.stAmount > _amount, "not enough staking balance");

        updatePool(_pid);

        uint256 pendingMetaNode_ = (user_.stAmount * pool_.accMetaNodePerST) / (1 ether) - user_.finishedMetaNode;

        if (pendingMetaNode_ > 0) {
            user_.pendingMetaNode = user_.pendingMetaNode + pendingMetaNode_;
        }

        if (_amount > 0) {
            user_.stAmount = user_.stAmount - _amount;
            user_.requests.push(
                UnstakeRequest({amount: _amount, unlockBlocks: block.number + pool_.unstakeLockedBlocks})
            );
        }

        pool_.stTokenAmount -= _amount;
        user_.finishedMetaNode = (user_.stAmount * pool_.accMetaNodePerST) / 1 ether;

        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid) public checkPid(_pid) whenNotPaused whennotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingWithdraw_;
        uint256 popNum_;

        for (uint256 i = 0; i < user_.requests.length; i++) {
            pendingWithdraw_ += user_.requests[i].amount;
            popNum_++;
        }

        for (uint256 i = 0; i < user_.requests.length - popNum_; i++) {
            user_.requests[i] = user_.requests[i + popNum_];
        }

        for (uint256 i = 0; i < popNum_; i++) {
            user_.requests.pop();
        }

        if (pendingWithdraw_ > 0) {
            if (pool_.stTokenAddress == address(0)) {
                _safeETHTransfer(msg.sender, pendingWithdraw_);
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(msg.sender, pendingWithdraw_);
            }
        }

        emit Withdraw(msg.sender, _pid, pendingWithdraw_, block.number);
    }

    function _safeMetaNodeTransfer(address _to, uint256 _amount) internal {
        uint256 MetaNodeBal = MetaNode.balanceOf(address(this));

        if (_amount > MetaNodeBal) {
            MetaNode.transfer(_to, MetaNodeBal);
        } else {
            MetaNode.transfer(_to, _amount);
        }
    }

    function _safeETHTransfer(address _to, uint256 _amount) internal {
        (bool success, bytes memory data) = address(_to).call{value: _amount}("");
        require(success, "ETH transfer call failed");

        if (data.length > 0) {
            require(abi.decode(data, (bool)), "ETH transfer operation not succeed");
        }
    }

    function claim(uint256 _pid) public whennotClaimPaused checkPid(_pid) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingMetaNode_ = (user_.stAmount * pool_.accMetaNodePerST) /
            1 ether -
            user_.finishedMetaNode +
            user_.pendingMetaNode;

        if (pendingMetaNode_ > 0) {
            user_.pendingMetaNode = 0;
            // _safe
        }
    }
}
