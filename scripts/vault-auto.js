const Web3 = require("web3");
const Strategy = require('../build/contracts/StrategyCafeLP.json');

const fromAddress = "";
const vaultAddresses = [""];
const privateKey = "";
const chainID = 56;

const web3 = new Web3(
  new Web3.providers.HttpProvider(
    "https://bsc-dataseed1.defibit.io/"
  )
);

let strategyContract;

const harvest = async (vaultAddress) => {
  strategyContract = new web3.eth.Contract(Strategy.abi, vaultAddress);
  const nonce = await web3.eth.getTransactionCount(fromAddress);
  const gasPriceWei = await web3.eth.getGasPrice();
  const data = strategyContract.methods.harvest().encodeABI()

  const signedTx  = await web3.eth.accounts.signTransaction({
      to: vaultAddress,
      gas: 2000000,
      data: data,
      gasPrice: gasPriceWei,
      nonce: nonce,
      chainId: chainID
  }, privateKey)

  await web3.eth.sendSignedTransaction(signedTx.rawTransaction || signedTx.rawTransaction);
}

function sleep (time) {
  return new Promise((resolve) => setTimeout(resolve, time));
}

async function main() {
  
  while(1) {
    try {
        for (var i = 0; i < vaultAddresses.length; i++) {
            await harvest(vaultAddresses[i]);
        }
    }catch(err) {
        console.log(err);
    }
    await sleep(60000);
  }
}

main();
