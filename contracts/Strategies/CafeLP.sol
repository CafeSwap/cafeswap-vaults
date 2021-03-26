// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

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
 * @dev Implementation of a strategy to get yields from farming LP Pools in
 * CafeSwap.
 * This strat is currently compatible with all LP pools.
 */
contract StrategyCafeLP is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb, busd} - Required for liquidity routing when doing swaps.
     * {rewardToken} - Token generated by staking our funds.
     * {brew} - BREW token to buy and burn.
     * {lpPair} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {lpToken0, lpToken1} - Tokens that the strategy maximizes. IUniswapV2Pair tokens
     */
    address constant public wbnb = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    address constant public busd = address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    address constant public rewardToken = address(0x790Be81C3cA0e53974bE2688cDb954732C9862e1);
    address constant public brew = address(0x790Be81C3cA0e53974bE2688cDb954732C9862e1);
    address public lpPair;
    address public lpToken0;
    address public lpToken1;

    /**
     * @dev Third Party Contracts:
     * {unirouter} - CafeSwap unirouter
     * {masterchef} - MasterChef contract
     * {poolId} - MasterChef pool id
     */
    address constant public unirouter  = address(0x933DAea3a5995Fb94b14A7696a5F3ffD7B1E385A);
    address constant public masterchef = address(0xc772955c33088a97D56d0BBf473d05267bC4feBB);
    uint8 public poolId;

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
     * {BURN_FEE} - 1.5% goes to buying BREW and burning it.
     * {CALL_FEE} - 0.5% goes to whoever executes the harvest function as gas subsidy.
     * {STRATEGIST_FEE} - 0.5% goes to the strategist.
     * {MAX_FEE} - Aux const used to safely calc the correct amounts.
     *
     * {WITHDRAWAL_FEE} - Fee taxed when a user withdraws funds. 10 === 0.1% fee.
     * {WITHDRAWAL_MAX} - Aux const used to safely calc the correct amounts.
     */
    uint constant public BURN_FEE    = 600;
    uint constant public CALL_FEE       = 200;
    uint constant public STRATEGIST_FEE = 200;
    uint constant public MAX_FEE        = 1000;

    uint constant public WITHDRAWAL_FEE = 10;
    uint constant public WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using PancakeSwap.
     * {rewardTokenToWbnbRoute} - Route we take to get from {rewardToken} into {wbnb}.
     * {wbnbToBrewRoute} - Route we take to get from {wbnb} into {brew}.
     * {rewardTokenToLp0Route} - Route we take to get from {rewardToken} into {lpToken0}.
     * {rewardTokenToLp1Route} - Route we take to get from {rewardToken} into {lpToken1}.
     */
    address[] public rewardTokenToWbnbRoute = [rewardToken, wbnb];
    address[] public wbnbToBrewRoute = [wbnb, brew];
    address[] public rewardTokenToLp0Route;
    address[] public rewardTokenToLp1Route;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);

    /**
     * @dev Initializes the strategy with the token to maximize.
     */
    constructor(address _lpPair, uint8 _poolId, address _vault, address _strategist) public {
        lpPair = _lpPair;
        lpToken0 = IUniswapV2Pair(lpPair).token0();
        lpToken1 = IUniswapV2Pair(lpPair).token1();
        poolId = _poolId;
        vault = _vault;
        strategist = _strategist;

        if (lpToken0 == wbnb) {
            rewardTokenToLp0Route = [rewardToken, wbnb];
        } else if (lpToken0 == busd) {
            rewardTokenToLp0Route = [rewardToken, busd];
        } else if (lpToken0 != rewardToken) {
            rewardTokenToLp0Route = [rewardToken, wbnb, lpToken0];
        }

        if (lpToken1 == wbnb) {
            rewardTokenToLp1Route = [rewardToken, wbnb];
        } else if (lpToken1 == busd) {
            rewardTokenToLp1Route = [rewardToken, busd];
        } else if (lpToken1 != rewardToken) {
            rewardTokenToLp1Route = [rewardToken, wbnb, lpToken1];
        }

        IERC20(lpPair).safeApprove(masterchef, uint(-1));
        IERC20(rewardToken).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {lpPair} in the MasterChef to farm {rewardToken}
     */
    function deposit() public whenNotPaused {
        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal > 0) {
            IMasterChef(masterchef).deposit(poolId, pairBal);
        }
    }

    /**
     * @dev Withdraws funds and sends them back to the vault.
     * It withdraws {lpPair} from the MasterChef.
     * The available {lpPair} minus fees is returned to the vault.
     */
    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal < _amount) {
            IMasterChef(masterchef).withdraw(poolId, _amount.sub(pairBal));
            pairBal = IERC20(lpPair).balanceOf(address(this));
        }

        if (pairBal > _amount) {
            pairBal = _amount;
        }

        uint256 withdrawalFee = pairBal.mul(WITHDRAWAL_FEE).div(WITHDRAWAL_MAX);
        IERC20(lpPair).safeTransfer(vault, pairBal.sub(withdrawalFee));
    }

    /**
     * @dev Core function of the strat, in charge of collecting and re-investing rewards.
     * 1. It claims rewards from the MasterChef.
     * 2. It charges the system fees to simplify the split.
     * 3. It swaps the {rewardToken} token for {lpToken0} & {lpToken1}
     * 4. Adds more liquidity to the pool.
     * 5. It deposits the new LP tokens.
     */
    function harvest() external whenNotPaused {
        require(!Address.isContract(msg.sender), "!contract");
        IMasterChef(masterchef).deposit(poolId, 0);
        chargeFees();
        addLiquidity();
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
        uint256 toWbnb = IERC20(rewardToken).balanceOf(address(this)).mul(25).div(1000);
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
          wbnbToBrewRoute,
          address(0),
          now.add(600));

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Swaps {rewardToken} for {lpToken0}, {lpToken1} & {wbnb} using PancakeSwap.
     */
    function addLiquidity() internal {
        uint256 rewardTokenHalf = IERC20(rewardToken).balanceOf(address(this)).div(2);

        if (lpToken0 != rewardToken) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(rewardTokenHalf, 0, rewardTokenToLp0Route, address(this), now.add(600));
        }

        if (lpToken1 != rewardToken) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(rewardTokenHalf, 0, rewardTokenToLp1Route, address(this), now.add(600));
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(lpToken0, lpToken1, lp0Bal, lp1Bal, 1, 1, address(this), now.add(600));
    }

    /**
     * @dev Function to calculate the total underlaying {lpPair} held by the strat.
     * It takes into account both the funds in hand, as the funds allocated in the MasterChef.
     */
    function balanceOf() public view returns (uint256) {
        return balanceOfLpPair().add(balanceOfPool());
    }

    /**
     * @dev It calculates how much {lpPair} the contract holds.
     */
    function balanceOfLpPair() public view returns (uint256) {
        return IERC20(lpPair).balanceOf(address(this));
    }

    /**
     * @dev It calculates how much {lpPair} the strategy has allocated in the MasterChef
     */
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(poolId, address(this));
        return _amount;
    }

    /**
     * @dev Function that has to be called as part of strat migration. It sends all the available funds back to the 
     * vault, ready to be migrated to the new strat.
     */
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        IMasterChef(masterchef).emergencyWithdraw(poolId);

        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));
        IERC20(lpPair).transfer(vault, pairBal);
    }

    /**
     * @dev Pauses deposits. Withdraws all funds from the MasterChef, leaving rewards behind
     */
    function panic() public onlyOwner {
        pause();
        IMasterChef(masterchef).emergencyWithdraw(poolId);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() public onlyOwner {
        _pause();

        IERC20(lpPair).safeApprove(masterchef, 0);
        IERC20(rewardToken).safeApprove(unirouter, 0);
        IERC20(wbnb).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(lpPair).safeApprove(masterchef, uint(-1));
        IERC20(rewardToken).safeApprove(unirouter, uint(-1));
        IERC20(wbnb).safeApprove(unirouter, uint(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint(-1));
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