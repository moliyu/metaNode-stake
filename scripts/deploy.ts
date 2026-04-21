import hre, { network } from "hardhat"
import { upgrades } from "@openzeppelin/hardhat-upgrades"

const connection = await network.connect()
const { ethers } = connection

const [signer] = await ethers.getSigners()
const metaTokenContract = await ethers.getContractFactory("MetaNodeToken")
const metaToken = await metaTokenContract.deploy()
await metaToken.waitForDeployment()
const metaNodeTokenAddress = await metaToken.getAddress()
console.log("%c Line:12 🌮 metaNodeTokenAddress", "color:#b03734", metaNodeTokenAddress)

const metaNodeStake = await ethers.getContractFactory("MetaNodeStake")

const startBlock = 1
const endBlock = 999999999999
const metaNodePerBlock = ethers.parseEther("1")

const upgradeApi = await upgrades(hre, connection)
const stake = await upgradeApi.deployProxy(
  metaNodeStake,
  [metaNodeTokenAddress, startBlock, endBlock, metaNodePerBlock],
  { kind: "uups", initializer: "initialize" }
)
await stake.waitForDeployment()
const stakeAddress = await stake.getAddress()
console.log("%c Line:28 🍕 stakeAddress", "color:#ea7e5c", stakeAddress)

const tokenAmount = await metaToken.balanceOf(signer.address)
const tx = await metaToken.transfer(stakeAddress, tokenAmount)
await tx.wait()

console.log("transfer", ethers.formatUnits(tokenAmount, 18))
