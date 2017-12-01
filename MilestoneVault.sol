pragma solidity 0.4.18;

/// @author Pablo Ruiz - 2017 - me@pabloruiz.co
/// @title MilestoneVault - A vault to store funds received during a token sale.
/// Funds are released in milestones, approved by the original contributors

//
// Permissions
//
//                  crowdsale contract      admin       contributor
// Constructor              x
// Deposit                  x
// Close                    x
// Withdraw funds                             x
// Request funds                              x
// Vote against                                             x
// Refund contributions                                     x

contract MilestoneVault {
    using SafeMath for uint256;

    // The crowdsale that created the vault -> The only address allowed to forward funds to the vault
    address public crowdsale;

    // The account responsible for requesting funds and withdrawing them
    address public admin;

    // The address where funds will be transferred when a milestone is reached
    address public wallet;

    // How much ether gets transferred to wallet when milestone is reached.
    // Accepts any number of milestones which must sum 100%
    // For example: [30,40,20,10] -> Milestone 1 gives 30% of the funds raised,
    // milestone 2 40%, milestone 3 20% and milestone 4 10%.
    uint8[] public milestones;

    // Which milestone is being processed
    uint public currentMilestone;

    // How many attempts the current milestone has had.
    uint public currentRejectRetry = 0;

    // Funds deposited by each contributor. Used to weight votes and refund on project failure.
    mapping (address => uint256) public deposited;

    // Total funds collected by the vault during the crowdsale
    uint public totalFunds;

    // Total funds withdrawn by the owner after each milestone is reached
    uint public fundsWithdrawn;

    enum State { Fundraising, Closed, Voting, WithdrawalRejected, ProjectCancelled}
    State public state;

    // Marks when the voting period started upon funds request by owner
    uint public votingStartTime;

    // Marks the end of the voting period. No votes can be submitted afterwards
    uint public votingEndTime;

    // total votes (weighted by contribution) the current request for withdrawal has
    uint public votesAgainstWithdrawal;

    // Stores whether or not a contributor has voted in the current Milestone -> Retry
    mapping (address => mapping (uint => mapping (uint => bool))) public voteCast;

    //
    // CONSTANTS
    // The following constants control the timing of the withdrawal requests
    //

    // How much time has to pass for the admin to request funds again after a failed attempt
    uint constant WITHDRAWAL_RETRY_TIME = 10 days;

    // The duration of each voting period.
    uint constant VOTING_TIME = 5 days;

    // If the crowdsale team tries to withdraw many times and the investors reject it, then
    // we deem the project a failure. Investors can get a refund on funds not yet withdrawn by admin.
    // They would also keep their tokens, but at this point it wouldn't matter, I guess.
    uint constant MAX_RETRY_ATTEMPTS = 3;

    modifier onlyAdmin {
        require(msg.sender == admin);
        _;
    }

    modifier onlyCrowdsale {
        require(msg.sender == crowdsale);
        _;
    }

    //
    // Events
    //

    event Closed();
    event E_FundsRequested(uint _requested, uint _votingStartTime, uint _votingEndTime);
    event E_RejectedWithdrawal(uint _votesAgainstWithdrawal,uint _totalFunds);
    event E_FundsWithdrawn(uint _milestone,uint _fundsWithdrawn);
    event E_ProjectCancelled(uint _cancellationTime, uint _rejectRetry, uint _rejectMilestone);
    event E_RefundedContribution(uint refundDate, uint _refunded);
    event E_Closed();

    /// @dev contract constructor. Called by crowdsale contract
    /// @param _admin The administrator of the vault. Responsible for requesting withdrawals
    /// @param _wallet The address where the funds withdrawn by admin will be forwarded to
    /// @param _milestones An array with the percentaje (uint values) to be withdrawn at each milestone
    function MilestoneVault(address _admin,address _wallet, uint8[] _milestones) public {
        require(_wallet != address(0));
        require(_admin != address(0));
        require(_milestones.length >0);

        uint8 _milestonesSum = 0;
        for(uint8 i; i<_milestones.length;i++){
            _milestonesSum += _milestones[i];
        }
        require(_milestonesSum == 100);

        wallet = _wallet;
        crowdsale = msg.sender;
        admin = _admin;
        milestones = _milestones;

        state = State.Fundraising;
    }

    /// @dev Crowdsale contract should forward funds here instead of to their wallet
    /// Funds are secured here while the admin has access as milestones are reached.
    /// Typically called like this from the crowdsale milestoneVault.deposit.value(msg.value)(msg.sender);
    /// @param _contributor The address of the contributor who bought tokens on the crowdsale
    function deposit(address _contributor) public onlyCrowdsale payable {
        require(state == State.Fundraising);
        deposited[_contributor] = deposited[_contributor].add(msg.value);
        totalFunds = totalFunds.add(msg.value);
    }

    /// @dev Crowdsale contract should call this function when the crowdsale successfully ends
    /// No more funds may be received afterwards. Admin can start requesting funds afterwards.
    function close() onlyCrowdsale public {
        require(state == State.Fundraising);
        require(totalFunds > 0);
        state = State.Closed;
        E_Closed();
      }

    /// @dev Withdraw funds for the current milestone (only if contributors did not reject it)
    function withdrawFunds() public onlyAdmin {
        require(currentMilestone < milestones.length); // Make sure we haven't already gone through all milestones

        // State equals voting when the owner has requested the funds and the voters
        // have not yet rejected it.
        require(state == State.Voting);

        // We have to wait until the voting period has ended
        require(now > votingEndTime);

        uint allowedWithdrawal = milestones[currentMilestone]; // % to withdraw
        uint fundsToWithdraw = totalFunds.mul(allowedWithdrawal).div(100);
        require(fundsToWithdraw <= this.balance);

        fundsWithdrawn = fundsWithdrawn.add(fundsToWithdraw); // Keep track of funds withdrawn so far

        currentRejectRetry = 0; //Reset attempts at withdrawing funds for this milestone
        currentMilestone++; // Move to the next milestone

        state = State.Closed; // Back to the starting point ()

        // transfer the funds to the wallet
        wallet.transfer(fundsToWithdraw);

        E_FundsWithdrawn(currentMilestone-1,fundsToWithdraw);
    }

    /// @dev initiate funds withdrawal request. Once this is called, voting period begins.
    /// If contributors don't reject it, admin will be able to withdraw the funds after the voting period ends
    function requestFunds() public onlyAdmin {
        //Can request funds only if:
        //1. Previous request was successful (or if it is the first time)
        //2. OR previous request was rejected and enough time has passed since then
        require(state == State.Closed ||
        (state == State.WithdrawalRejected && now > votingEndTime + WITHDRAWAL_RETRY_TIME));

        // Reset voting variables
        votesAgainstWithdrawal = 0;
        votingStartTime = now;
        votingEndTime = now + VOTING_TIME;

        // Move to voting state
        state = State.Voting;

        uint requested = totalFunds.mul(milestones[currentMilestone]).div(100);
        E_FundsRequested(requested, votingStartTime,votingEndTime);
    }

    /// @dev contributors should call this function in order to cast their vote.
    /// Votes are weighted by the contribution size.
    /// If more than half votes are received, the request is rejected.
    /// If there are several rejections on the same milestone, we deem the project cancelled
    function voteAgainstFundsWithdrawal() public {
        require(state == State.Voting);
        require(now < votingEndTime);
        require(!voteCast[msg.sender][currentMilestone][currentRejectRetry]); // Make sure no person votes twice
        require(deposited[msg.sender]>0);


        //Votes are weighted, based on the contribution made by the voter
        votesAgainstWithdrawal = votesAgainstWithdrawal.add(deposited[msg.sender]);
        voteCast[msg.sender][currentMilestone][currentRejectRetry] = true;

        //If 51% voted against, the withdrawal is rejected
        if(votesAgainstWithdrawal > totalFunds.div(2)){
            state = State.WithdrawalRejected;
            votingEndTime = now; // No need to keep waiting if request has already been rejected
            currentRejectRetry++; // Now we have another attempt at withdrawing
            E_RejectedWithdrawal(votesAgainstWithdrawal,totalFunds);

            // If during the same milestone, the contributors reject requests past the max,
            // cancel project and allow refunds
            if(currentRejectRetry >= MAX_RETRY_ATTEMPTS){
                state = State.ProjectCancelled;
                E_ProjectCancelled(now,currentRejectRetry, currentMilestone);
            }
        }
    }

    /// @dev Allow contributors to get a refund on funds not yet withdrawn.
    /// Only available if the project has been cancelled by repeat failed requests.
    function refundContributions() public {
        require(state == State.ProjectCancelled);
        require(deposited[msg.sender] > 0);

        // Calculated how much the contributor is entitled to based on
        // what he contributed from the total, minus what the admin already withdrawn
        uint remainingFunds = totalFunds.sub(fundsWithdrawn);
        uint funds = remainingFunds.mul(deposited[msg.sender]).div(totalFunds);

        require (funds <= this.balance);

        deposited[msg.sender] = 0;

        // Transfer the funds to the contributor
        msg.sender.transfer(funds);

        E_RefundedContribution(now, funds);
    }

    function getBalance() view public returns (uint) {
        return this.balance;
    }
}


/**
 * @title SafeMath
 * @dev Math operations with safety checks that throw on error
 */
library SafeMath {
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    if (a == 0) {
      return 0;
    }
    uint256 c = a * b;
    assert(c / a == b);
    return c;
  }

  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    // assert(b > 0); // Solidity automatically throws when dividing by 0
    uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold
    return c;
  }

  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    assert(b <= a);
    return a - b;
  }

  function add(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    assert(c >= a);
    return c;
  }
}
