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

contract MetaNodeStake is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");
    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");

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

    Pool[] public pool; // 奖金池列表

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
    event UpdatePool(
        uint256 indexed poolId,
        uint256 indexed lastRewardBlock,
        uint256 totalMetaNode
    );
    event SetPoolWeight(
        uint256 pid,
        uint256 poolWeight,
        uint256 totalPoolWeight
    );

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
        require(
            _startBlock < _endBlock && _MetaNodePerBlock > 0,
            "Invalid params"
        );

        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        setMetaNode(_MetaNode);

        startBlock = _startBlock;
        endBlock = _endBlock;
        MetaNodePerBlock = _MetaNodePerBlock;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADE_ROLE) {}

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
        require(
            _startBlock < endBlock,
            "startBlock must smaller than endBlock"
        );
        startBlock = _startBlock;

        emit SetStartBlock(_startBlock);
    }

    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(startBlock < _endBlock, "endBlock must bigger than startBlock");
        endBlock = _endBlock;

        emit SetEndBlock(_endBlock);
    }

    function setMetaNodePerBlock(
        uint256 _MetaNodePerBlock
    ) public onlyRole(ADMIN_ROLE) {
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
            require(
                _stTokenAddress != address(0),
                "invalid staking token address"
            );
        } else {
            require(
                _stTokenAddress == address(0),
                "invalid staking token address"
            );
        }

        require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");
        require(block.number < endBlock, "Already ended");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;

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

        emit AddPool(
            _stTokenAddress,
            _poolWeight,
            lastRewardBlock,
            _minDepositeAmount,
            _unstakeLockedBlocks
        );
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

    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256 multiplier) {
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

        (bool success1, uint256 totalMetaNode) = getMultiplier(
            poolItem.lastRewardBlock,
            block.number
        ).tryMul(poolItem.poolWeight);
        require(success1, "overflow");

        (success1, totalMetaNode) = totalMetaNode.tryDiv(totalPoolWeight);
        require(success1, "overflow");

        uint256 stSupply = poolItem.stTokenAmount;
        if (stSupply > 0) {
            (bool success2, uint256 totalMetaNode_) = totalMetaNode.tryMul(
                1 ether
            );
            require(success2, "overflow");

            (success2, totalMetaNode_) = totalMetaNode_.tryDiv(stSupply);
            require(success2, "overflow");

            (bool success3, uint256 accMetaNodePerST) = poolItem
                .accMetaNodePerST
                .tryAdd(totalMetaNode_);
            require(success3, "overflow");
            poolItem.accMetaNodePerST = accMetaNodePerST;
        }

        poolItem.lastRewardBlock = block.number;

        emit UpdatePool(_pid, poolItem.lastRewardBlock, totalMetaNode);
    }

    function setPoolWeight(
        uint256 _pid,
        uint256 _poolWeight,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
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
}
