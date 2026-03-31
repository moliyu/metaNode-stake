import hre, { network } from "hardhat";
import { upgrades } from "@openzeppelin/hardhat-upgrades";
import { expect } from "chai";

const log = (msg: string) => {
  console.log(`>>> ${msg}`);
};

const connection = await network.connect();
const { ethers, networkHelpers } = connection;
describe("stake test", async () => {
  async function deployFixtrue() {
    const metaNodePerBlock = 100n;
    const blockHeight = 1000;
    const unstakeLockedBlocks = 10;

    const [admin, user1, user2, user3] = await ethers.getSigners();
    const erc20 = await ethers.getContractFactory("MetaNodeToken");
    const erc20Contract = await erc20.connect(admin).deploy();
    await erc20Contract.waitForDeployment();
    const erc20Address = await erc20Contract.getAddress();

    const blockNumber = await ethers.provider.getBlockNumber();

    const upgradeApi = await upgrades(hre, connection);
    const metaNodeStake = await ethers.getContractFactory("MetaNodeStake");
    const stakeProxyContract = await upgradeApi.deployProxy(
      metaNodeStake.connect(admin),
      [erc20Address, blockNumber, blockNumber + blockHeight, metaNodePerBlock],
      { kind: "uups" },
    );
    await stakeProxyContract.waitForDeployment();
    const metaNodeStakeAddress = await stakeProxyContract.getAddress();
    await stakeProxyContract
      .connect(admin)
      .addPool(ethers.ZeroAddress, 5, 1e15, unstakeLockedBlocks, false);

    return {
      stakeProxyContract,
      erc20Contract,
      admin,
      user1,
      user2,
      user3,
      blockNumber,
    };
  }

  it("deploy", async () => {
    const { stakeProxyContract, blockNumber } =
      await networkHelpers.loadFixture(deployFixtrue);
    log(`当前区块高度: ${blockNumber}`);
    const poolLength = await stakeProxyContract.poolLength();
    log(`当前区块长度: ${poolLength}`);
    expect(poolLength).to.be.gt(0);
  });
});
