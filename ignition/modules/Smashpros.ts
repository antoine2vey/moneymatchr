import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";


const SmashprosModule = buildModule('Smashpros', (m) => {
  const smashpros = m.contract('Smashpros', ['0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'])

  return { 
    smashpros
  }
})

export default SmashprosModule;
