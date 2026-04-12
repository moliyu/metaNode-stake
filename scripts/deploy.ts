import hre, { network } from "hardhat"
import { upgrades } from "@openzeppelin/hardhat-upgrades"

const connection = await network.connect()
const { ethers } = connection

const [signer] = await ethers.getSigners()
const metaNodeTokenAddress = "0x5ac237DB8365410a54B4f90FBC40FB9D8F42BCAe"

const metaNodeStake = await ethers.getContractFactory("MetaNodeStake")

const startBlock = 1
const endBlock = 999999999999
const metaNodePerBlock = ethers.parseEther("1")

const upgradeApi = await upgrades(hre, connection)
const stake = await upgradeApi.deployProxy(
  metaNodeStake,
  [metaNodeTokenAddress, startBlock, endBlock, metaNodePerBlock],
  { kind: "uups", initializer: "initialize" },
)
await stake.waitForDeployment()
const stakeAddress = await stake.getAddress()

console.log("MetaNodeStake contract deployed to:", stakeAddress)
