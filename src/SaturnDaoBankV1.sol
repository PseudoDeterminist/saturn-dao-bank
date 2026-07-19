// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Minimal single-contract Saturn DAO Bank v1 draft.
/// @dev This is a first implementation from the plain-English spec.
///      It intentionally avoids OpenZeppelin Governor, AccessControl, proxies,
///      arbitrary governance calls, and upgradeability.
contract SaturnDaoBankV1 {

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    address public constant ETC = address(0);

    // STRN has 4 decimals. 1,000,000.0000 STRN = 10,000,000,000 raw units.
    uint256 public constant STRN_STAKE = 10_000_000_000;

    uint64 public constant MIN_VOTING_PERIOD = 40;
    uint64 public constant MAX_VOTING_PERIOD = 100;

    uint64 public constant MIN_EXECUTION_DELAY = 0;
    uint64 public constant MAX_EXECUTION_DELAY = 100;

    uint64 public constant MIN_EXECUTION_EXPIRY = 10;
    uint64 public constant MAX_EXECUTION_EXPIRY = 100_000;

    uint64 public constant MIN_RESTAKE_DELAY = 0;
    uint64 public constant MAX_RESTAKE_DELAY = 100_000;

    uint64 public constant MIN_REMOVED_EXIT_WINDOW = 10;
    uint64 public constant MAX_REMOVED_EXIT_WINDOW = 100;

    // Practical v1 guard. Full-account recovery loops across the user's asset list.
    uint256 public constant MAX_RECOVERY_ASSETS = 50;

    // ---------------------------------------------------------------------
    // Immutable deployment values
    // ---------------------------------------------------------------------

    address public immutable STRN;
    address public immutable founder1;
    address public immutable founder2;
    address public immutable founder3;

    // ---------------------------------------------------------------------
    // Enums
    // ---------------------------------------------------------------------

    enum MemberStatus {
        None,
        Bank,
        Dao,
        RemovedExitOnly,
        RecoveredRetired
    }

    enum TokenStatus {
        NeverListed,
        Active,
        Delisted
    }

    enum VoteChoice {
        None,
        Yes,
        No,
        Abstain
    }

    enum ProposalStatus {
        None,
        Active,
        Executed,
        Cancelled,
        Expired
    }

    enum ProposalType {
        AdmitDaoMember,
        AdmitBankMember,
        RemoveMember,
        RecoverAccount,
        ListToken,
        DelistToken,
        RelistToken,
        TreasuryExternalTransfer,
        TreasuryInternalTransfer,
        SweptExternalTransfer,
        SweptInternalTransfer,
        ChangeVotingPeriod,
        ChangeExecutionDelay,
        ChangeExecutionExpiry,
        ChangeRestakeDelay,
        ChangeRemovedExitWindow
    }

    // ---------------------------------------------------------------------
    // Structs
    // ---------------------------------------------------------------------

    struct Member {
        MemberStatus status;
        bool staked;
        uint64 restakeReadyBlock;
        uint64 removedAtBlock;
    }

    struct Proposal {
        ProposalType pType;
        ProposalStatus status;
        address proposer;
        address account;
        address target;
        address token;
        uint256 amount;
        uint64 value;
        uint64 startBlock;
        uint64 endBlock;
        uint64 executeAfter;
        uint64 expiresAt;
        uint32 yesVotes;
        uint32 noVotes;
        uint32 abstainVotes;
        string memo;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    bool public governanceActive;
    uint256 public nextProposalId = 1;

    uint64 public votingPeriod = 100;
    uint64 public executionDelay = 10;
    uint64 public executionExpiry = 1_000;
    uint64 public restakeDelay = 500;
    uint64 public removedExitWindow = 50;

    mapping(address => Member) public members;
    mapping(address => TokenStatus) public tokenStatus;

    // user => token => balance. ETC is address(0).
    mapping(address => mapping(address => uint256)) public balanceOf;

    // DAO-owned accounting buckets.
    mapping(address => uint256) public treasuryBalance;
    mapping(address => uint256) public sweptBalance;

    // Total credited internal liabilities for each asset.
    mapping(address => uint256) public totalLiability;

    // Asset-list tracking is needed for full-account recovery.
    mapping(address => address[]) internal userAssets;
    mapping(address => mapping(address => bool)) internal hasUserAsset;

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => VoteChoice)) public voteOf;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error DuplicateFounder();
    error NotAdmitted();
    error NotDaoMember();
    error NotVotingMember();
    error GovernanceInactive();
    error BadToken();
    error BadAmount();
    error BadStatus();
    error AlreadyRegistered();
    error ProposalNotActive();
    error VotingClosed();
    error VotingOpen();
    error NotPassed();
    error ExecutionTooEarly();
    error ExecutionExpired();
    error SelfVoteBlocked();
    error RecoveryTargetInvalid();
    error RecoveryTooLarge();
    error TransferFailed();
    error ParamOutOfBounds();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event InternalTransfer(address indexed from, address indexed to, address indexed token, uint256 amount);

    event Stake(address indexed user, bool fromBank);
    event Unstake(address indexed user, bool toBank);

    event ProposalCreated(
        uint256 indexed proposalId,
        ProposalType indexed pType,
        address indexed proposer,
        address account,
        address target,
        address token,
        uint256 amount,
        uint256 value,
        uint64 endBlock,
        string memo
    );

    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteChoice choice);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalExpired(uint256 indexed proposalId);
    event RecoveryCancelled(uint256 indexed proposalId, address indexed oldAccount);

    event DaoMemberAdmitted(address indexed account);
    event BankMemberAdmitted(address indexed account);
    event MemberRemoved(address indexed account);

    event TokenListed(address indexed token);
    event TokenDelisted(address indexed token);
    event TokenRelisted(address indexed token);
    event TokenSwept(address indexed token, uint256 amount);

    event TreasuryTransfer(address indexed token, address indexed to, uint256 amount, bool internalTransfer);
    event SweptFundsTransfer(address indexed token, address indexed to, uint256 amount, bool internalTransfer);

    event ParameterChanged(ProposalType indexed parameter, uint256 value);
    event BootstrapCompleted(uint256 blockNumber);

    // ---------------------------------------------------------------------
    // Constructor / receive
    // ---------------------------------------------------------------------

    constructor(address strn, address f1, address f2, address f3) {
        if (strn == address(0) || f1 == address(0) || f2 == address(0) || f3 == address(0)) {
            revert ZeroAddress();
        }
        if (f1 == f2 || f1 == f3 || f2 == f3) revert DuplicateFounder();

        STRN = strn;
        founder1 = f1;
        founder2 = f2;
        founder3 = f3;

        members[f1].status = MemberStatus.Dao;
        members[f2].status = MemberStatus.Dao;
        members[f3].status = MemberStatus.Dao;

        emit DaoMemberAdmitted(f1);
        emit DaoMemberAdmitted(f2);
        emit DaoMemberAdmitted(f3);
    }

    receive() external payable {
        revert TransferFailed();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isActiveUser(address user) public view returns (bool) {
        MemberStatus s = members[user].status;
        return s == MemberStatus.Bank || s == MemberStatus.Dao;
    }

    function isVotingMember(address user) public view returns (bool) {
        Member memory m = members[user];
        return governanceActive
            && m.status == MemberStatus.Dao
            && m.staked
            && block.number >= m.restakeReadyBlock;
    }

    function isActiveToken(address token) public view returns (bool) {
        return token == ETC || token == STRN || tokenStatus[token] == TokenStatus.Active;
    }

    function wasListed(address token) public view returns (bool) {
        return token == ETC || token == STRN || tokenStatus[token] != TokenStatus.NeverListed;
    }

    function getUserAssetCount(address user) external view returns (uint256) {
        return userAssets[user].length;
    }

    function getUserAsset(address user, uint256 index) external view returns (address) {
        return userAssets[user][index];
    }

    function hasPassed(uint256 proposalId) public view returns (bool) {
        Proposal storage p = proposals[proposalId];
        if (p.status != ProposalStatus.Active) return false;
        if (block.number <= p.endBlock) return false;

        uint256 yes = p.yesVotes;
        uint256 no = p.noVotes;
        uint256 yesNo = yes + no;

        if (yesNo == 0) return false;

        return yes * 3 >= yesNo * 2;
    }

    function canWithdraw(address user) public view returns (bool) {
        Member memory m = members[user];

        if (m.status == MemberStatus.Bank || m.status == MemberStatus.Dao) {
            return true;
        }

        if (m.status == MemberStatus.RemovedExitOnly) {
            return block.number <= uint256(m.removedAtBlock) + uint256(removedExitWindow);
        }

        return false;
    }

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyActiveUser() {
        if (!isActiveUser(msg.sender)) revert NotAdmitted();
        _;
    }

    modifier onlyVotingMember() {
        if (!isVotingMember(msg.sender)) revert NotVotingMember();
        _;
    }

    // ---------------------------------------------------------------------
    // Deposits / withdrawals / internal transfers
    // ---------------------------------------------------------------------

    function depositETC() external payable onlyActiveUser {
        if (msg.value == 0) revert BadAmount();

        _creditUser(msg.sender, ETC, msg.value);
        totalLiability[ETC] += msg.value;

        emit Deposit(msg.sender, ETC, msg.value);
    }

    function depositToken(address token, uint256 amount) external onlyActiveUser {
        if (token == ETC || !isActiveToken(token)) revert BadToken();
        if (amount == 0) revert BadAmount();

        uint256 beforeBal = IERC20Minimal(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 afterBal = IERC20Minimal(token).balanceOf(address(this));

        uint256 received = afterBal - beforeBal;
        if (received == 0) revert BadAmount();

        _creditUser(msg.sender, token, received);
        totalLiability[token] += received;

        emit Deposit(msg.sender, token, received);
    }

    function withdraw(address token, uint256 amount) external {
        if (!canWithdraw(msg.sender)) revert NotAdmitted();
        if (!wasListed(token)) revert BadToken();
        if (amount == 0) revert BadAmount();

        _debitUser(msg.sender, token, amount);
        totalLiability[token] -= amount;

        _sendAsset(token, msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    function internalTransfer(address token, address to, uint256 amount) external onlyActiveUser {
        if (!isActiveUser(to)) revert NotAdmitted();
        if (!isActiveToken(token)) revert BadToken();
        if (amount == 0) revert BadAmount();

        _debitUser(msg.sender, token, amount);
        _creditUser(to, token, amount);

        emit InternalTransfer(msg.sender, to, token, amount);
    }

    // ---------------------------------------------------------------------
    // Staking
    // ---------------------------------------------------------------------

    function stakeFromWallet() external {
        Member storage m = members[msg.sender];
        if (m.status != MemberStatus.Dao) revert NotDaoMember();
        if (m.staked) revert BadStatus();

        _safeTransferFrom(STRN, msg.sender, address(this), STRN_STAKE);

        m.staked = true;
        totalLiability[STRN] += STRN_STAKE;

        emit Stake(msg.sender, false);
        _tryActivateGovernance();
    }

    function stakeFromBank() external {
        Member storage m = members[msg.sender];
        if (m.status != MemberStatus.Dao) revert NotDaoMember();
        if (m.staked) revert BadStatus();

        _debitUser(msg.sender, STRN, STRN_STAKE);
        m.staked = true;

        emit Stake(msg.sender, true);
        _tryActivateGovernance();
    }

    function unstakeToBank() external {
        Member storage m = members[msg.sender];
        if (m.status != MemberStatus.Dao || !m.staked) revert BadStatus();

        m.staked = false;
        m.restakeReadyBlock = uint64(block.number) + restakeDelay;

        _creditUser(msg.sender, STRN, STRN_STAKE);

        emit Unstake(msg.sender, true);
    }

    function unstakeToWallet() external {
        Member storage m = members[msg.sender];
        if (m.status != MemberStatus.Dao || !m.staked) revert BadStatus();

        m.staked = false;
        m.restakeReadyBlock = uint64(block.number) + restakeDelay;
        totalLiability[STRN] -= STRN_STAKE;

        _safeTransfer(STRN, msg.sender, STRN_STAKE);

        emit Unstake(msg.sender, false);
    }

    // ---------------------------------------------------------------------
    // Sweeps
    // ---------------------------------------------------------------------

    function sweepToken(address token) external onlyVotingMember {
        if (token == ETC || !wasListed(token)) revert BadToken();

        uint256 actual = IERC20Minimal(token).balanceOf(address(this));
        uint256 liability = totalLiability[token];

        if (actual <= liability) revert BadAmount();

        uint256 excess = actual - liability;

        sweptBalance[token] += excess;
        totalLiability[token] += excess;

        emit TokenSwept(token, excess);
    }

    function sweepETC() external onlyVotingMember {
        uint256 actual = address(this).balance;
        uint256 liability = totalLiability[ETC];

        if (actual <= liability) revert BadAmount();

        uint256 excess = actual - liability;

        sweptBalance[ETC] += excess;
        totalLiability[ETC] += excess;

        emit TokenSwept(ETC, excess);
    }

    // ---------------------------------------------------------------------
    // Proposal creation
    // ---------------------------------------------------------------------

    function proposeMember(
        ProposalType pType,
        address account,
        string calldata memo
    ) external onlyVotingMember returns (uint256) {
        if (
            pType != ProposalType.AdmitDaoMember &&
            pType != ProposalType.AdmitBankMember &&
            pType != ProposalType.RemoveMember
        ) revert BadStatus();

        if (account == address(0)) revert ZeroAddress();

        return _createProposal(pType, account, address(0), address(0), 0, 0, memo);
    }

    function proposeRecovery(
        address oldAccount,
        address newAccount,
        string calldata memo
    ) external onlyVotingMember returns (uint256) {
        if (oldAccount == address(0) || newAccount == address(0)) revert ZeroAddress();
        return _createProposal(ProposalType.RecoverAccount, oldAccount, newAccount, address(0), 0, 0, memo);
    }

    function proposeToken(
        ProposalType pType,
        address token,
        string calldata memo
    ) external onlyVotingMember returns (uint256) {
        if (
            pType != ProposalType.ListToken &&
            pType != ProposalType.DelistToken &&
            pType != ProposalType.RelistToken
        ) revert BadStatus();

        if (token == address(0) || token == STRN) revert BadToken();

        return _createProposal(pType, address(0), address(0), token, 0, 0, memo);
    }

    function proposeFundMove(
        ProposalType pType,
        address token,
        address to,
        uint256 amount,
        string calldata memo
    ) external onlyVotingMember returns (uint256) {
        if (
            pType != ProposalType.TreasuryExternalTransfer &&
            pType != ProposalType.TreasuryInternalTransfer &&
            pType != ProposalType.SweptExternalTransfer &&
            pType != ProposalType.SweptInternalTransfer
        ) revert BadStatus();

        if (to == address(0)) revert ZeroAddress();
        if (!wasListed(token)) revert BadToken();
        if (amount == 0) revert BadAmount();

        return _createProposal(pType, address(0), to, token, amount, 0, memo);
    }

    function proposeParameter(
        ProposalType pType,
        uint64 newValue,
        string calldata memo
    ) external onlyVotingMember returns (uint256) {
        if (
            pType != ProposalType.ChangeVotingPeriod &&
            pType != ProposalType.ChangeExecutionDelay &&
            pType != ProposalType.ChangeExecutionExpiry &&
            pType != ProposalType.ChangeRestakeDelay &&
            pType != ProposalType.ChangeRemovedExitWindow
        ) revert BadStatus();

        _checkParameterBounds(pType, newValue);

        return _createProposal(pType, address(0), address(0), address(0), 0, newValue, memo);
    }

    function _createProposal(
        ProposalType pType,
        address account,
        address target,
        address token,
        uint256 amount,
        uint64 value,
        string calldata memo
    ) internal returns (uint256 id) {
        id = nextProposalId++;

        Proposal storage p = proposals[id];
        p.pType = pType;
        p.status = ProposalStatus.Active;
        p.proposer = msg.sender;
        p.account = account;
        p.target = target;
        p.token = token;
        p.amount = amount;
        p.value = value;
        p.startBlock = uint64(block.number);
        p.endBlock = uint64(block.number) + votingPeriod;
        p.executeAfter = uint64(block.number) + votingPeriod + executionDelay;
        p.expiresAt = uint64(block.number) + votingPeriod + executionDelay + executionExpiry;
        p.memo = memo;

        emit ProposalCreated(
            id,
            pType,
            msg.sender,
            account,
            target,
            token,
            amount,
            value,
            p.endBlock,
            memo
        );
    }

    // ---------------------------------------------------------------------
    // Voting / recovery cancellation / expiry
    // ---------------------------------------------------------------------

    function vote(uint256 proposalId, VoteChoice choice) external {
        Proposal storage p = proposals[proposalId];

        if (p.status != ProposalStatus.Active) revert ProposalNotActive();
        if (block.number > p.endBlock) revert VotingClosed();
        if (choice == VoteChoice.None) revert BadStatus();

        // Recovery self-veto: if the old address votes No, cancel recovery.
        if (
            p.pType == ProposalType.RecoverAccount &&
            msg.sender == p.account &&
            choice == VoteChoice.No
        ) {
            p.status = ProposalStatus.Cancelled;
            emit RecoveryCancelled(proposalId, msg.sender);
            return;
        }

        if (!isVotingMember(msg.sender)) revert NotVotingMember();

        if (
            (p.pType == ProposalType.RecoverAccount || p.pType == ProposalType.RemoveMember) &&
            msg.sender == p.account
        ) {
            revert SelfVoteBlocked();
        }

        VoteChoice old = voteOf[proposalId][msg.sender];

        if (old == VoteChoice.Yes) p.yesVotes--;
        else if (old == VoteChoice.No) p.noVotes--;
        else if (old == VoteChoice.Abstain) p.abstainVotes--;

        if (choice == VoteChoice.Yes) p.yesVotes++;
        else if (choice == VoteChoice.No) p.noVotes++;
        else if (choice == VoteChoice.Abstain) p.abstainVotes++;

        voteOf[proposalId][msg.sender] = choice;

        emit VoteCast(proposalId, msg.sender, choice);
    }

    function cancelOwnRecovery(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        if (p.status != ProposalStatus.Active) revert ProposalNotActive();
        if (p.pType != ProposalType.RecoverAccount) revert BadStatus();
        if (p.account != msg.sender) revert SelfVoteBlocked();

        p.status = ProposalStatus.Cancelled;

        emit RecoveryCancelled(proposalId, msg.sender);
    }

    function expire(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        if (p.status != ProposalStatus.Active) revert ProposalNotActive();
        if (block.number <= p.expiresAt) revert ExecutionTooEarly();

        p.status = ProposalStatus.Expired;

        emit ProposalExpired(proposalId);
    }

    // ---------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------

    function execute(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];

        if (p.status != ProposalStatus.Active) revert ProposalNotActive();
        if (block.number <= p.endBlock) revert VotingOpen();
        if (!hasPassed(proposalId)) revert NotPassed();
        if (block.number < p.executeAfter) revert ExecutionTooEarly();
        if (block.number > p.expiresAt) revert ExecutionExpired();

        p.status = ProposalStatus.Executed;

        ProposalType t = p.pType;

        if (t == ProposalType.AdmitDaoMember) {
            _execAdmitDaoMember(p.account);
        } else if (t == ProposalType.AdmitBankMember) {
            _execAdmitBankMember(p.account);
        } else if (t == ProposalType.RemoveMember) {
            _execRemoveMember(p.account);
        } else if (t == ProposalType.RecoverAccount) {
            _execRecoverAccount(p.account, p.target);
        } else if (t == ProposalType.ListToken) {
            _execListToken(p.token);
        } else if (t == ProposalType.DelistToken) {
            _execDelistToken(p.token);
        } else if (t == ProposalType.RelistToken) {
            _execRelistToken(p.token);
        } else if (t == ProposalType.TreasuryExternalTransfer) {
            _execDaoFundsTransfer(false, false, p.token, p.target, p.amount);
        } else if (t == ProposalType.TreasuryInternalTransfer) {
            _execDaoFundsTransfer(false, true, p.token, p.target, p.amount);
        } else if (t == ProposalType.SweptExternalTransfer) {
            _execDaoFundsTransfer(true, false, p.token, p.target, p.amount);
        } else if (t == ProposalType.SweptInternalTransfer) {
            _execDaoFundsTransfer(true, true, p.token, p.target, p.amount);
        } else if (
            t == ProposalType.ChangeVotingPeriod ||
            t == ProposalType.ChangeExecutionDelay ||
            t == ProposalType.ChangeExecutionExpiry ||
            t == ProposalType.ChangeRestakeDelay ||
            t == ProposalType.ChangeRemovedExitWindow
        ) {
            _execChangeParameter(t, p.value);
        } else {
            revert BadStatus();
        }

        emit ProposalExecuted(proposalId);
    }

    // ---------------------------------------------------------------------
    // Execution internals
    // ---------------------------------------------------------------------

    function _execAdmitDaoMember(address account) internal {
        if (account == address(0)) revert ZeroAddress();
        if (members[account].status != MemberStatus.None) revert AlreadyRegistered();

        members[account].status = MemberStatus.Dao;

        emit DaoMemberAdmitted(account);
    }

    function _execAdmitBankMember(address account) internal {
        if (account == address(0)) revert ZeroAddress();
        if (members[account].status != MemberStatus.None) revert AlreadyRegistered();

        members[account].status = MemberStatus.Bank;

        emit BankMemberAdmitted(account);
    }

    function _execRemoveMember(address account) internal {
        Member storage m = members[account];

        if (m.status != MemberStatus.Bank && m.status != MemberStatus.Dao) revert BadStatus();

        if (m.staked) {
            m.staked = false;
            _creditUser(account, STRN, STRN_STAKE);
            // totalLiability unchanged: staked liability becomes bank balance liability.
        }

        m.status = MemberStatus.RemovedExitOnly;
        m.removedAtBlock = uint64(block.number);

        emit MemberRemoved(account);
    }

    function _execRecoverAccount(address oldAccount, address newAccount) internal {
        if (newAccount == address(0)) revert ZeroAddress();

        Member storage oldM = members[oldAccount];
        if (
            oldM.status != MemberStatus.Bank &&
            oldM.status != MemberStatus.Dao &&
            oldM.status != MemberStatus.RemovedExitOnly
        ) revert BadStatus();

        if (members[newAccount].status != MemberStatus.None) revert RecoveryTargetInvalid();

        address[] storage assets = userAssets[oldAccount];
        if (assets.length > MAX_RECOVERY_ASSETS) revert RecoveryTooLarge();

        members[newAccount] = oldM;

        for (uint256 i = 0; i < assets.length; i++) {
            address token = assets[i];
            uint256 amount = balanceOf[oldAccount][token];

            if (amount != 0) {
                balanceOf[oldAccount][token] = 0;
                _creditUser(newAccount, token, amount);
            }
        }

        oldM.status = MemberStatus.RecoveredRetired;
        oldM.staked = false;
        oldM.restakeReadyBlock = 0;
        oldM.removedAtBlock = 0;
    }

    function _execListToken(address token) internal {
        if (token == ETC || token == STRN) revert BadToken();
        if (tokenStatus[token] != TokenStatus.NeverListed) revert BadStatus();

        tokenStatus[token] = TokenStatus.Active;

        emit TokenListed(token);
    }

    function _execDelistToken(address token) internal {
        if (token == ETC || token == STRN) revert BadToken();
        if (tokenStatus[token] != TokenStatus.Active) revert BadStatus();

        tokenStatus[token] = TokenStatus.Delisted;

        emit TokenDelisted(token);
    }

    function _execRelistToken(address token) internal {
        if (token == ETC || token == STRN) revert BadToken();
        if (tokenStatus[token] != TokenStatus.Delisted) revert BadStatus();

        tokenStatus[token] = TokenStatus.Active;

        emit TokenRelisted(token);
    }

    function _execDaoFundsTransfer(
        bool fromSwept,
        bool toInternal,
        address token,
        address to,
        uint256 amount
    ) internal {
        if (!wasListed(token)) revert BadToken();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert BadAmount();

        if (fromSwept) {
            if (sweptBalance[token] < amount) revert BadAmount();
            sweptBalance[token] -= amount;
        } else {
            if (treasuryBalance[token] < amount) revert BadAmount();
            treasuryBalance[token] -= amount;
        }

        if (toInternal) {
            if (!isActiveUser(to)) revert NotAdmitted();
            if (!isActiveToken(token)) revert BadToken();

            _creditUser(to, token, amount);
            // Liability unchanged: DAO liability becomes user liability.
        } else {
            totalLiability[token] -= amount;
            _sendAsset(token, to, amount);
        }

        if (fromSwept) {
            emit SweptFundsTransfer(token, to, amount, toInternal);
        } else {
            emit TreasuryTransfer(token, to, amount, toInternal);
        }
    }

    function _execChangeParameter(ProposalType pType, uint64 value) internal {
        _checkParameterBounds(pType, value);

        if (pType == ProposalType.ChangeVotingPeriod) {
            votingPeriod = value;
        } else if (pType == ProposalType.ChangeExecutionDelay) {
            executionDelay = value;
        } else if (pType == ProposalType.ChangeExecutionExpiry) {
            executionExpiry = value;
        } else if (pType == ProposalType.ChangeRestakeDelay) {
            restakeDelay = value;
        } else if (pType == ProposalType.ChangeRemovedExitWindow) {
            removedExitWindow = value;
        } else {
            revert BadStatus();
        }

        emit ParameterChanged(pType, value);
    }

    function _checkParameterBounds(ProposalType pType, uint64 value) internal pure {
        if (pType == ProposalType.ChangeVotingPeriod) {
            if (value < MIN_VOTING_PERIOD || value > MAX_VOTING_PERIOD) revert ParamOutOfBounds();
        } else if (pType == ProposalType.ChangeExecutionDelay) {
            if (value < MIN_EXECUTION_DELAY || value > MAX_EXECUTION_DELAY) revert ParamOutOfBounds();
        } else if (pType == ProposalType.ChangeExecutionExpiry) {
            if (value < MIN_EXECUTION_EXPIRY || value > MAX_EXECUTION_EXPIRY) revert ParamOutOfBounds();
        } else if (pType == ProposalType.ChangeRestakeDelay) {
            if (value < MIN_RESTAKE_DELAY || value > MAX_RESTAKE_DELAY) revert ParamOutOfBounds();
        } else if (pType == ProposalType.ChangeRemovedExitWindow) {
            if (value < MIN_REMOVED_EXIT_WINDOW || value > MAX_REMOVED_EXIT_WINDOW) revert ParamOutOfBounds();
        } else {
            revert BadStatus();
        }
    }

    // ---------------------------------------------------------------------
    // Internal accounting helpers
    // ---------------------------------------------------------------------

    function _creditUser(address user, address token, uint256 amount) internal {
        if (amount == 0) return;

        if (!hasUserAsset[user][token]) {
            hasUserAsset[user][token] = true;
            userAssets[user].push(token);
        }

        balanceOf[user][token] += amount;
    }

    function _debitUser(address user, address token, uint256 amount) internal {
        if (balanceOf[user][token] < amount) revert BadAmount();
        balanceOf[user][token] -= amount;
    }

    function _tryActivateGovernance() internal {
        if (
            !governanceActive &&
            members[founder1].staked &&
            members[founder2].staked &&
            members[founder3].staked
        ) {
            governanceActive = true;
            emit BootstrapCompleted(block.number);
        }
    }

    // ---------------------------------------------------------------------
    // Asset transfer helpers
    // ---------------------------------------------------------------------

    function _sendAsset(address token, address to, uint256 amount) internal {
        if (token == ETC) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            _safeTransfer(token, to, amount);
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount)
        );

        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount)
        );

        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }
}
