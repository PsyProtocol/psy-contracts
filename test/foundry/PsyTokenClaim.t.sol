// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PsyToken} from "../../src/PsyToken.sol";
import {PsyAddressesProvider} from "../../src/PsyAddressesProvider.sol";
import {PsyACLManager} from "../../src/PsyACLManager.sol";
import {StateManager} from "../../src/StateManager.sol";
import {MockGnarkVerifier} from "../fixtures/contracts/MockGnarkVerifier.sol";
import {TestERC1967Proxy} from "../fixtures/contracts/TestERC1967Proxy.sol";

/// @dev Unit stand-in only. It accepts one fixed 8-word reward-claim proof and the claim
/// message hash PsyToken computes from the claim-message ABI. Any other 256-byte
/// proof is rejected. This is not a Groth16 verifier and is not real-proof evidence.
contract RewardClaimMessageHashVerifier {
    uint256 internal constant REWARD_CLAIM_PROOF_WORD_0 = 1;
    uint256 internal constant REWARD_CLAIM_PROOF_WORD_1 = 2;
    uint256 internal constant REWARD_CLAIM_PROOF_WORD_2 = 3;
    uint256 internal constant REWARD_CLAIM_PROOF_WORD_3 = 4;
    uint256 internal constant REWARD_CLAIM_PROOF_WORD_4 = 5;
    uint256 internal constant REWARD_CLAIM_PROOF_WORD_5 = 6;
    uint256 internal constant REWARD_CLAIM_PROOF_WORD_6 = 7;
    uint256 internal constant REWARD_CLAIM_PROOF_WORD_7 = 8;

    bytes32 internal immutable claimMessageHash;

    constructor(bytes32 claimMessageHash_) {
        claimMessageHash = claimMessageHash_;
    }

    function verifyProof(uint256[8] calldata proof, uint256[2] calldata publicInputs) external view {
        if (
            proof[0] != REWARD_CLAIM_PROOF_WORD_0 || proof[1] != REWARD_CLAIM_PROOF_WORD_1 || proof[2] != REWARD_CLAIM_PROOF_WORD_2 || proof[3] != REWARD_CLAIM_PROOF_WORD_3 || proof[4] != REWARD_CLAIM_PROOF_WORD_4 || proof[5] != REWARD_CLAIM_PROOF_WORD_5
                || proof[6] != REWARD_CLAIM_PROOF_WORD_6 || proof[7] != REWARD_CLAIM_PROOF_WORD_7
        ) revert("unexpected unit test proof");
        bytes32 claimMessageHashActual = bytes32((uint256(publicInputs[0]) << 128) | uint256(publicInputs[1]));
        require(claimMessageHashActual == claimMessageHash, "unexpected claim digest");
    }
}

/// @dev State-manager stand-in with code whose provider view disagrees with the token.
contract MismatchedAddressesProvider {
    function addressesProvider() external view returns (address) {
        return address(this);
    }
}

contract PsyTokenClaimTest is Test {
    uint256 internal constant K = 64;
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 1e9;

    address internal owner = address(0xA11CE);
    address internal proposer = address(0xB0B);
    address internal holder = address(0xB10C);
    address internal recipient = address(0xBEEF);
    address internal other = address(0xC0DE);

    function _deployAddressesProvider() internal returns (PsyAddressesProvider provider) {
        PsyAddressesProvider impl = new PsyAddressesProvider();
        bytes memory initData = abi.encodeCall(PsyAddressesProvider.initialize, (owner));
        provider = PsyAddressesProvider(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _deployACL() internal returns (PsyACLManager acl) {
        PsyACLManager impl = new PsyACLManager();
        bytes memory initData = abi.encodeCall(PsyACLManager.initialize, (owner, owner, owner, owner, proposer));
        acl = PsyACLManager(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _deployStateManager(PsyAddressesProvider provider) internal returns (StateManager sm) {
        StateManager impl = new StateManager();
        bytes memory initData = abi.encodeCall(StateManager.initialize, (owner, address(provider), uint8(0)));
        sm = StateManager(address(new TestERC1967Proxy(address(impl), initData)));
    }

    function _rewardClaimProof() internal pure returns (bytes memory proof) {
        uint256[8] memory rewardClaimProofWords = [uint256(1), 2, 3, 4, 5, 6, 7, 8];
        return abi.encode(rewardClaimProofWords);
    }

    function _buildTopTreeProof(bytes32 leaf, uint8 index) internal pure returns (bytes32[9] memory p, bytes32 root) {
        p[0] = leaf;
        bytes32 cur = leaf;
        for (uint8 i = 0; i < 8; ++i) {
            bytes32 sib = keccak256(abi.encodePacked("sib", i));
            p[i + 1] = sib;
            if (((index >> i) & 1) == 0) {
                cur = keccak256(abi.encodePacked(cur, sib));
            } else {
                cur = keccak256(abi.encodePacked(sib, cur));
            }
        }
        root = cur;
    }

    function _checkpointRoots(bytes32 first, bytes32 last) internal pure returns (bytes32[2] memory checkpointRoots) {
        checkpointRoots[0] = first;
        checkpointRoots[1] = last;
    }

    function _stateManagerContractState(
        uint64 checkpointId,
        uint256 checkpointRoot,
        uint256 depositTreeRoot,
        uint256 withdrawalTreeRoot,
        uint256 withdrawalRoot
    ) internal pure returns (StateManager.StateManagerContractState memory state_) {
        state_ = StateManager.StateManagerContractState({
            lastFinalizedCheckpointId: checkpointId,
            lastVerifiedCheckpointRoot: bytes32(checkpointRoot),
            lastVerifiedDepositTreeRoot: bytes32(depositTreeRoot),
            lastVerifiedWithdrawalTreeRoot: bytes32(withdrawalTreeRoot),
            withdrawalSubtreeRoot: bytes32(withdrawalRoot)
        });
    }

    function _deriveClaimMessageHash(
        PsyToken token,
        address stateManager,
        uint32 userId,
        address claimRecipient,
        bytes32 checkpointRoot,
        uint32[] memory checkpointIds,
        uint256 totalAmount
    ) internal pure returns (bytes32) {
        uint32[K] memory paddedIds;
        for (uint256 i; i < checkpointIds.length; ++i) {
            paddedIds[i] = checkpointIds[i];
        }
        return keccak256(
            abi.encode(
                keccak256("PsyReward/TokenCheckpointClaim/1"),
                address(token),
                stateManager,
                uint256(userId),
                claimRecipient,
                checkpointRoot,
                uint256(checkpointIds.length),
                uint256(totalAmount),
                paddedIds
            )
        );
    }

    function _ids(uint32 a) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](1);
        ids[0] = a;
    }

    function _ids(uint32 a, uint32 b) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _buildCheckpointIds(uint32 start, uint256 count) internal pure returns (uint32[] memory ids) {
        ids = new uint32[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = start + uint32(i);
        }
    }

    function _setRewardClaimVerifier(PsyAddressesProvider provider, StateManager sm, bytes32 claimMessageHash)
        internal
        returns (RewardClaimMessageHashVerifier verifier)
    {
        verifier = new RewardClaimMessageHashVerifier(claimMessageHash);
        vm.startPrank(owner);
        provider.setAddress(provider.ACL_MANAGER_ID(), address(_deployACL()));
        provider.setAddress(provider.ZK_VERIFIER_ID(), address(new MockGnarkVerifier()));
        provider.setAddress(provider.STATE_MANAGER_ID(), address(sm));
        provider.setAddress(provider.REWARD_CLAIM_VERIFIER_ID(), address(verifier));
        vm.stopPrank();
    }

    function _setProviderAddress(PsyAddressesProvider provider, bytes32 id, address value) internal {
        vm.prank(owner);
        provider.setAddress(id, value);
    }


    function _finalizeRoot(StateManager sm, bytes32 checkpointRoot)
        internal
        returns (bytes32 depositRoot, bytes32 withdrawalRoot, bytes32 withdrawalLeaf)
    {
        bytes32 depositLeaf = sm.withdrawalSubtreeRoot();
        bytes32[9] memory depositProof;
        (depositProof, depositRoot) = _buildTopTreeProof(depositLeaf, 0);
        bytes32[9] memory withdrawalProof;
        (withdrawalProof, withdrawalRoot) = _buildTopTreeProof(bytes32(uint256(0x1234)), 0);
        withdrawalLeaf = withdrawalProof[0];
        vm.prank(proposer);
        sm.finalize(
            _rewardClaimProof(),
            depositRoot,
            _checkpointRoots(bytes32(uint256(1)), checkpointRoot),
            withdrawalRoot,
            0,
            1,
            depositProof,
            withdrawalProof
        );
    }

    function _buildRecognizedRewardRoot(
        uint32 userId,
        uint32[] memory checkpointIds,
        uint256 totalAmount
    )
        internal
        returns (
            PsyToken token,
            StateManager sm,
            RewardClaimMessageHashVerifier verifier,
            bytes32 checkpointRoot,
            bytes32 depositRoot,
            bytes32 withdrawalRoot,
            bytes32 withdrawalLeaf
        )
    {
        PsyAddressesProvider provider = _deployAddressesProvider();
        sm = _deployStateManager(provider);
        token = new PsyToken(holder, INITIAL_SUPPLY, address(provider));
        checkpointRoot = bytes32(uint256(2));
        verifier = _setRewardClaimVerifier(
            provider, sm, _deriveClaimMessageHash(token, address(sm), userId, recipient, checkpointRoot, checkpointIds, totalAmount)
        );
        (depositRoot, withdrawalRoot, withdrawalLeaf) = _finalizeRoot(sm, checkpointRoot);
    }

    function _assertUnclaimed(PsyToken token, uint32 userId, uint32[] memory checkpointIds, uint256 supply, uint256 balance)
        internal
        view
    {
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(recipient), balance);
        for (uint256 i; i < checkpointIds.length; ++i) {
            assertFalse(token.claimed(userId, checkpointIds[i]));
        }
    }

    function testConstructorRejectsProviderWithoutCode() public {
        vm.expectRevert(PsyToken.ZeroAddress.selector);
        new PsyToken(holder, INITIAL_SUPPLY, address(0));
        vm.expectRevert(PsyToken.ZeroAddress.selector);
        new PsyToken(holder, INITIAL_SUPPLY, address(0xE0A));
    }

    function testStandardErc20AndOwnerMintUnchanged() public {
        PsyAddressesProvider provider = _deployAddressesProvider();
        PsyToken token = new PsyToken(holder, INITIAL_SUPPLY, address(provider));

        assertEq(token.name(), "Psy Token");
        assertEq(token.symbol(), "PSY");
        assertEq(token.decimals(), 9);
        assertEq(token.owner(), holder);
        assertEq(token.addressesProvider(), address(provider));
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(holder), INITIAL_SUPPLY);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        token.mint(other, 1);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(other), 0);

        vm.prank(holder);
        token.mint(other, 42);
        assertEq(token.balanceOf(other), 42);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + 42);

        vm.prank(other);
        assertTrue(token.transfer(holder, 17));
        assertEq(token.balanceOf(other), 25);
        assertEq(token.balanceOf(holder), INITIAL_SUPPLY + 17);
        assertEq(token.totalSupply(), INITIAL_SUPPLY + 42);
    }

    function testRejectedChainBeforeExternalCallOrStateWrites() public {
        (PsyToken token, StateManager sm,,,,,) = _buildRecognizedRewardRoot(11, _ids(0, 3), 23);
        uint32[] memory ids = _ids(0, 3);
        uint256 supply = token.totalSupply();

        vm.chainId(8453);
        vm.expectRevert(PsyToken.WrongChain.selector);
        token.claimReward(_rewardClaimProof(), bytes32(uint256(2)), 11, recipient, ids, 23);

        // The guard is first: this verifier rejects every proof, including the pinned words.
        RewardClaimMessageHashVerifier rejecting = new RewardClaimMessageHashVerifier(bytes32(uint256(1)));
        PsyAddressesProvider provider = PsyAddressesProvider(token.addressesProvider());
        bytes32 rewardClaimVerifierId = provider.REWARD_CLAIM_VERIFIER_ID();
        _setProviderAddress(provider, rewardClaimVerifierId, address(rejecting));
        vm.chainId(5);
        vm.expectRevert(PsyToken.WrongChain.selector);
        token.claimReward(_rewardClaimProof(), bytes32(uint256(2)), 11, recipient, ids, 23);

        vm.chainId(1);
        vm.expectRevert(PsyToken.InvalidProof.selector);
        token.claimReward(_rewardClaimProof(), bytes32(uint256(2)), 11, recipient, ids, 23);

        _assertUnclaimed(token, 11, ids, supply, 0);
        assertEq(sm.rewardRootEpoch(), 1);
        assertEq(sm.rewardRootEpochs(bytes32(uint256(2))), 1);
        assertEq(token.balanceOf(holder), INITIAL_SUPPLY);
    }

    function testAllowedChainsMintExactRecipientAndSupply() public {
        uint256[3] memory allowedChains = [uint256(1), 31337, 11155111];
        uint256[3] memory amounts = [uint256(23), 41, 59];
        for (uint256 i; i < allowedChains.length; ++i) {
            uint32[] memory ids = new uint32[](3);
            ids[0] = 0;
            ids[1] = 3;
            ids[2] = 9;
            (PsyToken token,,, bytes32 checkpointRoot,,,) = _buildRecognizedRewardRoot(7, ids, amounts[i]);
            uint256 supply = token.totalSupply();
            uint256 recipientBefore = token.balanceOf(recipient);
            uint256 holderBefore = token.balanceOf(holder);

            vm.expectEmit(true, true, true, true, address(token));
            emit PsyToken.RewardClaimed(7, recipient, checkpointRoot, ids, amounts[i]);
            vm.chainId(allowedChains[i]);
            token.claimReward(_rewardClaimProof(), checkpointRoot, 7, recipient, ids, amounts[i]);

            assertEq(token.balanceOf(recipient), recipientBefore + amounts[i]);
            assertEq(token.totalSupply(), supply + amounts[i]);
            assertEq(token.balanceOf(holder), holderBefore);
            assertTrue(token.claimed(7, 0));
            assertTrue(token.claimed(7, 3));
            assertTrue(token.claimed(7, 9));
            assertFalse(token.claimed(7, 1));
        }
    }

    function testWrongUserRecipientListAmountOrRootRejects() public {
        uint32[] memory ids = _ids(9);
        (PsyToken token,,, bytes32 checkpointRoot,,,) = _buildRecognizedRewardRoot(11, ids, 77);
        uint256 supply = token.totalSupply();

        vm.chainId(1);
        vm.expectRevert(PsyToken.InvalidProof.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 12, recipient, ids, 77);
        vm.expectRevert(PsyToken.InvalidProof.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, other, ids, 77);
        vm.expectRevert(PsyToken.InvalidProof.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, _ids(10), 77);
        vm.expectRevert(PsyToken.InvalidProof.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, ids, 76);
        vm.expectRevert(PsyToken.UnrecognizedRewardRoot.selector);
        token.claimReward(_rewardClaimProof(), bytes32(uint256(3)), 11, recipient, ids, 77);
        vm.expectRevert(PsyToken.InvalidProof.selector);
        token.claimReward(abi.encode(uint256(9), 8, 7, 6, 5, 4, 3, 2), checkpointRoot, 11, recipient, ids, 77);
        vm.expectRevert(PsyToken.InvalidProof.selector);
        token.claimReward(hex"01", checkpointRoot, 11, recipient, ids, 77);

        _assertUnclaimed(token, 11, ids, supply, 0);
        assertFalse(token.claimed(12, 9));
    }

    function testReplayOfAnyPairRevertsEntireClaim() public {
        uint32[] memory first = _ids(4, 11);
        (PsyToken token,,, bytes32 checkpointRoot,,,) = _buildRecognizedRewardRoot(1000, first, 20);

        vm.chainId(1);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 1000, recipient, first, 20);
        uint256 supply = token.totalSupply();
        uint256 balance = token.balanceOf(recipient);

        uint32[] memory overlap = _ids(11, 12);
        vm.expectRevert(PsyToken.AlreadyClaimed.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 1000, recipient, overlap, 20);
        vm.expectRevert(PsyToken.AlreadyClaimed.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 1000, recipient, first, 20);

        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(recipient), balance);
        assertTrue(token.claimed(1000, 4));
        assertTrue(token.claimed(1000, 11));
        assertFalse(token.claimed(1000, 12));
    }

    function testOlderUnpaidHoleRemainsClaimable() public {
        uint32[] memory later = _ids(11);
        (PsyToken token, StateManager sm,, bytes32 checkpointRoot,,,) = _buildRecognizedRewardRoot(1000, later, 5);

        vm.chainId(1);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 1000, recipient, later, 5);
        assertTrue(token.claimed(1000, 11));
        assertFalse(token.claimed(1000, 4));

        uint32[] memory hole = _ids(4);
        RewardClaimMessageHashVerifier holeVerifier =
            new RewardClaimMessageHashVerifier(_deriveClaimMessageHash(token, address(sm), 1000, recipient, checkpointRoot, hole, 7));
        PsyAddressesProvider provider = PsyAddressesProvider(token.addressesProvider());
        bytes32 rewardClaimVerifierId = provider.REWARD_CLAIM_VERIFIER_ID();
        _setProviderAddress(provider, rewardClaimVerifierId, address(holeVerifier));

        uint256 supply = token.totalSupply();
        token.claimReward(_rewardClaimProof(), checkpointRoot, 1000, recipient, hole, 7);
        assertTrue(token.claimed(1000, 4));
        assertTrue(token.claimed(1000, 11));
        assertEq(token.balanceOf(recipient), 12);
        assertEq(token.totalSupply(), supply + 7);
    }

    function testHistoricalRootRecognizedUntilEpochRollback() public {
        uint32[] memory ids = _ids(9);
        (
            PsyToken token,
            StateManager sm,
            ,
            bytes32 checkpointRoot,
            bytes32 depositRoot,
            bytes32 withdrawalRoot,
            bytes32 withdrawalLeaf
        ) = _buildRecognizedRewardRoot(11, ids, 77);

        bytes32 historical = bytes32(uint256(8));
        bytes32[9] memory continuedDeposit;
        bytes32 continuedDepositRoot;
        (continuedDeposit, continuedDepositRoot) = _buildTopTreeProof(withdrawalLeaf, 0);
        bytes32[9] memory continuedWithdrawal;
        bytes32 continuedWithdrawalRoot;
        (continuedWithdrawal, continuedWithdrawalRoot) = _buildTopTreeProof(bytes32(uint256(0x5678)), 0);
        vm.prank(proposer);
        sm.finalize(
            _rewardClaimProof(),
            continuedDepositRoot,
            _checkpointRoots(checkpointRoot, historical),
            continuedWithdrawalRoot,
            0,
            2,
            continuedDeposit,
            continuedWithdrawal
        );
        assertEq(sm.rewardRootEpoch(), 1);
        assertEq(sm.rewardRootEpochs(checkpointRoot), 1);
        assertEq(sm.rewardRootEpochs(historical), 1);

        vm.chainId(1);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, ids, 77);
        assertEq(token.balanceOf(recipient), 77);
        assertTrue(token.claimed(11, 9));
        uint256 supply = token.totalSupply();

        vm.prank(owner);
        sm.forceSetState(
            _stateManagerContractState(
                2,
                uint256(historical),
                uint256(continuedDepositRoot),
                uint256(continuedWithdrawalRoot),
                uint256(continuedWithdrawal[0])
            ),
            _stateManagerContractState(0, 0x21, 0x22, 0x23, 0x24)
        );
        assertEq(sm.rewardRootEpoch(), 2);
        assertEq(sm.rewardRootEpochs(checkpointRoot), 1);
        assertTrue(token.claimed(11, 9));

        vm.expectRevert(PsyToken.UnrecognizedRewardRoot.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, _ids(10), 1);
        vm.expectRevert(PsyToken.UnrecognizedRewardRoot.selector);
        token.claimReward(_rewardClaimProof(), historical, 11, recipient, _ids(10), 1);

        vm.recordLogs();
        vm.prank(owner);
        sm.forceSetState(
            _stateManagerContractState(0, 0x21, 0x22, 0x23, 0x24),
            _stateManagerContractState(0, 0x21, 0x22, 0x23, 0x24)
        );
        assertEq(sm.rewardRootEpoch(), 2);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(recipient), 77);
        assertTrue(token.claimed(11, 9));
        assertFalse(token.claimed(11, 10));
    }

    function testInvalidClaimShapeRevertsBeforeVerification() public {
        uint32[] memory ids = _buildCheckpointIds(1, K);
        (PsyToken token,,, bytes32 checkpointRoot,,,) = _buildRecognizedRewardRoot(11, ids, type(uint128).max);

        vm.chainId(1);
        vm.expectRevert(PsyToken.InvalidRewardClaim.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, address(0), ids, type(uint128).max);
        vm.expectRevert(PsyToken.InvalidRewardClaim.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, new uint32[](0), 1);
        vm.expectRevert(PsyToken.InvalidRewardClaim.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, ids, 0);
        vm.expectRevert(PsyToken.InvalidRewardClaim.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, ids, uint256(type(uint128).max) + 1);
        vm.expectRevert(PsyToken.InvalidRewardClaim.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, _buildCheckpointIds(1, K + 1), 1);

        uint32[] memory unordered = _ids(3, 3);
        vm.expectRevert(PsyToken.InvalidRewardClaim.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, unordered, 1);
        unordered[1] = 2;
        vm.expectRevert(PsyToken.InvalidRewardClaim.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, unordered, 1);

        assertEq(token.balanceOf(recipient), 0);
        assertFalse(token.claimed(11, 1));
        assertFalse(token.claimed(11, 3));
    }

    function testBoundaryListMintsAndUsersStaySeparate() public {
        uint32[] memory full = _buildCheckpointIds(0, K);
        (PsyToken token, StateManager sm,, bytes32 checkpointRoot,,,) = _buildRecognizedRewardRoot(1000, full, 64);

        vm.chainId(1);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 1000, recipient, full, 64);
        assertEq(token.balanceOf(recipient), 64);
        assertTrue(token.claimed(1000, 0));
        assertTrue(token.claimed(1000, 63));
        assertFalse(token.claimed(1001, 0));

        uint32[] memory otherUser = _ids(0);
        RewardClaimMessageHashVerifier otherVerifier = new RewardClaimMessageHashVerifier(
            _deriveClaimMessageHash(token, address(sm), 1001, other, checkpointRoot, otherUser, 9)
        );
        PsyAddressesProvider provider = PsyAddressesProvider(token.addressesProvider());
        bytes32 rewardClaimVerifierId = provider.REWARD_CLAIM_VERIFIER_ID();
        _setProviderAddress(provider, rewardClaimVerifierId, address(otherVerifier));
        token.claimReward(_rewardClaimProof(), checkpointRoot, 1001, other, otherUser, 9);
        assertEq(token.balanceOf(other), 9);
        assertTrue(token.claimed(1001, 0));
        assertTrue(token.claimed(1000, 0));
    }

    function testVerifierOrRootFailureWritesNothing() public {
        uint32[] memory ids = _ids(9);
        (PsyToken token, StateManager sm,, bytes32 checkpointRoot,,,) = _buildRecognizedRewardRoot(11, ids, 77);
        uint256 supply = token.totalSupply();

        vm.chainId(1);
        vm.expectRevert(PsyToken.InvalidProof.selector);
        token.claimReward(abi.encode(uint256(9), 8, 7, 6, 5, 4, 3, 2), checkpointRoot, 11, recipient, ids, 77);

        PsyAddressesProvider provider = PsyAddressesProvider(token.addressesProvider());
        bytes32 stateManagerAddressId = provider.STATE_MANAGER_ID();
        bytes32 rewardClaimVerifierId = provider.REWARD_CLAIM_VERIFIER_ID();
        _setProviderAddress(provider, stateManagerAddressId, address(new MismatchedAddressesProvider()));
        vm.expectRevert(PsyToken.ProviderMismatch.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, ids, 77);

        _setProviderAddress(provider, stateManagerAddressId, holder);
        vm.expectRevert(PsyToken.StateManagerNotSet.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, ids, 77);

        _setProviderAddress(provider, stateManagerAddressId, address(sm));
        _setProviderAddress(provider, rewardClaimVerifierId, holder);
        vm.expectRevert(PsyToken.VerifierNotSet.selector);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 11, recipient, ids, 77);

        _assertUnclaimed(token, 11, ids, supply, 0);
    }

    function testHandBuiltMessageBytesMatchDigestHalves() public {
        uint32[] memory ids = new uint32[](3);
        ids[0] = 0;
        ids[1] = 3;
        ids[2] = 9;
        (PsyToken token, StateManager sm,, bytes32 checkpointRoot,,,) = _buildRecognizedRewardRoot(7, ids, 23);
        bytes32 domain = keccak256("PsyReward/TokenCheckpointClaim/1");

        bytes memory claimMessage = new bytes(2304);
        assertEq(claimMessage.length, 32 * (8 + K));
        _writeClaimMessageWord(claimMessage, 0, uint256(domain));
        _writeClaimMessageWord(claimMessage, 1, uint256(uint160(address(token))));
        _writeClaimMessageWord(claimMessage, 2, uint256(uint160(address(sm))));
        _writeClaimMessageWord(claimMessage, 3, 7);
        _writeClaimMessageWord(claimMessage, 4, uint256(uint160(recipient)));
        _writeClaimMessageWord(claimMessage, 5, uint256(checkpointRoot));
        _writeClaimMessageWord(claimMessage, 6, ids.length);
        _writeClaimMessageWord(claimMessage, 7, 23);
        _writeClaimMessageWord(claimMessage, 8, ids[0]);
        _writeClaimMessageWord(claimMessage, 9, ids[1]);
        _writeClaimMessageWord(claimMessage, 10, ids[2]);
        for (uint256 slot = 11; slot < 8 + K; ++slot) {
            assertEq(_readClaimMessageWord(claimMessage, slot), 0);
        }

        assertEq(_readClaimMessageWord(claimMessage, 0), uint256(domain));
        assertEq(_readClaimMessageWord(claimMessage, 8), 0);
        assertEq(_readClaimMessageWord(claimMessage, 9), 3);
        assertEq(_readClaimMessageWord(claimMessage, 10), 9);
        assertEq(_readClaimMessageWord(claimMessage, 71), 0);

        bytes32 digest = keccak256(claimMessage);
        bytes32 claimMessageHash = _deriveClaimMessageHash(token, address(sm), 7, recipient, checkpointRoot, ids, 23);
        assertEq(digest, claimMessageHash);

        bytes16 claimMessageHashHigh;
        bytes16 claimMessageHashLow;
        assembly {
            claimMessageHashHigh := claimMessageHash
            claimMessageHashLow := shl(128, claimMessageHash)
        }
        uint256 claimMessageHashHighU128 = uint256(uint128(claimMessageHashHigh));
        uint256 claimMessageHashLowU128 = uint256(uint128(claimMessageHashLow));
        assertEq(bytes32((claimMessageHashHighU128 << 128) | claimMessageHashLowU128), claimMessageHash);

        RewardClaimMessageHashVerifier handVerifier = new RewardClaimMessageHashVerifier(claimMessageHash);
        PsyAddressesProvider provider = PsyAddressesProvider(token.addressesProvider());
        bytes32 rewardClaimVerifierId = provider.REWARD_CLAIM_VERIFIER_ID();
        _setProviderAddress(provider, rewardClaimVerifierId, address(handVerifier));

        vm.chainId(1);
        token.claimReward(_rewardClaimProof(), checkpointRoot, 7, recipient, ids, 23);
        assertEq(token.balanceOf(recipient), 23);
        assertTrue(token.claimed(7, 0));
        assertTrue(token.claimed(7, 3));
        assertTrue(token.claimed(7, 9));
    }

    function _writeClaimMessageWord(bytes memory claimMessage, uint256 word, uint256 value) internal pure {
        assembly {
            mstore(add(add(claimMessage, 0x20), mul(word, 32)), value)
        }
    }

    function _readClaimMessageWord(bytes memory claimMessage, uint256 word) internal pure returns (uint256 value) {
        assembly {
            value := mload(add(add(claimMessage, 0x20), mul(word, 32)))
        }
    }
}
