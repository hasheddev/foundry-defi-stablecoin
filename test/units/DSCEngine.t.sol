// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    address public USER = makeAddr("user");
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, , ) = helperConfig
            .activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        vm.deal(USER, STARTING_ERC20_BALANCE);
    }

    //Constructor Tests
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsifTokenAndPriceFeedLengthDoNotMatch() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressMustMatchPriceFeedAdressInLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //Price Test
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000 dollar/eth = 30000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    //Deposit Collateral Test
    function testRevertsIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(
            DSCEngine.DSCEngine__AmountMustBeGreaterThanZero.selector
        );
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock mockToken = new ERC20Mock(
            "Random",
            "RAN",
            USER,
            STARTING_ERC20_BALANCE
        );
        vm.startPrank(USER);
        vm.expectRevert(
            DSCEngine.DSCEngine__CollateralTokenNotAllowed.selector
        );
        dscEngine.depositCollateral(address(mockToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanGetCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInfo(USER);
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assert(totalDscMinted == 0);
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralWithoutMinting()
        public
        depositedCollateral
    {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (amountCollateral *
                (uint256(price) * dscEngine.getAdditionalFeedPrecision())) /
            dscEngine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
            amountToMint,
            dscEngine.getUsdValue(weth, amountCollateral)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactorWith.selector,
                expectedHealthFactor
            )
        );
        dscEngine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();
    }
}
