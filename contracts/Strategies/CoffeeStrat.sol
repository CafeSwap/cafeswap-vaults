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
 * @dev Strategy to farm Brew through a CafeSwap based MasterChef contract.
 */
contract StrategyBrew is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb} - Required for liquidity routing when doing swaps.
     * {brew} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {brew} - CafeSwap token, used to send funds to the treasury.
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public brew = address(0x790Be81C3cA0e53974bE2688cDb954732C9862e1);
    address public burnerAddress;

    /**
     * @dev Third Party Contracts:
     * {unirouter} - CafeSwap unirouter
     * {masterchef} - MasterChef contract. Stake Brew, get rewards.
     */
    address constant public unirouter  = address(0x933DAea3a5995Fb94b14A7696a5F3ffD7B1E385A);
    address constant public masterchef = address(0xc772955c33088a97D56d0BBf473d05267bC4feBB);

    /**
     * @dev Coffee Contracts:
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     */
    address public vault;
    address public strategist;

    /**
     * @dev Distribution of fees earned. This allocations relative to the % implemented on doSplit().
     * Current implementation separates 2.5% for fees.
     *
     * {BURN_FEE} - 2.5% goes to buying BREW and burning it.
     * {CALL_FEE} - 0.5% goes to whoever executes the harvest function as gas subsidy.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public BURN_FEE    = 716;
    uint constant public CALL_FEE       = 142;
    uint constant public STRATEGIST_FEE = 142;
    uint constant public MAX_FEE        = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using PancakeSwap.
     * {brewToWbnbRoute} - Route we take to go from {brew} into {wbnb}.
     * {wbnbToBrewRoute} - Route we take to go from {wbnb} into {brew}.
     */
    address[] public brewToWbnbRoute = [brew, wbnb];
    address[] public wbnbToBrewRoute = [wbnb, brew];

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

        IERC20(brew).safeApprove(masterchef, uint(-1));
        IERC20(brew).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits brew in the MasterChef to earn rewards in brew.
     */
    function deposit() public whenNotPaused {
        uint256 brewBal = IERC20(brew).balanceOf(address(this));

        if (brewBal > 0) {
            IMasterChef(masterchef).enterStaking(brewBal);
        }
    }

    /**
     * @dev It withdraws brew from the MasterChef and sends it to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 brewBal = IERC20(brew).balanceOf(address(this));

        if (brewBal < _amount) {
            IMasterChef(masterchef).leaveStaking(_amount.sub(brewBal));
            brewBal = IERC20(brew).balanceOf(address(this));
        }

        if (brewBal > _amount) {
            brewBal = _amount;    
        }

        if (tx.origin == owner()) {
            IERC20(brew).safeTransfer(vault, brewBal);
        } else {
            uint256 withdrawalFee = brewBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
            IERC20(brew).safeTransfer(vault, brewBal.sub(withdrawalFee));
        }
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the MasterChef
     * 3. It charges the system fee and sends it to BREW stakers.
     * 4. It re-invests the remaining profits.
     */
    function harvest() external whenNotPaused {
        require(msg.sender == tx.origin, "!contract");
        IMasterChef(masterchef).leaveStaking(0);
        chargeFees();
        deposit();

        emit StratHarvest(msg.sender);
    }

    /**
     * @dev Takes out 3.5% as system fees from the rewards. 
     * 0.5% -> Call Fee
     * 0.5% -> Strategist fee
     * 2.5% -> BURN BREW
     */
    function chargeFees() internal {
        uint256 toWbnb = IERC20(brew).balanceOf(address(this)).mul(35).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                  toWbnb,
                  0,
                  brewToWbnbRoute,
                  address(this),
                  now.add(600));

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));
        
        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);

        uint256 burnFee = wbnbBal.mul(BURN_FEE).div(MAX_FEE);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(
          burnFee,
          0,
          wbnbToBrewRoute,
          burnerAddress,
          now.add(600));

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Function to calculate the total underlaying {brew} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the MasterChef.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfBrew().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {brew} the contract holds.
     */
    function balanceOfBrew() public view returns (uint256) {
        return IERC20(brew).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {brew} the strategy has allocated in the MasterChef
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

        uint256 brewBal = IERC20(brew).balanceOf(address(this));
        IERC20(brew).transfer(vault, brewBal);
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

        IERC20(brew).safeApprove(masterchef, 0);
        IERC20(brew).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(brew).safeApprove(masterchef, uint(-1));
        IERC20(brew).safeApprove(unirouter, uint(-1));
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