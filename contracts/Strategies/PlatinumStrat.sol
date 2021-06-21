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

/*
  LP: 0x125ca224d49b717a636a6b2e593d0d2f29c6bf1a: 8, 20
  BlueToken: 0x36C0556c2B15aED79F842675Ff030782738eF9e8: 24
*/

/**
 * @dev Strategy to farm rewardToken tokens through a Pancakeswap and Cafeswap routers based MasterChef contract.
 */
contract PlatinumStrategy is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /**
     * @dev Tokens Used:
     * {wbnb, busd} - Required for liquidity routing when doing swaps.
     * {rewardToken} - Token that the strategy farms.
     * {brew} - Cafeswap token, used to send funds to be burned
     */
    address public constant wbnb =
        address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c); // WBNB Token
    address public constant busd =
        address(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56); // BUSD Token
    address public constant rewardToken =
        address(0x75A52196012ca777b94265F8c3eFEEF5693cE981); // Platinum Token
    address public constant brew =
        address(0x790Be81C3cA0e53974bE2688cDb954732C9862e1); // Brew Token

    /**
     * @dev Third Party Contracts:
     * {unirouter} - PancakeSwap unirouter
     * {caferouter} - CafeSwap unirouter
     * {masterchef} - MasterChef contract
     * {poolId} - MasterChef pool id
     */
    address public constant unirouter =
        address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    address public constant caferouter =
        address(0x933DAea3a5995Fb94b14A7696a5F3ffD7B1E385A);
    address public constant masterchef =
        address(0x9616423F893228101A570D511CcDB0610a949559); // Platinum MasterChef
    uint8 public poolId;

    /**
     * @dev CafeVault Contracts:
     * {vault} - Address of the vault that controls the strategy's funds.
     * {strategist} - Address of the strategy author/deployer where strategist fee will go.
     * {burnerAddress} - Address of where the brew reward will go.
     * {lpPair} - Token that the strategy maximizes. The same token that users deposit in the vault.
     * {lpToken0, lpToken1} - Tokens that the strategy maximizes. IUniswapV2Pair tokens
     */
    address public vault;
    address public strategist;
    address public burnerAddress;
    address public lpPair;
    address public lpToken0;
    address public lpToken1;

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
    uint256 public constant BURN_FEE = 600;
    uint256 public constant CALL_FEE = 200;
    uint256 public constant STRATEGIST_FEE = 200;
    uint256 public constant MAX_FEE = 1000;

    uint256 public constant WITHDRAWAL_FEE = 10;
    uint256 public constant WITHDRAWAL_MAX = 10000;

    /**
     * @dev Routes we take to swap tokens using PancakeSwap and CafeSwap.
     * {rewardTokenToWbnbRoute} - Route we take to go from {rewardToken} into {wbnb}. via the Pancakeswap router
     * {wbnbToBrewRoute} - Route we take to go from {wbnb} into {brew}. via the Cafeswap router
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
     * @dev Initializes the strategy with the token that it will look to maximize.
     * @param _vault Address to initialize {vault}
     * @param _strategist Address to initialize {strategist}
     * @param _burnerAddress Address to initialize {burnerAddress}
     * @param _lpPair Address of the LP pair to maximize
     * @param _poolId Pool ID of where to stake the LP
     */
    constructor(
        address _vault,
        address _strategist,
        address _burnerAddress,
        address _lpPair,
        uint8 _poolId
    ) public {
        vault = _vault;
        strategist = _strategist;
        burnerAddress = _burnerAddress;
        lpPair = _lpPair;
        lpToken0 = IUniswapV2Pair(lpPair).token0();
        lpToken1 = IUniswapV2Pair(lpPair).token1();
        poolId = _poolId;

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

        IERC20(lpPair).safeApprove(masterchef, uint256(-1));
        IERC20(rewardToken).safeApprove(unirouter, uint256(-1));
        IERC20(wbnb).safeApprove(unirouter, uint256(-1));
        IERC20(wbnb).safeApprove(caferouter, uint256(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));
    }

    /**
     * @dev Function that puts the funds to work.
     * It gets called whenever someone deposits in the strategy's vault contract.
     * It deposits {rewardToken} in the MasterChef to earn rewards in {rewardToken}.
     */
    function deposit() public whenNotPaused {
        uint256 pairBal = IERC20(lpPair).balanceOf(address(this));

        if (pairBal > 0) {
            IMasterChef(masterchef).deposit(poolId, pairBal);
        }
    }

    /**
     * @dev It withdraws {rewardToken} from the MasterChef and sends it to the vault.
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
        uint256 toWbnb =
            IERC20(rewardToken).balanceOf(address(this)).mul(25).div(1000);
        IUniswapRouterETH(unirouter).swapExactTokensForTokens(
            toWbnb,
            0,
            rewardTokenToWbnbRoute,
            address(this),
            now.add(600)
        );

        uint256 wbnbBal = IERC20(wbnb).balanceOf(address(this));

        uint256 callFee = wbnbBal.mul(CALL_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(msg.sender, callFee);

        uint256 burnFee = wbnbBal.mul(BURN_FEE).div(MAX_FEE);
        IUniswapRouterETH(caferouter).swapExactTokensForTokens(
            burnFee,
            0,
            wbnbToBrewRoute,
            burnerAddress,
            now.add(600)
        );

        uint256 strategistFee = wbnbBal.mul(STRATEGIST_FEE).div(MAX_FEE);
        IERC20(wbnb).safeTransfer(strategist, strategistFee);
    }

    /**
     * @dev Swaps {rewardToken} for {lpToken0}, {lpToken1} & {wbnb} using PancakeSwap.
     */
    function addLiquidity() internal {
        uint256 rewardTokenHalf =
            IERC20(rewardToken).balanceOf(address(this)).div(2);

        if (lpToken0 != rewardToken) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                rewardTokenHalf,
                0,
                rewardTokenToLp0Route,
                address(this),
                now.add(600)
            );
        }

        if (lpToken1 != rewardToken) {
            IUniswapRouterETH(unirouter).swapExactTokensForTokens(
                rewardTokenHalf,
                0,
                rewardTokenToLp1Route,
                address(this),
                now.add(600)
            );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(
            lpToken0,
            lpToken1,
            lp0Bal,
            lp1Bal,
            1,
            1,
            address(this),
            now.add(600)
        );
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
        (uint256 _amount, ) =
            IMasterChef(masterchef).userInfo(poolId, address(this));
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
        IERC20(wbnb).safeApprove(caferouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        IERC20(lpPair).safeApprove(masterchef, uint256(-1));
        IERC20(rewardToken).safeApprove(unirouter, uint256(-1));
        IERC20(wbnb).safeApprove(unirouter, uint256(-1));
        IERC20(wbnb).safeApprove(caferouter, uint256(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));
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
