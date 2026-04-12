import hre, { network } from "hardhat"
import { upgrades } from "@openzeppelin/hardhat-upgrades"
import { expect } from "chai"

const log = (msg: string) => {
  console.log(`>>> ${msg}`)
}

const connection = await network.connect()
const { ethers, networkHelpers } = connection

const metaNodePerBlock = 100n
const blockHeight = 1000
const unstakeLockedBlocks = 10
const minDepositeAmount = ethers.parseEther("1")
describe("stake test", async () => {
  async function deployFixtrue() {
    const [admin, user1, user2, user3] = await ethers.getSigners()
    const erc20 = await ethers.getContractFactory("MetaNodeToken")
    const erc20Contract = await erc20.connect(admin).deploy()
    await erc20Contract.waitForDeployment()
    const erc20Address = await erc20Contract.getAddress()

    const blockNumber = await ethers.provider.getBlockNumber()

    const upgradeApi = await upgrades(hre, connection)
    const metaNodeStake = await ethers.getContractFactory("MetaNodeStake")
    const stakeProxyContract = await upgradeApi.deployProxy(
      metaNodeStake.connect(admin),
      [erc20Address, blockNumber, blockNumber + blockHeight, metaNodePerBlock],
      { kind: "uups" },
    )
    await stakeProxyContract.waitForDeployment()
    const metaNodeStakeAddress = await stakeProxyContract.getAddress()
    await stakeProxyContract
      .connect(admin)
      .addPool(ethers.ZeroAddress, 5, minDepositeAmount, unstakeLockedBlocks, false)

    return {
      stakeProxyContract,
      erc20Contract,
      admin,
      user1,
      user2,
      user3,
      blockNumber,
      erc20Address,
      metaNodeStakeAddress,
    }
  }

  it("deploy", async () => {
    const { stakeProxyContract, blockNumber } = await networkHelpers.loadFixture(deployFixtrue)
    log(`当前区块高度: ${blockNumber}`)
    const poolLength = await stakeProxyContract.poolLength()
    log(`当前区块长度: ${poolLength}`)
    expect(poolLength).to.be.gt(0)
  })

  it("withdraw state", async () => {
    const { stakeProxyContract } = await networkHelpers.loadFixture(deployFixtrue)
    await stakeProxyContract.pauseWithDraw()
    const withdrawPaused = await stakeProxyContract.withDrawPaused()
    expect(withdrawPaused).to.true
    await stakeProxyContract.unPauseWithDraw()
    const res = await stakeProxyContract.withDrawPaused()
    expect(res).to.false
  })

  it("claim state", async () => {
    const { stakeProxyContract } = await networkHelpers.loadFixture(deployFixtrue)
    await stakeProxyContract.pauseClaim()
    const res1 = await stakeProxyContract.claimPaused()
    expect(res1).to.true

    await stakeProxyContract.unPauseClaim()
    const res2 = await stakeProxyContract.claimPaused()
    expect(res2).to.false
  })

  it("blocknumber", async () => {
    const { stakeProxyContract } = await networkHelpers.loadFixture(deployFixtrue)
    const blockNumber = await ethers.provider.getBlockNumber()
    const startBlockNumber = blockNumber
    await stakeProxyContract.setStartBlock(startBlockNumber)
    const start = await stakeProxyContract.startBlock()
    expect(start).to.eq(startBlockNumber)

    const endBlock = start + 100n
    await stakeProxyContract.setEndBlock(endBlock)
    const _endBlock = await stakeProxyContract.endBlock()
    expect(endBlock).to.eq(_endBlock)
  })

  it("addPool", async () => {
    const { stakeProxyContract, erc20Address } = await networkHelpers.loadFixture(deployFixtrue)
    const poolWeight = 10
    const withUpdate = false
    const minDepositeAmount = ethers.parseEther("1")
    await stakeProxyContract.addPool(erc20Address, poolWeight, minDepositeAmount, unstakeLockedBlocks, withUpdate)
    const len = await stakeProxyContract.poolLength()
    expect(len).to.eq(2)
  })

  it("getMultiplier", async () => {
    const { stakeProxyContract } = await networkHelpers.loadFixture(deployFixtrue)
    const fromBlock = await stakeProxyContract.startBlock()
    const toBlock = fromBlock + 10n
    const mul = await stakeProxyContract.getMultiplier(fromBlock, toBlock)
    expect(mul).to.eq(metaNodePerBlock * (toBlock - fromBlock))
  })

  it("deposite and unstake", async () => {
    const { stakeProxyContract, admin, user1, user2, user3, erc20Contract, metaNodeStakeAddress, erc20Address } =
      await networkHelpers.loadFixture(deployFixtrue)
    await expect(stakeProxyContract.connect(user1).depositeETH({ value: ethers.parseEther("0.1") })).to.revertedWith(
      "deposite amount is too small",
    )

    await stakeProxyContract.connect(user1).depositeETH({ value: ethers.parseEther("10") })
    await stakeProxyContract.connect(user2).depositeETH({ value: ethers.parseEther("20") })
    const poolWeight = 10
    const withUpdate = false
    const minDepositeAmount = ethers.parseEther("1")
    await stakeProxyContract.addPool(erc20Address, poolWeight, minDepositeAmount, unstakeLockedBlocks, withUpdate)
    await erc20Contract.connect(admin).transfer(user3.address, ethers.parseEther("1000"))
    await erc20Contract.connect(user3).approve(metaNodeStakeAddress, ethers.parseEther("200"))
    await expect(stakeProxyContract.connect(user3).deposite(1, ethers.parseEther("300"))).revert(ethers)
    await stakeProxyContract.connect(user3).deposite(1, ethers.parseEther("200"))

    const user1Stake = await stakeProxyContract.stakingBalance(0, user1.address)
    const user2Stake = await stakeProxyContract.stakingBalance(0, user2.address)
    const user3Stake = await stakeProxyContract.stakingBalance(1, user3.address)

    expect(user1Stake).to.eq(ethers.parseEther("10"))
    expect(user2Stake).to.eq(ethers.parseEther("20"))
    expect(user3Stake).to.eq(ethers.parseEther("200"))

    await stakeProxyContract.connect(user1).unstake(0, ethers.parseEther("2"))
    await stakeProxyContract.connect(user2).unstake(0, ethers.parseEther("2"))
    await stakeProxyContract.connect(user3).unstake(1, ethers.parseEther("10"))

    {
      const user1Stake = await stakeProxyContract.stakingBalance(0, user1.address)
      const user2Stake = await stakeProxyContract.stakingBalance(0, user2.address)
      const user3Stake = await stakeProxyContract.stakingBalance(1, user3.address)

      expect(user1Stake).to.eq(ethers.parseEther("8"))
      expect(user2Stake).to.eq(ethers.parseEther("18"))
      expect(user3Stake).to.eq(ethers.parseEther("190"))
      await stakeProxyContract.massUpdatePools()
    }

    log(user1.address)
    const user1BalanceBefore = await ethers.provider.getBalance(user1.address)
    const user2BalanceBefore = await ethers.provider.getBalance(user2.address)
    const user3BalanceBefore = await erc20Contract.balanceOf(user3.address)
    log("提现前")
    log(`${user1BalanceBefore}`)
    log(`${user2BalanceBefore}`)
    log(`${user3BalanceBefore}`)

    // 跳过锁定区块提现
    for (let i = 0; i < unstakeLockedBlocks; i++) {
      await ethers.provider.send("evm_mine", [])
    }

    await stakeProxyContract.connect(user1).withdraw(0)
    await stakeProxyContract.connect(user2).withdraw(0)
    await stakeProxyContract.connect(user3).withdraw(1)

    const user1Balance = await ethers.provider.getBalance(user1.address)
    const user2Balance = await ethers.provider.getBalance(user2.address)
    const user3Balance = await erc20Contract.balanceOf(user3.address)
    log("提现后")
    log(`${user1Balance}`)
    log(`${user2Balance}`)
    log(`${user3Balance}`)

    // 提现有gas费，所以应该有误差
    expect(user1Balance - user1BalanceBefore)
      .to.lt(ethers.parseEther("2"))
      .to.gt(ethers.parseEther("1.9"))

    expect(user2Balance - user2BalanceBefore)
      .to.lt(ethers.parseEther("2"))
      .to.gt(ethers.parseEther("1.9"))
    expect(user3Balance - user3BalanceBefore).to.eq(ethers.parseEther("10"))
  })
})
