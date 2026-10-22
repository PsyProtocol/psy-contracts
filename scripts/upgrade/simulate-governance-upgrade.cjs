// Local Anvil forks only. Public backends must be read-only. No signing keys.
const fs = require('fs');
const assert = require('assert/strict');
const crypto = require('crypto');
const { ethers } = require('ethers');
const IMPL = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const ADMIN = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103';
const OWNER = '0x490f8192725255c2c3de0cbce66312335ca019ad';
const BRIDGES = {11155111:'0x9809D527544054bbb7357FB5b9e484590A72f2DF',97:'0xaf1c879A6052701bEA56373bcF6F9fB4568C7c70',84532:'0x7740B9be2886751D9bB8E12c4548F33F20caFc70'};
const addr = word => ethers.utils.getAddress('0x' + word.slice(-40));
const sha = hex => crypto.createHash('sha256').update(Buffer.from(hex.slice(2),'hex')).digest('hex');
const split = hex => Array.from({length:8},(_,i)=>parseInt(hex.slice(2+i*8,10+i*8),16));
async function main() {
 const cfg=JSON.parse(fs.readFileSync(0,'utf8'));
 const u=new URL(cfg.rpc);
 assert(u.protocol==='http:' && u.hostname==='127.0.0.1' && u.port && !u.username && !u.password && u.pathname==='/' && !u.search && !u.hash);
 const p=new ethers.providers.JsonRpcProvider(u.href);
 assert(/anvil/i.test(await p.send('web3_clientVersion',[]))); await p.send('anvil_nodeInfo',[]);
 assert.equal((await p.getNetwork()).chainId,cfg.chainId);
 assert.equal(BRIDGES[cfg.chainId]?.toLowerCase(),cfg.bridge.toLowerCase());
 const plan=JSON.parse(fs.readFileSync(cfg.policy)).chains.find(c=>c.chainId===cfg.chainId);
 assert.equal(plan.bridge.toLowerCase(),cfg.bridge.toLowerCase());
 const artifact=JSON.parse(fs.readFileSync(cfg.artifact)); assert.equal(artifact.contractName,'Bridge');
 const artifactAt=name=>JSON.parse(fs.readFileSync(`artifacts/hardhat/src/${name}.sol/${name}.json`));
 const bridge=new ethers.Contract(cfg.bridge,artifact.abi,p);
 const oldImpl=addr(await p.getStorageAt(cfg.bridge,IMPL));
 assert.equal(oldImpl.toLowerCase(),plan.oldImplementation.toLowerCase());
 assert.equal(sha(await p.getCode(oldImpl)),plan.oldRuntimeSha256);
 const adminAddress=addr(await p.getStorageAt(cfg.bridge,ADMIN));
 const adminAbi=['function owner() view returns(address)','function upgrade(address,address)','function upgradeAndCall(address,address,bytes)'];
 const admin=new ethers.Contract(adminAddress,adminAbi,p);
 assert.equal((await admin.owner()).toLowerCase(),OWNER);
 assert.equal((await bridge.owner()).toLowerCase(),OWNER);
 const oldSlots=await Promise.all(Array.from({length:40},(_,i)=>p.getStorageAt(cfg.bridge,i)));
 const oldPending=await bridge.pendingDepositCount(),oldProved=await bridge.provedDepositCount();
 const indices=Array.from({length:Math.min(8,oldPending.toNumber())},(_,i)=>oldPending.toNumber()-i-1);
 const leaves=await Promise.all(indices.map(i=>bridge.depositLeafHashes(i)));
 const oldBalance=await p.getBalance(cfg.bridge);
 await p.send('anvil_setBlockTimestampInterval',[0]);
 await p.send('anvil_setBalance',[OWNER,ethers.utils.hexValue(ethers.utils.parseEther('1000'))]);
 await p.send('anvil_impersonateAccount',[OWNER]);
 const signer=p.getSigner(OWNER), fees={gasPrice:ethers.BigNumber.from('1000000000')};
 async function mined(tx) {
  for(let i=0;i<100;i++) {
   const r=await p.send('eth_getTransactionReceipt',[tx.hash]);
   if(r){if(parseInt(r.status,16)!==1){let trace={};try{trace=await p.send('debug_traceTransaction',[tx.hash,{tracer:'callTracer'}]);}catch{}throw Error(JSON.stringify({local_failed_tx:tx.hash,to:tx.to,selector:tx.data?.slice(0,10),gas_used:r.gasUsed,trace_error:trace.error,output:trace.output}));}return {...r,gasUsed:ethers.BigNumber.from(r.gasUsed)};}
   await new Promise(resolve=>setTimeout(resolve,50));
  }
  throw Error('Local transaction receipt missing');
 }
 async function deploy(a) {const c=await new ethers.ContractFactory(a.abi,a.bytecode,signer).deploy({...fees,gasLimit:10000000});await mined(c.deployTransaction);assert.equal(sha(await p.getCode(c.address)),sha(a.deployedBytecode));return c;}
 async function rejected(to,data,signature,from=OWNER) {
  let seen=false;
  try{await p.send('eth_call',[{to,from,data,gas:'0x7a120'},'latest']);}
  catch(e){let current=e;for(let i=0;current&&i<4;i++,current=current.error){if(typeof current.data==='string' && current.data.slice(0,10)===ethers.utils.id(signature).slice(0,10))seen=true;}}
  assert(seen,`Expected ${signature}`);
 }
 // ACL is an additive implementation upgrade, retaining namespaced roles/owner.
 const aclAddress=plan.contracts.PsyACLManager,aclArtifact=artifactAt('PsyACLManager');
 const acl=new ethers.Contract(aclAddress,aclArtifact.abi,signer);
 const aclAdminAddress=addr(await p.getStorageAt(aclAddress,ADMIN));
 const aclAdmin=new ethers.Contract(aclAdminAddress,adminAbi,signer);
 assert.equal((await aclAdmin.owner()).toLowerCase(),OWNER);
 const roles=await Promise.all(['DEFAULT_ADMIN_ROLE','BRIDGE_ADMIN_ROLE','ROUTER_ADMIN_ROLE','STATE_MANAGER_ADMIN_ROLE','PROPOSER_ROLE'].map(n=>acl[n]()));
 const roleState=await Promise.all(roles.map(r=>acl.hasRole(r,OWNER)));
 const oldAclImpl=addr(await p.getStorageAt(aclAddress,IMPL));
 const nextAcl=await deploy(aclArtifact);await mined(await aclAdmin.upgrade(aclAddress,nextAcl.address,{...fees,gasLimit:500000}));
 for(let i=0;i<roles.length;i++)assert.equal(await acl.hasRole(roles[i],OWNER),roleState[i]);
 await mined(await acl.grantRole(await acl.GUARDIAN_ROLE(),OWNER,{...fees,gasLimit:300000}));
 assert(await acl.isGuardian(OWNER));
 const candidate=await deploy(artifact);
 const initialize=bridge.interface.encodeFunctionData('initializeFlowLimits',[plan.tokens,plan.configs]);
 const upgrade=await mined(await admin.connect(signer).upgradeAndCall(cfg.bridge,candidate.address,initialize,{...fees,gasLimit:2000000}));
 for(let i=0;i<40;i++)assert.equal(await p.getStorageAt(cfg.bridge,i),oldSlots[i]);
 for(let i=0;i<leaves.length;i++)assert.equal(await bridge.depositLeafHashes(indices[i]),leaves[i]);
 assert((await p.getBalance(cfg.bridge)).eq(oldBalance));
 assert.equal((await bridge.getRevision()).toNumber(),3);
 const bucket=await bridge.getMaterializedDepositBucket(plan.tokens[1]);assert(bucket.available.eq('40000000000'));
 const token=new ethers.Contract(plan.tokens[1],['function owner() view returns(address)','function mint(address,uint256)','function approve(address,uint256)','function balanceOf(address) view returns(uint256)'],p);
 const mintOwner=await token.owner();await p.send('anvil_impersonateAccount',[mintOwner]);await p.send('anvil_setBalance',[mintOwner,ethers.utils.hexValue(ethers.utils.parseEther('100'))]);
 await mined(await token.connect(p.getSigner(mintOwner)).mint(OWNER,'100000000000',{...fees,gasLimit:300000}));
 await mined(await token.connect(signer).approve(plan.contracts.ERC20Gateway,ethers.constants.MaxUint256,{...fees,gasLimit:300000}));
 const router=new ethers.Contract(plan.contracts.Router,['function deposit(address,uint256,bytes32,bytes32) payable'],signer);
 const shield=ethers.utils.hexZeroPad('0x1234',32),note=ethers.utils.hexZeroPad('0x5678',32);
 await rejected(router.address,router.interface.encodeFunctionData('deposit',[token.address,999999,shield,note]),'DepositBelowMinimum(address,uint256,uint256)');
 await rejected(router.address,router.interface.encodeFunctionData('deposit',[token.address,'40000000001',shield,note]),'DepositRateLimited(address,uint256,uint64)');
 for(let i=0;i<4;i++)await mined(await router.deposit(token.address,'10000000000',shield,note,{...fees,gasLimit:500000}));
 assert((await bridge.getMaterializedDepositBucket(token.address)).available.isZero());
 const balanceBefore=await token.balanceOf(OWNER);
 await rejected(router.address,router.interface.encodeFunctionData('deposit',[token.address,'10000000000',shield,note]),'DepositRateLimited(address,uint256,uint64)');
 assert((await token.balanceOf(OWNER)).eq(balanceBefore));
 // Fractional integer refill: six seconds is 4 raw units short of 10000.
 const depletedAt=(await p.getBlock('latest')).timestamp;
 await p.send('evm_setNextBlockTimestamp',[depletedAt+6]);await p.send('evm_mine',[]);
 assert((await bridge.getMaterializedDepositBucket(token.address)).available.eq('9999999996'));
 await p.send('evm_setNextBlockTimestamp',[depletedAt+7]);await p.send('evm_mine',[]);
 await mined(await router.deposit(token.address,'10000000000',shield,note,{...fees,gasLimit:500000}));
 // Lifecycle-only withdrawal check: explicitly mock cryptographic verification
 // on this LOCAL fork, then restore the exact verifier before real proof replay.
 const originalWithdrawalVerifier=await bridge.withdrawalClaimVerifier();
 const mock=await deploy(artifactAt('MockGnarkVerifier'));
 await mined(await bridge.connect(signer).setWithdrawalClaimVerifier(mock.address,{...fees,gasLimit:300000}));
 const sm=new ethers.Contract(plan.contracts.StateManager,['function withdrawalSubtreeRoot() view returns(bytes32)','function BRIDGE_USER_ID() view returns(uint64)'],p);
 const nonce=ethers.utils.keccak256(ethers.utils.toUtf8Bytes('local-governance-'+cfg.chainId));
 const slots=Array(1088).fill(0);slots[0]=123;
 slots.splice(1,8,...split(ethers.utils.hexZeroPad(OWNER,32)));slots.splice(9,8,...split(ethers.utils.hexZeroPad(token.address,32)));
 slots.splice(17,8,...split(ethers.utils.hexZeroPad(ethers.utils.hexlify(17000000),32)));slots.splice(25,8,...split(nonce));slots[33]=plan.chainIndex;
 const commitment=ethers.utils.keccak256(ethers.utils.hexConcat(slots.map(x=>ethers.utils.hexZeroPad(ethers.utils.hexlify(x),4))));
 const inputs=[...split(await sm.withdrawalSubtreeRoot()),1,(await sm.BRIDGE_USER_ID()).toNumber(),...split(commitment)];
 const beforePayment=await token.balanceOf(OWNER);
 await mined(await bridge.connect(signer).batchClaimWithdrawal(Array(8).fill(0),inputs,slots,{...fees,gasLimit:6000000}));
 assert(await bridge.claimedNullifiers(nonce));assert((await bridge.pendingWithdrawals(nonce)).amount.eq(17000000));assert((await token.balanceOf(OWNER)).eq(beforePayment));
 const pin=(await p.getBlock('latest')).hash;
 const occupied=await p.send('eth_call',[{to:cfg.bridge,data:bridge.interface.encodeFunctionData('claimedNullifiers',[nonce])},{blockHash:pin,requireCanonical:true}]);
 assert(bridge.interface.decodeFunctionResult('claimedNullifiers',occupied)[0]);
 // Rolling back does not clear the registered nonce or restore old balances.
 await mined(await admin.connect(signer).upgrade(cfg.bridge,oldImpl,{...fees,gasLimit:300000}));
 assert(await bridge.claimedNullifiers(nonce));
 await mined(await admin.connect(signer).upgrade(cfg.bridge,candidate.address,{...fees,gasLimit:300000}));
 assert((await bridge.pendingWithdrawals(nonce)).amount.eq(17000000));
 const payment=await mined(await bridge.connect(signer).claimPendingWithdrawal(nonce,{...fees,gasLimit:500000}));
 assert((await bridge.pendingWithdrawals(nonce)).amount.isZero());assert((await token.balanceOf(OWNER)).sub(beforePayment).eq(17000000));
 await rejected(cfg.bridge,bridge.interface.encodeFunctionData('claimPendingWithdrawal',[nonce]),'PendingWithdrawalNotFound(bytes32)');
 await mined(await bridge.connect(signer).setWithdrawalClaimVerifier(originalWithdrawalVerifier,{...fees,gasLimit:300000}));
 assert.equal((await bridge.withdrawalClaimVerifier()).toLowerCase(),originalWithdrawalVerifier.toLowerCase());
 // The following historical packed proofs use the unchanged REAL verifier.
 const replays=[];
 for(const job of cfg.replay?.jobs??[]) {
  const snapshot=await p.send('evm_snapshot',[]);
  for(const [slot,value] of Object.entries(cfg.replay.slots)){assert(BigInt(slot)>=2n && BigInt(slot)<=35n);await p.send('anvil_setStorageAt',[cfg.bridge,slot,value]);}
  const receipt=await mined(await signer.sendTransaction({to:cfg.adapter,data:job.tx.data,...fees,gasLimit:15000000}));
  assert((await bridge.provedDepositCount()).eq(job.to));
  await p.send('evm_revert',[snapshot]);
  const badSnapshot=await p.send('evm_snapshot',[]);
  for(const [slot,value] of Object.entries(cfg.replay.slots))await p.send('anvil_setStorageAt',[cfg.bridge,slot,value]);
  const bad=ethers.utils.arrayify(job.tx.data);bad[68]^=1;
  let invalid=false;try{await p.send('eth_call',[{from:OWNER,to:cfg.adapter,data:ethers.utils.hexlify(bad),gas:'0xe4e1c0'},'latest']);}catch(e){invalid=JSON.stringify(e).includes(ethers.utils.id('InvalidDepositBatchProof()').slice(2,10));}
  assert(invalid);await p.send('evm_revert',[badSnapshot]);
  replays.push({calls:job.count,deposits:job.to-job.from,gas_used:receipt.gasUsed.toNumber(),invalid_proof_rejected:true});
 }
 const pendingAfter=await bridge.pendingDepositCount();assert(pendingAfter.eq(oldPending.add(5)));assert((await bridge.provedDepositCount()).eq(oldProved));
 await mined(await admin.connect(signer).upgrade(cfg.bridge,oldImpl,{...fees,gasLimit:300000}));
 assert((await bridge.pendingDepositCount()).eq(pendingAfter));assert((await bridge.provedDepositCount()).eq(oldProved));
 await mined(await aclAdmin.upgrade(aclAddress,oldAclImpl,{...fees,gasLimit:300000}));
 console.log(JSON.stringify({simulation_only:true,public_transactions_sent:false,chain_id:cfg.chainId,bridge:cfg.bridge,candidate_runtime_sha256:sha(artifact.deployedBytecode),
  legacy_slots_preserved:40,legacy_leaf_samples_preserved:leaves.length,guardian_acl_passed:true,burst_10000_pUSDT_accepted:4,min_and_capacity_rejections_passed:true,fractional_refill_passed:true,
  withdrawal_lifecycle:{cryptographic_verifier:'LOCAL_MOCK_ONLY',registered_before_paid:true,payment_gas:payment.gasUsed.toNumber(),exact_token_balance_increase:17000000,double_claim_rejected:true,canonical_hash_read_passed:true,pending_survives_rollback:true},
  historical_real_packed_replays:replays,rollback_preserved_progress:true,upgrade_gas:upgrade.gasUsed.toNumber(),passed:true}));
}
main().catch(e=>{console.error(e.stack);process.exitCode=1;});
