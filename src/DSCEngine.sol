// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Adebayo Halir Shola
 *
 * System designed to be as minimal as possible and maintaina 1 token to 1 dollar peg
 * Properties:
 * - Exogenoeus Collteral
 * - Dollar pegged
 * - Algorithmically Stable
 *
 * Our Dsc should always be "Overcollateralized". At no point, should the value of collateral be <= the dollar backed vlue of All dsc
 *
 * Similar to DAI if it had no governance, no fees, and was only backed by WETH and WBTC
 * @notice This is te core of the DSC system. It handles the logic for mining adn redeeming DSC,
 * as wee as depositing and withdrawing collateral
 * @notice This contract is loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    //Errors
    error DSCEngine__AmountMustBeGreaterThanZero();
    error DSCEngine__CollateralTokenNotAllowed();
    error DSCEngine__TokenAddressMustMatchPriceFeedAdressInLength();
    error DSCEngine__onlyOwnerCanSetCoin();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactorWith(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //Types
    using OracleLib for AggregatorV3Interface;

    //State Variables
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    //Events
    event CollteralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );

    //Modifiers
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__AmountMustBeGreaterThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__CollateralTokenNotAllowed();
        }
        _;
    }

    //Functions

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressMustMatchPriceFeedAdressInLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    function depositCollateral(
        address tokenCollateralAddress,
        uint256 collateralAmount
    )
        public
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += collateralAmount;
        emit CollteralDeposited(
            msg.sender,
            tokenCollateralAddress,
            collateralAmount
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress Address of token to deposit as collateral
     * @param collateralAmount Amount of collateral tp deposit
     * @param amountDscToMint Amount of stablecoins to mint
     * @notice This function deposits collateral and mints DSC for user in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 amountDscToMint
    ) public {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDsc(amountDscToMint);
    }

    // Health factor must be over 1 after collateral pulled
    /**
     *
     * @param tokenCollateralAddress Collateral address to redeem
     * @param amountCollateral Amount to redeem
     * @param amountDscToBurn Amount of DSC to burn
     * This function burns DSC and redeems collateral in one transaction
     */
    function redeemCollateralDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 collateralAmount
    ) public moreThanZero(collateralAmount) nonReentrant {
        _redeemCollateral(
            msg.sender,
            msg.sender,
            tokenCollateralAddress,
            collateralAmount
        );
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @notice follows CEI (checks, effects, interactions)
     * @param amountDscToMint amount of DSC to mint
     * @notice they must have more collateral than minimum threshold
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param collateral ther erc20 collateral address to liquidate
     * @param user user with healthfactor below min healthfactor
     * @param debtToCover Amount of dsc to burn to improve users health factor
     * @notice You can partailly liquidate a user and get a liquidation bonus
     * @notice This function assumes protocol is overcollateralized roughly(200%) for this to work
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalColateralToRedeem = tokenAmountFromDebtCovered +
            bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalColateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //Private & Internal View Functions

    function _getAccountInfo(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     *
     * @param user user to check
     * @return How close a user is to liqiudation (below 1 means user can be liquidated)
     */
    function _healthFactor(address user) private view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInfo(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactorWith(userHealthFactor);
        }
    }

    function _redeemCollateral(
        address from,
        address to,
        address tokenCollateralAddress,
        uint256 collateralAmount
    ) private moreThanZero(collateralAmount) nonReentrant {
        s_collateralDeposited[from][tokenCollateralAddress] -= collateralAmount;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            collateralAmount
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            collateralAmount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *  @dev lov level internal funcyion should not be called unless function calling it
     * is checking for health factors being broken
     */
    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedThreshold * PRECISION) / totalDscMinted;
    }

    //Public & External View Functions

    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        //returns answer * 1e8 (100000000)
        return
            (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInfo(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInfo(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
