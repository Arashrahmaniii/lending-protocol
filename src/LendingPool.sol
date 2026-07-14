// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "./libraries/DataTypes.sol";
import {WadRayMath} from "./libraries/WadRayMath.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IInterestRateStrategy} from "./interfaces/IInterestRateStrategy.sol";
import {IFlashLoanReceiver} from "./interfaces/IFlashLoanReceiver.sol";
import {IScaledToken} from "./interfaces/IScaledToken.sol";
import {AToken} from "./tokens/AToken.sol";
import {VariableDebtToken} from "./tokens/VariableDebtToken.sol";

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external returns (bool);
}

/**
 * @title LendingPool
 * @notice Core of an Aave-style, over-collateralised, multi-asset money market.
 *         Handles deposits, withdrawals, variable-rate borrowing (with credit
 *         delegation), repayment, flash loans and liquidation of unhealthy
 *         positions. Interest is tracked with scaled-balance tokens and
 *         cumulative RAY indexes.
 *
 * @dev Security model:
 *      - every state-mutating entry point is reentrancy-guarded and pausable
 *      - aToken/debtToken mint & burn are pool-only
 *      - reserve risk parameters are validated on initialisation and update
 *      - collateral cannot leave a position (withdraw / aToken transfer /
 *        collateral toggle) unless the resulting health factor stays >= 1
 */
contract LendingPool is ILendingPool {
    using WadRayMath for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18; // WAD
    uint256 internal constant LIQUIDATION_CLOSE_FACTOR = 5_000; // 50% in bps
    uint256 public constant FLASHLOAN_PREMIUM_BPS = 9; // 0.09%
    uint256 internal constant MAX_RESERVES = 128;

    // Every odd bit of the user config bitmap is a "borrowing" bit.
    uint256 internal constant BORROWING_MASK =
        0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;

    address public immutable admin;
    address public immutable treasury;
    address public emergencyAdmin;
    IPriceOracle public oracle;
    bool public paused;

    mapping(address => DataTypes.ReserveData) internal _reserves;
    mapping(address => uint256) internal _userConfig; // packed collateral/borrow bits
    address[] internal _reservesList;

    uint256 private _locked = 1;

    // --------------------------------------------------------------------- //
    //                                Events                                 //
    // --------------------------------------------------------------------- //
    event ReserveInitialized(address indexed asset, address aToken, address debtToken);
    event ReserveConfigUpdated(address indexed asset);
    event ReserveDataUpdated(
        address indexed asset,
        uint256 liquidityRate,
        uint256 variableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex
    );
    event Deposit(address indexed asset, address indexed user, address indexed onBehalfOf, uint256 amount);
    event Withdraw(address indexed asset, address indexed user, address indexed to, uint256 amount);
    event Borrow(address indexed asset, address indexed user, address indexed onBehalfOf, uint256 amount);
    event Repay(address indexed asset, address indexed user, address indexed onBehalfOf, uint256 amount);
    event FlashLoan(
        address indexed receiver, address indexed initiator, address indexed asset, uint256 amount, uint256 premium
    );
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed user,
        uint256 debtCovered,
        uint256 collateralSeized,
        address liquidator,
        bool receiveAToken
    );
    event ReserveUsedAsCollateralEnabled(address indexed asset, address indexed user);
    event ReserveUsedAsCollateralDisabled(address indexed asset, address indexed user);
    event PausedSet(bool paused);
    event OracleUpdated(address indexed oracle);
    event EmergencyAdminUpdated(address indexed emergencyAdmin);
    event MintedToTreasury(address indexed asset, uint256 amount);

    // --------------------------------------------------------------------- //
    //                              Modifiers                                //
    // --------------------------------------------------------------------- //

    modifier nonReentrant() {
        require(_locked == 1, "Pool: reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "Pool: paused");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Pool: not admin");
        _;
    }

    constructor(address _oracle, address _treasury) {
        require(_oracle != address(0) && _treasury != address(0), "Pool: zero address");
        admin = msg.sender;
        emergencyAdmin = msg.sender;
        oracle = IPriceOracle(_oracle);
        treasury = _treasury;
    }

    // --------------------------------------------------------------------- //
    //                            Administration                             //
    // --------------------------------------------------------------------- //

    function setOracle(address _oracle) external onlyAdmin {
        require(_oracle != address(0), "Pool: zero address");
        oracle = IPriceOracle(_oracle);
        emit OracleUpdated(_oracle);
    }

    function setEmergencyAdmin(address _emergencyAdmin) external onlyAdmin {
        require(_emergencyAdmin != address(0), "Pool: zero address");
        emergencyAdmin = _emergencyAdmin;
        emit EmergencyAdminUpdated(_emergencyAdmin);
    }

    /// @notice Circuit breaker. Halts all user-facing actions.
    function setPaused(bool value) external {
        require(msg.sender == emergencyAdmin || msg.sender == admin, "Pool: not authorized");
        paused = value;
        emit PausedSet(value);
    }

    function initReserve(
        address asset,
        DataTypes.ReserveConfig calldata config,
        address interestRateStrategy,
        string calldata assetSymbol
    ) external onlyAdmin returns (address aTokenAddr, address debtTokenAddr) {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(asset != address(0) && interestRateStrategy != address(0), "Pool: zero address");
        require(r.aTokenAddress == address(0), "Pool: reserve exists");
        require(_reservesList.length < MAX_RESERVES, "Pool: too many reserves");
        _validateReserveConfig(config);

        AToken aToken = new AToken(
            address(this),
            asset,
            string.concat("Lend Interest Bearing ", assetSymbol),
            string.concat("l", assetSymbol),
            config.decimals
        );
        VariableDebtToken debtToken = new VariableDebtToken(
            address(this),
            asset,
            string.concat("Lend Variable Debt ", assetSymbol),
            string.concat("d", assetSymbol),
            config.decimals
        );

        r.config = config;
        r.liquidityIndex = WadRayMath.RAY;
        r.variableBorrowIndex = WadRayMath.RAY;
        r.lastUpdateTimestamp = uint40(block.timestamp);
        r.aTokenAddress = address(aToken);
        r.variableDebtTokenAddress = address(debtToken);
        r.interestRateStrategy = interestRateStrategy;
        r.id = uint16(_reservesList.length);
        _reservesList.push(asset);

        emit ReserveInitialized(asset, address(aToken), address(debtToken));
        return (address(aToken), address(debtToken));
    }

    /// @notice Updates risk parameters of an existing reserve. Decimals are immutable.
    function updateReserveConfig(address asset, DataTypes.ReserveConfig calldata config)
        external
        onlyAdmin
    {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.aTokenAddress != address(0), "Pool: no reserve");
        require(config.decimals == r.config.decimals, "Pool: decimals immutable");
        _validateReserveConfig(config);
        r.config = config;
        emit ReserveConfigUpdated(asset);
    }

    function setInterestRateStrategy(address asset, address strategy) external onlyAdmin {
        require(strategy != address(0), "Pool: zero address");
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.aTokenAddress != address(0), "Pool: no reserve");
        _updateState(r);
        r.interestRateStrategy = strategy;
        _updateInterestRates(asset, r);
    }

    function _validateReserveConfig(DataTypes.ReserveConfig calldata config) internal pure {
        require(config.decimals >= 6 && config.decimals <= 18, "Pool: bad decimals");
        require(config.ltv <= config.liquidationThreshold, "Pool: ltv > threshold");
        require(config.liquidationThreshold <= BPS, "Pool: threshold > 100%");
        require(config.liquidationBonus > BPS, "Pool: bonus <= 100%");
        // A liquidation must never be able to leave the protocol with bad debt
        // by design: threshold * bonus must stay under 100%.
        require(
            (config.liquidationThreshold * config.liquidationBonus) / BPS <= BPS,
            "Pool: unsafe threshold/bonus"
        );
        require(config.reserveFactor < BPS, "Pool: bad reserve factor");
    }

    // --------------------------------------------------------------------- //
    //                             User actions                              //
    // --------------------------------------------------------------------- //

    function deposit(address asset, uint256 amount, address onBehalfOf)
        external
        nonReentrant
        whenNotPaused
    {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.config.isActive, "Pool: reserve inactive");
        require(!r.config.isFrozen, "Pool: reserve frozen");
        require(amount != 0, "Pool: zero amount");
        require(onBehalfOf != address(0), "Pool: zero address");

        _updateState(r);

        uint256 supplyCap = r.config.supplyCap;
        if (supplyCap != 0) {
            require(
                AToken(r.aTokenAddress).totalSupply() + amount <= supplyCap, "Pool: supply cap"
            );
        }

        require(
            IERC20Minimal(asset).transferFrom(msg.sender, r.aTokenAddress, amount),
            "Pool: transferFrom failed"
        );

        bool firstMint = AToken(r.aTokenAddress).mint(onBehalfOf, amount, r.liquidityIndex);
        if (firstMint && r.config.usableAsCollateral) {
            _setUsingAsCollateral(onBehalfOf, r.id, true);
            emit ReserveUsedAsCollateralEnabled(asset, onBehalfOf);
        }

        _updateInterestRates(asset, r);
        emit Deposit(asset, msg.sender, onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.config.isActive, "Pool: reserve inactive");
        require(to != address(0), "Pool: zero address");

        _updateState(r);

        uint256 userBalance = AToken(r.aTokenAddress).balanceOf(msg.sender);
        uint256 amountToWithdraw = amount == type(uint256).max ? userBalance : amount;
        require(amountToWithdraw != 0 && amountToWithdraw <= userBalance, "Pool: bad amount");

        AToken(r.aTokenAddress).burn(msg.sender, amountToWithdraw, r.liquidityIndex);

        if (AToken(r.aTokenAddress).scaledBalanceOf(msg.sender) == 0) {
            _setUsingAsCollateral(msg.sender, r.id, false);
            emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
        }

        AToken(r.aTokenAddress).transferUnderlyingTo(to, amountToWithdraw);
        _updateInterestRates(asset, r);

        // Only positions with open borrows need a health check.
        if (_isBorrowingAny(msg.sender)) {
            require(
                _healthFactorOf(msg.sender) >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "Pool: HF < 1"
            );
        }

        emit Withdraw(asset, msg.sender, to, amountToWithdraw);
        return amountToWithdraw;
    }

    /**
     * @notice Borrows `amount` of `asset` against `onBehalfOf`'s collateral.
     * @dev If `onBehalfOf != msg.sender`, the caller must have been approved via
     *      credit delegation (VariableDebtToken.approveDelegation). The borrowed
     *      funds are always sent to msg.sender.
     */
    function borrow(address asset, uint256 amount, address onBehalfOf)
        external
        nonReentrant
        whenNotPaused
    {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.config.isActive, "Pool: reserve inactive");
        require(!r.config.isFrozen, "Pool: reserve frozen");
        require(r.config.borrowingEnabled, "Pool: borrowing disabled");
        require(amount != 0, "Pool: zero amount");

        _updateState(r);

        // SECURITY: without this check anyone could mint debt against another
        // user's collateral. Borrowing on behalf of someone else requires an
        // explicit credit delegation allowance.
        if (onBehalfOf != msg.sender) {
            VariableDebtToken(r.variableDebtTokenAddress).decreaseBorrowAllowance(
                onBehalfOf, msg.sender, amount
            );
        }

        uint256 borrowCap = r.config.borrowCap;
        if (borrowCap != 0) {
            require(
                VariableDebtToken(r.variableDebtTokenAddress).totalSupply() + amount <= borrowCap,
                "Pool: borrow cap"
            );
        }

        (,, uint256 availableBorrowsBase,,,) = getUserAccountData(onBehalfOf);
        uint256 amountBase = _toBase(asset, amount, r.config.decimals);
        require(amountBase <= availableBorrowsBase, "Pool: insufficient collateral");

        VariableDebtToken(r.variableDebtTokenAddress).mint(onBehalfOf, amount, r.variableBorrowIndex);
        _setBorrowing(onBehalfOf, r.id, true);

        AToken(r.aTokenAddress).transferUnderlyingTo(msg.sender, amount);
        _updateInterestRates(asset, r);

        emit Borrow(asset, msg.sender, onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, address onBehalfOf)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.config.isActive, "Pool: reserve inactive");

        _updateState(r);

        uint256 debt = VariableDebtToken(r.variableDebtTokenAddress).balanceOf(onBehalfOf);
        uint256 paybackAmount = amount == type(uint256).max ? debt : amount;
        require(paybackAmount != 0 && paybackAmount <= debt, "Pool: bad amount");

        VariableDebtToken(r.variableDebtTokenAddress).burn(onBehalfOf, paybackAmount, r.variableBorrowIndex);

        if (VariableDebtToken(r.variableDebtTokenAddress).scaledBalanceOf(onBehalfOf) == 0) {
            _setBorrowing(onBehalfOf, r.id, false);
        }

        require(
            IERC20Minimal(asset).transferFrom(msg.sender, r.aTokenAddress, paybackAmount),
            "Pool: transferFrom failed"
        );

        _updateInterestRates(asset, r);
        emit Repay(asset, msg.sender, onBehalfOf, paybackAmount);
        return paybackAmount;
    }

    /// @notice Enables/disables a deposited reserve as collateral for msg.sender.
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral)
        external
        nonReentrant
        whenNotPaused
    {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.config.isActive, "Pool: reserve inactive");
        require(
            AToken(r.aTokenAddress).scaledBalanceOf(msg.sender) != 0, "Pool: no deposit"
        );
        if (useAsCollateral) {
            require(r.config.usableAsCollateral, "Pool: not collateralizable");
            _setUsingAsCollateral(msg.sender, r.id, true);
            emit ReserveUsedAsCollateralEnabled(asset, msg.sender);
        } else {
            _setUsingAsCollateral(msg.sender, r.id, false);
            if (_isBorrowingAny(msg.sender)) {
                require(
                    _healthFactorOf(msg.sender) >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
                    "Pool: HF < 1"
                );
            }
            emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
        }
    }

    // --------------------------------------------------------------------- //
    //                              Flash loans                              //
    // --------------------------------------------------------------------- //

    /**
     * @notice Uncollateralised loan that must be repaid (plus a premium) within
     *         the same transaction. The premium is accrued to depositors by
     *         cumulating it into the liquidity index.
     * @dev The receiver must implement IFlashLoanReceiver and approve the pool
     *      for `amount + premium` before returning. Reentrancy into the pool is
     *      deliberately blocked during the callback (conservative design).
     */
    function flashLoan(address receiver, address asset, uint256 amount, bytes calldata params)
        external
        nonReentrant
        whenNotPaused
    {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.config.isActive, "Pool: reserve inactive");
        require(amount != 0, "Pool: zero amount");

        _updateState(r);

        uint256 premium = (amount * FLASHLOAN_PREMIUM_BPS) / BPS;

        AToken(r.aTokenAddress).transferUnderlyingTo(receiver, amount);

        require(
            IFlashLoanReceiver(receiver).executeOperation(asset, amount, premium, msg.sender, params),
            "Pool: flashloan callback failed"
        );

        require(
            IERC20Minimal(asset).transferFrom(receiver, r.aTokenAddress, amount + premium),
            "Pool: flashloan repay failed"
        );

        // Distribute the premium to suppliers pro-rata via the liquidity index.
        uint256 scaledSupply = AToken(r.aTokenAddress).scaledTotalSupply();
        if (premium != 0 && scaledSupply != 0) {
            uint256 totalLiquidity = scaledSupply.rayMul(r.liquidityIndex);
            r.liquidityIndex =
                r.liquidityIndex.rayMul(WadRayMath.RAY + (premium * WadRayMath.RAY) / totalLiquidity);
        }

        _updateInterestRates(asset, r);
        emit FlashLoan(receiver, msg.sender, asset, amount, premium);
    }

    // --------------------------------------------------------------------- //
    //                             Liquidation                               //
    // --------------------------------------------------------------------- //

    struct LiquidationVars {
        uint256 userDebt;
        uint256 maxDebtToLiquidate;
        uint256 actualDebtToCover;
        uint256 collateralToSeize;
        uint256 userCollateralBalance;
        uint256 collateralPrice;
        uint256 debtPrice;
        uint8 collateralDecimals;
        uint8 debtDecimals;
    }

    /**
     * @notice Liquidates an unhealthy position (health factor < 1). The caller
     *         repays up to 50% (close factor) of the user's debt in `debtAsset`
     *         and receives collateral worth the repaid debt plus the liquidation
     *         bonus, either as aTokens or as the underlying asset.
     */
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external nonReentrant whenNotPaused {
        DataTypes.ReserveData storage collateralReserve = _reserves[collateralAsset];
        DataTypes.ReserveData storage debtReserve = _reserves[debtAsset];
        require(collateralReserve.config.isActive && debtReserve.config.isActive, "Pool: inactive");
        require(debtToCover != 0, "Pool: zero amount");

        _updateState(collateralReserve);
        _updateState(debtReserve);

        require(
            _healthFactorOf(user) < HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "Pool: position healthy"
        );

        LiquidationVars memory v;
        v.userDebt = VariableDebtToken(debtReserve.variableDebtTokenAddress).balanceOf(user);
        require(v.userDebt != 0, "Pool: no debt");
        require(_isUsingAsCollateral(user, collateralReserve.id), "Pool: not collateral");

        // A liquidator may repay at most `closeFactor` of the user's debt in one call.
        v.maxDebtToLiquidate = (v.userDebt * LIQUIDATION_CLOSE_FACTOR) / BPS;
        v.actualDebtToCover = debtToCover > v.maxDebtToLiquidate ? v.maxDebtToLiquidate : debtToCover;

        v.collateralPrice = oracle.getAssetPrice(collateralAsset);
        v.debtPrice = oracle.getAssetPrice(debtAsset);
        v.collateralDecimals = collateralReserve.config.decimals;
        v.debtDecimals = debtReserve.config.decimals;
        v.userCollateralBalance = AToken(collateralReserve.aTokenAddress).balanceOf(user);

        (v.collateralToSeize, v.actualDebtToCover) = _calculateSeizeAmount(collateralReserve, v);

        // Burn the covered debt and pull the repayment from the liquidator.
        VariableDebtToken(debtReserve.variableDebtTokenAddress).burn(
            user, v.actualDebtToCover, debtReserve.variableBorrowIndex
        );
        if (VariableDebtToken(debtReserve.variableDebtTokenAddress).scaledBalanceOf(user) == 0) {
            _setBorrowing(user, debtReserve.id, false);
        }
        require(
            IERC20Minimal(debtAsset).transferFrom(
                msg.sender, debtReserve.aTokenAddress, v.actualDebtToCover
            ),
            "Pool: repay transfer failed"
        );
        _updateInterestRates(debtAsset, debtReserve);

        // Seize the collateral for the liquidator (as aTokens or underlying).
        uint256 cIndex = collateralReserve.liquidityIndex;
        if (receiveAToken) {
            bool liquidatorFirst =
                AToken(collateralReserve.aTokenAddress).scaledBalanceOf(msg.sender) == 0;
            AToken(collateralReserve.aTokenAddress).transferOnLiquidation(
                user, msg.sender, v.collateralToSeize, cIndex
            );
            if (liquidatorFirst && collateralReserve.config.usableAsCollateral) {
                _setUsingAsCollateral(msg.sender, collateralReserve.id, true);
                emit ReserveUsedAsCollateralEnabled(collateralAsset, msg.sender);
            }
        } else {
            AToken(collateralReserve.aTokenAddress).burn(user, v.collateralToSeize, cIndex);
            AToken(collateralReserve.aTokenAddress).transferUnderlyingTo(msg.sender, v.collateralToSeize);
            _updateInterestRates(collateralAsset, collateralReserve);
        }

        if (AToken(collateralReserve.aTokenAddress).scaledBalanceOf(user) == 0) {
            _setUsingAsCollateral(user, collateralReserve.id, false);
            emit ReserveUsedAsCollateralDisabled(collateralAsset, user);
        }

        emit LiquidationCall(
            collateralAsset,
            debtAsset,
            user,
            v.actualDebtToCover,
            v.collateralToSeize,
            msg.sender,
            receiveAToken
        );
    }

    /// @dev Converts the debt-to-cover into a collateral amount including the
    ///      liquidation bonus, capping at the user's collateral and scaling the
    ///      covered debt back down if the collateral is the binding constraint.
    function _calculateSeizeAmount(
        DataTypes.ReserveData storage collateralReserve,
        LiquidationVars memory v
    ) internal view returns (uint256 collateralAmount, uint256 debtToCover) {
        uint256 debtValueBase = _toBase(v.debtPrice, v.actualDebtToCover, v.debtDecimals);
        uint256 bonusValueBase = (debtValueBase * collateralReserve.config.liquidationBonus) / BPS;

        // collateralAmount = bonusValueBase / collateralPrice, adjusting decimals
        uint256 maxCollateral = (bonusValueBase * (10 ** v.collateralDecimals)) / v.collateralPrice;

        if (maxCollateral > v.userCollateralBalance) {
            collateralAmount = v.userCollateralBalance;
            // Recompute the debt actually covered for the seized collateral.
            uint256 seizedValueBase =
                (collateralAmount * v.collateralPrice) / (10 ** v.collateralDecimals);
            uint256 debtValueForSeized =
                (seizedValueBase * BPS) / collateralReserve.config.liquidationBonus;
            debtToCover = (debtValueForSeized * (10 ** v.debtDecimals)) / v.debtPrice;
        } else {
            collateralAmount = maxCollateral;
            debtToCover = v.actualDebtToCover;
        }
    }

    // --------------------------------------------------------------------- //
    //                          aToken transfer hook                         //
    // --------------------------------------------------------------------- //

    /// @inheritdoc ILendingPool
    function finalizeTransfer(
        address asset,
        address from,
        address to,
        uint256 fromScaledBefore,
        uint256 toScaledBefore
    ) external whenNotPaused {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(msg.sender == r.aTokenAddress, "Pool: not aToken");

        if (from != to) {
            if (AToken(r.aTokenAddress).scaledBalanceOf(from) == 0 && fromScaledBefore != 0) {
                _setUsingAsCollateral(from, r.id, false);
                emit ReserveUsedAsCollateralDisabled(asset, from);
            }
            if (toScaledBefore == 0 && r.config.usableAsCollateral) {
                _setUsingAsCollateral(to, r.id, true);
                emit ReserveUsedAsCollateralEnabled(asset, to);
            }
        }

        // The sender's position must remain healthy after moving collateral out.
        if (_isBorrowingAny(from)) {
            require(
                _healthFactorOf(from) >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "Pool: HF < 1"
            );
        }
    }

    // --------------------------------------------------------------------- //
    //                        Interest / index updates                       //
    // --------------------------------------------------------------------- //

    function _updateState(DataTypes.ReserveData storage r) internal {
        uint40 last = r.lastUpdateTimestamp;
        if (last == uint40(block.timestamp)) return;

        uint256 scaledDebt = IScaledToken(r.variableDebtTokenAddress).scaledTotalSupply();
        if (scaledDebt != 0) {
            uint256 prevBorrowIndex = r.variableBorrowIndex;
            uint256 prevLiquidityIndex = r.liquidityIndex;

            uint256 cumLiquidity = MathUtils.calculateLinearInterest(r.currentLiquidityRate, last);
            uint256 newLiquidityIndex = cumLiquidity.rayMul(prevLiquidityIndex);

            uint256 cumBorrow = MathUtils.calculateCompoundedInterest(r.currentVariableBorrowRate, last);
            uint256 newBorrowIndex = cumBorrow.rayMul(prevBorrowIndex);

            r.liquidityIndex = newLiquidityIndex;
            r.variableBorrowIndex = newBorrowIndex;

            // Accrue the protocol's cut of borrow interest to the treasury.
            uint256 reserveFactor = r.config.reserveFactor;
            if (reserveFactor != 0) {
                uint256 prevDebt = scaledDebt.rayMul(prevBorrowIndex);
                uint256 newDebt = scaledDebt.rayMul(newBorrowIndex);
                uint256 totalInterest = newDebt - prevDebt;
                uint256 amountToTreasury = (totalInterest * reserveFactor) / BPS;
                if (amountToTreasury != 0) {
                    r.accruedToTreasury += amountToTreasury.rayDiv(newLiquidityIndex);
                }
            }
        }
        r.lastUpdateTimestamp = uint40(block.timestamp);
    }

    function _updateInterestRates(address asset, DataTypes.ReserveData storage r) internal {
        uint256 availableLiquidity = IERC20Minimal(asset).balanceOf(r.aTokenAddress);
        uint256 totalDebt = VariableDebtToken(r.variableDebtTokenAddress).totalSupply();
        (uint256 liqRate, uint256 borrowRate) = IInterestRateStrategy(r.interestRateStrategy)
            .calculateInterestRates(availableLiquidity, totalDebt, r.config.reserveFactor);
        r.currentLiquidityRate = liqRate;
        r.currentVariableBorrowRate = borrowRate;
        emit ReserveDataUpdated(asset, liqRate, borrowRate, r.liquidityIndex, r.variableBorrowIndex);
    }

    /// @notice Mints the accrued protocol fees to the treasury as aTokens.
    function mintToTreasury(address asset) external nonReentrant {
        DataTypes.ReserveData storage r = _reserves[asset];
        require(r.aTokenAddress != address(0), "Pool: no reserve");
        _updateState(r);
        uint256 scaledAccrued = r.accruedToTreasury;
        if (scaledAccrued == 0) return;
        uint256 amount = scaledAccrued.rayMul(r.liquidityIndex);
        r.accruedToTreasury = 0;
        AToken(r.aTokenAddress).mint(treasury, amount, r.liquidityIndex);
        emit MintedToTreasury(asset, amount);
    }

    function getReserveNormalizedIncome(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage r = _reserves[asset];
        uint40 last = r.lastUpdateTimestamp;
        if (last == uint40(block.timestamp)) return r.liquidityIndex;
        return MathUtils.calculateLinearInterest(r.currentLiquidityRate, last).rayMul(r.liquidityIndex);
    }

    function getReserveNormalizedVariableDebt(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage r = _reserves[asset];
        uint40 last = r.lastUpdateTimestamp;
        if (last == uint40(block.timestamp)) return r.variableBorrowIndex;
        return MathUtils.calculateCompoundedInterest(r.currentVariableBorrowRate, last).rayMul(
            r.variableBorrowIndex
        );
    }

    // --------------------------------------------------------------------- //
    //                          Account / risk data                          //
    // --------------------------------------------------------------------- //

    function getUserAccountData(address user)
        public
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        uint256 avgLtvWeighted;
        uint256 avgThresholdWeighted;
        uint256 length = _reservesList.length;

        for (uint256 i = 0; i < length; i++) {
            address asset = _reservesList[i];
            DataTypes.ReserveData storage r = _reserves[asset];
            uint256 id = r.id;

            bool asCollateral = _isUsingAsCollateral(user, id);
            bool borrowing = _isBorrowing(user, id);
            if (!asCollateral && !borrowing) continue;

            uint256 price = oracle.getAssetPrice(asset);
            uint8 dec = r.config.decimals;

            if (asCollateral) {
                uint256 balance = AToken(r.aTokenAddress).balanceOf(user);
                uint256 valueBase = _toBase(price, balance, dec);
                totalCollateralBase += valueBase;
                avgLtvWeighted += valueBase * r.config.ltv;
                avgThresholdWeighted += valueBase * r.config.liquidationThreshold;
            }
            if (borrowing) {
                uint256 debt = VariableDebtToken(r.variableDebtTokenAddress).balanceOf(user);
                totalDebtBase += _toBase(price, debt, dec);
            }
        }

        if (totalCollateralBase != 0) {
            ltv = avgLtvWeighted / totalCollateralBase;
            currentLiquidationThreshold = avgThresholdWeighted / totalCollateralBase;
        }

        uint256 borrowingPower = (totalCollateralBase * ltv) / BPS;
        availableBorrowsBase = borrowingPower > totalDebtBase ? borrowingPower - totalDebtBase : 0;

        healthFactor = _calcHealthFactor(totalCollateralBase, currentLiquidationThreshold, totalDebtBase);
    }

    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory) {
        return _reserves[asset];
    }

    function getReservesList() external view returns (address[] memory) {
        return _reservesList;
    }

    function _healthFactorOf(address user) internal view returns (uint256) {
        (,,,,, uint256 healthFactor) = getUserAccountData(user);
        return healthFactor;
    }

    function _calcHealthFactor(uint256 collateralBase, uint256 liqThresholdBps, uint256 debtBase)
        internal
        pure
        returns (uint256)
    {
        if (debtBase == 0) return type(uint256).max;
        uint256 weightedCollateral = (collateralBase * liqThresholdBps) / BPS;
        return weightedCollateral.wadDiv(debtBase);
    }

    // --------------------------------------------------------------------- //
    //                               Helpers                                 //
    // --------------------------------------------------------------------- //

    /// @dev value in base currency (WAD) = amount * price / 10^decimals
    function _toBase(address asset, uint256 amount, uint8 decimals) internal view returns (uint256) {
        return (amount * oracle.getAssetPrice(asset)) / (10 ** decimals);
    }

    function _toBase(uint256 price, uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return (amount * price) / (10 ** decimals);
    }

    function _isUsingAsCollateral(address user, uint256 id) internal view returns (bool) {
        return (_userConfig[user] >> (id * 2)) & 1 != 0;
    }

    function _isBorrowing(address user, uint256 id) internal view returns (bool) {
        return (_userConfig[user] >> (id * 2 + 1)) & 1 != 0;
    }

    function _isBorrowingAny(address user) internal view returns (bool) {
        return _userConfig[user] & BORROWING_MASK != 0;
    }

    function _setUsingAsCollateral(address user, uint256 id, bool value) internal {
        uint256 bit = uint256(1) << (id * 2);
        if (value) _userConfig[user] |= bit;
        else _userConfig[user] &= ~bit;
    }

    function _setBorrowing(address user, uint256 id, bool value) internal {
        uint256 bit = uint256(1) << (id * 2 + 1);
        if (value) _userConfig[user] |= bit;
        else _userConfig[user] &= ~bit;
    }
}
