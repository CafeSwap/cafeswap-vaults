// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts/GSN/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../interfaces/IUniswapRouterETH.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IMasterChef.sol";

/**
 * @dev Strategy to farm RewardToken through a CafeSwap based MasterChef contract.
 */
contract StrategyReward is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {rewardToken} - Token that the strategy maximizes. The same token that users deposit in the vault.
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public rewardToken = address(0x790Be81C3cA0e53974bE2688cDb954732C9862e1);
    address constant public brew = address(0x790Be81C3cA0e53974bE2688cDb954732C9862e1);
    address public burnerAddress;

    /**
     * @dev Third Party Contracts:
     * {unirouter} - CafeSwap unirouter
     * {masterchef} - MasterChef contract. Stake RewardToken, get rewards.
     */
    address constant public unirouter  = address(0x933DAea3a5995Fb94b14A7696a5F3ffD7B1E385A);
    address constant public masterchef = address(0xc772955c33088a97D56d0BBf473d05267bC4feBB);

    /**
     * @dev Contracts:
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     */
    address public vault;
    address public strategist;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 2.5% for fees.
     *
     * {BURN_FEE} - 2.5% goes to buying RewardToken and burning it.
     * {CALL_FEE} - 0.5% goes to whoever executes the harvest function as gas subsidy.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public BURN_FEE    = 714;
    uint constant public CALL_FEE       = 143;
    uint constant public STRATEGIST_FEE = 143;
    uint constant public MAX_FEE        = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using CafeSwap.
     * {rewardTokenToWbnbRoute} - Route we take to go from {rewardToken} into {wbnb}.
     * {wbnbToRewardTokenRoute} - Route we take to go from {wbnb} into {rewardToken}.
     * {wbnbToBrew} - Route we take to go from {wbnb} into {rewardToken}.
     */
    address[] public rewardTokenToWbnbRoute = [rewardToken, wbnb];
    address[] public wbnbToRewardTokenRoute = [wbnb, rewardToken];
    address[] public wbnbToBrew = [wbnb, brew];

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token that it will look to maximize.
     * @param _vault Address to initialize {vault}
     * @param _strategist Address to initialize {strategist}
     */
    constructor(
        address _vault,
        address _strategist,
        address _burnerAddress
    ) public {
        vault = _vault;
        strategist = _strategist;
        burnerAddress = _burnerAddress;

        IERC20(rewardToken).safeApprove(masterchef, uint(-1));
        IERC20(rewardToken).safeApprove(unirouter, uint(-1));
        IERC20(brew).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits rewardToken in the MasterChef to earn rewards in rewardToken.
     */
    function deposit() public whenNotPaused {
        uint256 rewardTokenBal = IERC20(rewardToken).balanceOf(address(this));

        if (rewardTokenBal > 0) {
            IMasterChef(masterchef).enterStaking(rewardTokenBal);
        }
    }

    /**
     * @dev It withdraws rewardToken from the MasterChef and sends it to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 rewardTokenBal = IERC20(rewardToken).balanceOf(address(this));

        if (rewardTokenBal < _amount) {
            IMasterChef(masterchef).leaveStaking(_amount.sub(rewardTokenBal));
            rewardTokenBal = IERC20(rewardToken).balanceOf(address(this));
        }

        if (rewardTokenBal > _amount) {
            rewardTokenBal = _amount;    
        }

        if (tx.origin == owner()) {
            IERC20(rewardToken).safeTransfer(vault, rewardTokenBal);
        } else {
            uint256 withdrawalFee = rewardTokenBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
            IERC20(rewardToken).safeTransfer(vault, rewardTokenBal.sub(withdrawalFee));
        }
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the MasterChef
     * 3. It charges the system fee and sends it to BREW stakers.
     * 4. It re-invests the remaining profits.
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IMasterChef(masterchef).leaveStaking(0);
        chargeFees();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 2.5% as system fees from the rewards. 
     * 0.5% -> Call Fee
     * 0.5% -> Strategist fee
     * 1.5% -> BURN BREW
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(rewardToken).balanceOf(address(this)).mul(35).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                  toWbnb,
                  0,
                  rewardTokenToWbnbRoute,
                  address(this),
                  now.add(600));

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));
        
        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);

        uint256 burnFee = wbnbBal.mul(BURN_FEE).div(MAX_FEE);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(
          burnFee,
          0,
          wbnbToBrew,
          burnerAddress,
          now.add(600));

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Function to calculate the total underlaying {rewardToken} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the MasterChef.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfRewardToken().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {rewardToken} the contract holds.
     */
    function balanceOfRewardToken() public view returns (uint256) {
        return IERC20(rewardToken).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {rewardToken} the strategy has allocated in the MasterChef
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(0, address(this));
        return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(masterchef).emergencyWithdraw(0);

        uint256 rewardTokenBal = IERC20(rewardToken).balanceOf(address(this));
        IERC20(rewardToken).transfer(vault, rewardTokenBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the MasterChef, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IMasterChef(masterchef).emergencyWithdraw(0);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(rewardToken).safeApprove(masterchef, 0);
        IERC20(rewardToken).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(rewardToken).safeApprove(masterchef, uint(-1));
        IERC20(rewardToken).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Updates address where strategist fee earnings will go.
     * @param _strategist new strategist address.
     */
    function setStrategist(address _strategist) external {
        require(msg.sender == strategist, "!strategist");
        strategist = _strategist;
    }
}