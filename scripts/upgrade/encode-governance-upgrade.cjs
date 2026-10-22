// Offline encoder only: no RPC clients, wallets, deployment or broadcast.
const fs=require('fs');
const crypto=require('crypto');
const assert=require('assert/strict');
const {ethers}=require('ethers');
const BRIDGES={11155111:'0x9809D527544054bbb7357FB5b9e484590A72f2DF',97:'0xaf1c879A6052701bEA56373bcF6F9fB4568C7c70',84532:'0x7740B9be2886751D9bB8E12c4548F33F20caFc70'};
const sha=hex=>crypto.createHash('sha256').update(Buffer.from(hex.slice(2),'hex')).digest('hex');
function encodeGovernanceUpgrade(input){
 const plan=JSON.parse(fs.readFileSync(input.policy));
 const chain=plan.chains.find(c=>c.chainId===input.chainId);
 assert(chain && BRIDGES[input.chainId]?.toLowerCase()===chain.bridge.toLowerCase(),'Unsupported testnet target');
 const bridge=JSON.parse(fs.readFileSync(input.bridgeArtifact));
 const acl=JSON.parse(fs.readFileSync(input.aclArtifact));
 assert(bridge.contractName==='Bridge' && acl.contractName==='PsyACLManager');
 const iface=new ethers.utils.Interface(bridge.abi);
 const admin=new ethers.utils.Interface(['function upgrade(address,address)','function upgradeAndCall(address,address,bytes)']);
 const check=value=>{
  const address=ethers.utils.getAddress(value);
  assert(address!==ethers.constants.AddressZero,'Zero implementation');
  assert(![...Object.values(BRIDGES),chain.contracts.PsyACLManager,chain.proxyAdmin,chain.oldImplementation].some(a=>a.toLowerCase()===address.toLowerCase()),'Implementation is an existing target/old implementation');
  if(!input.simulationOnly)assert(!/^0x0{34}00[23]0[23]0$/i.test(address),'Simulation address is not deployable');
  return address;
 };
 const nextBridge=check(input.bridgeImplementation),nextAcl=check(input.aclImplementation);
 assert(nextBridge!==nextAcl,'Distinct implementations required');
 assert(chain.tokens.length===chain.configs.length && chain.tokens.length===3);
 assert(chain.tokens[1].toLowerCase()===chain.contracts.USDTToken.toLowerCase());
 assert(chain.configs[1].minDepositAmount==='1000000' && chain.configs[1].depositCapacity==='40000000000' && chain.configs[1].depositRefillPerSecond==='1666666666','Unreviewed pUSDT policy');
 const initialize=iface.encodeFunctionData('initializeFlowLimits',[chain.tokens,chain.configs]);
 return {
  offline_only:true,simulation_only:!!input.simulationOnly,chainId:input.chainId,bridge:chain.bridge,proxyAdmin:chain.proxyAdmin,
  oldBridgeImplementation:chain.oldImplementation,oldBridgeRuntimeSha256:chain.oldRuntimeSha256,
  newBridgeImplementation:nextBridge,newAclImplementation:nextAcl,
  bridgeRuntimeSha256:sha(bridge.deployedBytecode),aclRuntimeSha256:sha(acl.deployedBytecode),
  aclUpgrade:{to:chain.proxyAdmin,value:'0',data:admin.encodeFunctionData('upgrade',[chain.contracts.PsyACLManager,nextAcl])},
  bridgeUpgrade:{to:chain.proxyAdmin,value:'0',data:admin.encodeFunctionData('upgradeAndCall',[chain.bridge,nextBridge,initialize])},
 };
}
module.exports={encodeGovernanceUpgrade};
if(require.main===module)process.stdout.write(JSON.stringify(encodeGovernanceUpgrade(JSON.parse(fs.readFileSync(0,'utf8'))),null,2)+'\n');
