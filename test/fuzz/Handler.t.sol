// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 public timesMintIsCalled;
    address[] public usersWithDeposits;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;
        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethUsdPriceFeed = MockV3Aggregator(
            dsce.getCollateralTokenPriceFeed(address(weth))
        );
    }

    function mintDSC(uint256 amount, uint256 addressSeed) public {
        //random msg.sender casues error
        if (usersWithDeposits.length == 0) {
            return;
        }
        address sender = usersWithDeposits[
            addressSeed % usersWithDeposits.length
        ];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInfo(sender);
        int256 maxDscToMint = ((int256(collateralValueInUsd) / 2)) -
            int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    //breaks system
    //function updateCollateralPrice(uint96 newPrice) public {
    //   int256 newPriceInt = int256(uint256(newPrice));
    //    ethUsdPriceFeed.updateAnswer(newPriceInt);
    //}

    //randomized during test
    function depositCollateral(
        uint256 collateralSeed,
        uint256 amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        //repeated push of same address
        usersWithDeposits.push(msg.sender);
    }

    function _getCollateralFromSeed(
        uint256 collateralSeed
    ) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function redeemCollateral(
        uint256 _collateralSeed,
        uint256 _amountCollateral
    ) public {
        ERC20Mock collateral = _getCollateralFromSeed(_collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(
            msg.sender,
            address(collateral)
        );
        uint256 amountCollateral = bound(
            _amountCollateral,
            0,
            maxCollateralToRedeem
        );
        if (amountCollateral <= 0) {
            return;
            //or vm.assume
        }
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }
}
