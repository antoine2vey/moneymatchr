import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";


const Moneymatchr = buildModule('Moneymatchr', (m) => {
  const moneymatchr = m.contract('Moneymatchr', ['0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266', '0x5FbDB2315678afecb367f032d93F642f64180aa3'])

  return { 
    moneymatchr
  }
})

export default Moneymatchr;
