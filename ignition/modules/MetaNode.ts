import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

export default buildModule("MetaNodeToken", m => {
  const MetaNodeToken = m.contract("MetaNodeToken");
  return {
    MetaNodeToken
  }
})