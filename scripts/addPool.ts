import { network } from "hardhat"

async function main() {
  const connection = await network.connect()
  const { ethers } = connection
  const metaNodeStake = await ethers.getContractAt("MetaNodeStake", "0x682145EfbbC02ab7697f6D0B28a69DC85B54e78e")
  const [signer] = await ethers.getSigners()

  // 获取当前nonce和待处理交易数
  const nonce = await ethers.provider.getTransactionCount(signer.address, "latest")
  const pendingNonce = await ethers.provider.getTransactionCount(signer.address, "pending")

  console.log("当前nonce: ", nonce)
  console.log("待处理nonce: ", pendingNonce)

  if (pendingNonce > nonce) {
    const waitforCount = pendingNonce - nonce
    console.log(`有${waitforCount}个交易待处理，请等待他们交易完再试`)
    return
  }

  const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

  try {
    console.log("正在发送交易...")
    const tx = await metaNodeStake
      .connect(signer)
      .addPool(ethers.ZeroAddress, 500, 100, 20, true, { nonce, gasLimit: 500000 })
    const receipt = await tx.wait()

    console.log("交易成功! Gas 使用:", receipt?.gasUsed.toString())
    console.log("区块号:", receipt?.blockNumber)

    await wait(2000)
    const poolLength = await metaNodeStake.poolLength()
    console.log("%c Line:36 🥒 poolLength", "color:#4fff4B", poolLength)
  } catch (error) {}
}

main().catch((error) => {
  console.log("%c Line:41 🥪 error", "color:#6ec1c2", error)
})
