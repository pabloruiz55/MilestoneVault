# MilestoneVault
A vault to store crowdsale / ICO funds which get released after milestones are met by the team.

## About this contract

## How to use it

1. In your crowdsale contract, instantiate a MilestoneVault contract.
MilestoneVault receives 3 parameters:
- address _admin: The account responsible for managing the vault.
- address _wallet: The account where funds withdrawn at each milestone will get forwarded to.
- uint8[] _milestones: An array containing the percentages to be claimed by the admin at each milestone. There can be any amount of milestones, they must sum 100%.
```
uint8[] memory milestones = new uint8[](3);
milestones[0]= 30;
milestones[1]= 40;
milestones[2]= 30;
milestoneVault = new MilestoneVault(0x0001...,0x0002...,milestones);
    
```

2. In your crowdsale contract, instead of forwarding funds received to a wallet, forward them to this vault.
Typically, in the buyTokens() function of the crowdsale you would have to do: 
```
milestoneVault.deposit.value(msg.value)(msg.sender);
```
Now each time a contributor buys tokens, their ether will get stored in this vault.

3. Once the crowdsale is finished, the crowdsale contract should call close() to have the vault finish collecting funds.
You would typically call this function in the buyTokens() function when fundsRaised > hardCap.
```
milestoneVault.close();
```

4. Now that the ICO has succesfully finished, the account set as the admin can request the funds that correspond to each milestone set. To initiate the request for funds call requestFunds() from the admin account.

5. Now that the request has been initiated, the contributors have until `now + VOTING_TIME` to cast their negative vote by calling voteAgainstFundsWithdrawal(). If there's a majority of votes against the request, the withdrawal is cancelled.

6. If the request is not rejected by the voting period end, then the admin can call withdrawFunds() to have the corresponding funds forwarded to the account set as wallet in the MilestoneVault contract.

7. Then, the admin can repeat steps 4 to 6 to initiate a new request for the next milestone. 

8. In the case that the request is rejected, the admin can initiate another request by calling requestFunds() again after the `WITHDRAWAL_RETRY_TIME` has passed.

9. If enough request for the same milestone are rejected (defined by MAX_RETRY_ATTEMPTS) then the project gets cancelled and remaining funds are locked inside the contract for contributors to withdraw.

10. If project is cancelled by repeated failed withdrawal attempts, contributors can get their money refunded by calling refundContributions(). 
