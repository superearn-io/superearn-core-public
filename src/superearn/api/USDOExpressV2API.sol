// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

/// @notice Minimal IUSDO interface for superearn usage
interface IUSDO {
    function sharesOf(address account) external view returns (uint256);
    function bonusMultiplier() external view returns (uint256);
}

struct USDOMintRedeemLimiterCfg {
    uint256 mintMinimum;
    uint256 mintLimit;
    uint256 mintDuration;
    uint256 redeemMinimum;
    uint256 redeemLimit;
    uint256 redeemDuration;
    uint256 firstDepositAmount;
}

enum TxType {
    MINT,
    REDEEM,
    INSTANT_REDEEM
}

interface IUSDOExpressV2 {
    // ============ Errors ============
    error USDOExpressTooEarly(uint256 amount);
    error USDOExpressZeroAddress();
    error USDOExpressTokenNotSupported(address token);
    error USDOExpressReceiveUSDCFailed(uint256 amount, uint256 received);
    error MintLessThanMinimum(uint256 amount, uint256 minimum);
    error TotalSupplyCapExceeded();
    error FirstDepositLessThanRequired(uint256 amount, uint256 minimum);
    error USDOExpressNotInKycList(address from, address to);
    error USDOExpressInvalidInput(uint256 input);
    error USDOExpressInsufficientLiquidity(uint256 required, uint256 available);
    error InsufficientOutput(uint256 received, uint256 minimum);
    // Limiter Errors
    error RedeemLessThanMinimum(uint256 amount, uint256 minimum);
    error MintLimitExceeded();
    error RedeemLimitExceeded();

    // ============ Events ============
    event UpdateAPY(uint256 apy, uint256 increment);
    event UpdateCusdo(address cusdo);
    event UpdateMintFeeRate(uint256 fee);
    event UpdateRedeemFeeRate(uint256 fee);
    event UpdateInstantRedeemFee(uint256 fee);
    event UpdateTreasury(address treasury);
    event UpdateFeeTo(address feeTo);
    event UpdateTimeBuffer(uint256 timeBuffer);
    event InstantMint(
        address indexed underlying,
        address indexed from,
        address indexed to,
        uint256 reqAmt,
        uint256 receiveAmt,
        uint256 fee
    );
    event InstantMintAndWrap(
        address indexed underlying,
        address indexed from,
        address indexed to,
        uint256 reqAmt,
        uint256 usdoAmt,
        uint256 cusdoAmt,
        uint256 fee
    );
    event USDOKycGranted(address[] addresses);
    event USDOKycRevoked(address[] addresses);
    event InstantRedeem(
        address indexed from,
        address indexed to,
        uint256 reqAmt,
        uint256 receiveAmt,
        uint256 fee,
        uint256 payout,
        uint256 usycFee,
        uint256 minUsdcOut
    );
    event ManualRedeem(address indexed from, uint256 reqAmt, uint256 receiveAmt, uint256 fee);
    event UpdateFirstDeposit(address indexed account, bool flag);
    event AddToRedemptionQueue(address indexed from, address indexed to, uint256 usdoAmt, bytes32 id);
    event ProcessRedeem(
        address indexed from, address indexed to, uint256 usdoAmt, uint256 usdcAmt, uint256 fee, bytes32 id
    );
    event ProcessRedemptionQueue(uint256 totalRedeemAssets, uint256 totalBurnUsdo, uint256 totalFees);
    event ProcessRedemptionCancel(address indexed from, address indexed to, uint256 usdoAmt, bytes32 id);
    event Cancel(uint256 len, uint256 totalUsdo);
    event SetRedemption(address redemptionContract);
    event AssetRegistryUpdated(address indexed newRegistry);
    event OffRamp(address indexed to, uint256 amount);
    // Pausable Events
    event PausedMint(address account);
    event PausedRedeem(address account);
    event UnpausedMint(address account);
    event UnpausedRedeem(address account);
    // Limiter Events
    event MintMinimumUpdated(uint256 newMinimum);
    event MintLimitUpdated(uint256 newLimit);
    event MintDurationUpdated(uint256 newDuration);
    event RdeemMinimumUpdated(uint256 newMinimum);
    event RedeemLimitUpdated(uint256 newLimit);
    event RedeemDurationUpdated(uint256 newDuration);
    event FirstDepositAmount(uint256 amount);

    // ============ Role Constants ============
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function MULTIPLIER_ROLE() external view returns (bytes32);
    function PAUSE_ROLE() external view returns (bytes32);
    function WHITELIST_ROLE() external view returns (bytes32);
    function UPGRADE_ROLE() external view returns (bytes32);
    function MAINTAINER_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE() external view returns (bytes32);

    // ============ State Variables ============
    function _apy() external view returns (uint256);
    function _mintFeeRate() external view returns (uint256);
    function _redeemFeeRate() external view returns (uint256);
    function _instantRedeemFeeRate() external view returns (uint256);
    function _increment() external view returns (uint256);
    function _lastUpdateTS() external view returns (uint256);
    function _timeBuffer() external view returns (uint256);
    function _usdo() external view returns (IUSDO);
    function _usdc() external view returns (address);
    function RESERVE1() external view returns (address);
    function _treasury() external view returns (address);
    function _feeTo() external view returns (address);
    function _assetRegistry() external view returns (address);
    function _redemptionContract() external view returns (address);
    function _cusdo() external view returns (address);
    function _firstDeposit(address account) external view returns (bool);
    function _kycList(address account) external view returns (bool);

    // ============ Limiter State Variables (from USDOMintRedeemLimiter) ============
    function _RESERVE2() external view returns (uint256);
    function _mintMinimum() external view returns (uint256);
    function _mintLimit() external view returns (uint256);
    function _mintDuration() external view returns (uint256);
    function _mintResetTime() external view returns (uint256);
    function _mintedAmount() external view returns (uint256);
    function _redeemMinimum() external view returns (uint256);
    function _redeemLimit() external view returns (uint256);
    function _redeemDuration() external view returns (uint256);
    function _redeemResetTime() external view returns (uint256);
    function _redeemedAmount() external view returns (uint256);
    function _firstDepositAmount() external view returns (uint256);

    // ============ Pausable State Variables ============
    function pausedMint() external view returns (bool);
    function pausedRedeem() external view returns (bool);

    // ============ Initialization ============
    function initialize(
        address usdo,
        address cusdo,
        address usdc,
        address treasury,
        address feeTo,
        address maintainer,
        address operator,
        address admin,
        address assetRegistry,
        USDOMintRedeemLimiterCfg memory cfg
    )
        external;

    // ============ Core Functions ============
    function instantMint(address underlying, address to, uint256 amt) external;
    function instantMintAndWrap(address underlying, address to, uint256 amt) external;
    function instantRedeemSelf(address to, uint256 amt, uint256 minUsdcOut) external;
    function redeemRequest(address to, uint256 amt) external;
    function redeem(uint256 amt) external;

    // ============ Queue Management ============
    function cancel(uint256 _len) external;
    function processRedemptionQueue(uint256 _len) external;
    function getRedemptionQueueInfo(uint256 _index)
        external
        view
        returns (address sender, address receiver, uint256 usdoAmt, bytes32 id);
    function getRedemptionUserInfo(address _user) external view returns (uint256 usdoAmt);
    function getRedemptionQueueLength() external view returns (uint256);

    // ============ View/Preview Functions ============
    function convertFromUnderlying(address token, uint256 amt) external view returns (uint256 usdoAmt);
    function convertToUnderlying(address token, uint256 usdoAmt) external view returns (uint256 amt);
    function txsFee(uint256 amt, TxType txType) external view returns (uint256 fee);
    function previewIssuance(uint256 usdoAmt) external view returns (uint256 usdoAmtCurr, uint256 usdoAmtNext);
    function getBonusMultiplier() external view returns (uint256 curr, uint256 next);
    function previewMint(
        address underlying,
        uint256 amt
    )
        external
        view
        returns (uint256 netAmt, uint256 fee, uint256 usdoAmtCurr, uint256 usdoAmtNext);
    function previewRedeem(
        uint256 amt,
        bool isInstant
    )
        external
        view
        returns (uint256 feeAmt, uint256 usdcAmt, uint256 extraFee);
    function getTokenBalance(address token) external view returns (uint256 assetAmt);

    // ============ APY & Multiplier Management ============
    function updateAPY(uint256 newAPY) external;
    function addBonusMultiplier() external;
    function updateTimeBuffer(uint256 timeBuffer) external;

    // ============ Fee Management ============
    function updateMintFee(uint256 fee) external;
    function updateRedeemFee(uint256 fee) external;
    function updateInstantRedeemFee(uint256 fee) external;

    // ============ Address Management ============
    function updateCusdo(address cusdo) external;
    function setAssetRegistry(address newRegistry) external;
    function setRedemption(address redemptionContract) external;
    function updateTreasury(address treasury) external;
    function updateFeeTo(address feeTo) external;
    function updateFirstDeposit(address account, bool flag) external;

    // ============ Limit Configuration ============
    function setMintMinimum(uint256 mintMinimum) external;
    function setMintDuration(uint256 mintDuration) external;
    function setMintLimit(uint256 mintLimit) external;
    function setRedeemMinimum(uint256 redeemMinimum) external;
    function setRedeemDuration(uint256 redeemDuration) external;
    function setRedeemLimit(uint256 redeemLimit) external;
    function setFirstDepositAmount(uint256 amount) external;

    // ============ Pause Management ============
    function pauseMint() external;
    function unpauseMint() external;
    function pauseRedeem() external;
    function unpauseRedeem() external;

    // ============ KYC Management ============
    function grantKycInBulk(address[] calldata _addresses) external;
    function revokeKycInBulk(address[] calldata _addresses) external;

    // ============ Operator Functions ============
    function offRamp(uint256 amt) external;

    // ============ Access Control (inherited from AccessControlUpgradeable) ============
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;

    // ============ UUPS Upgrade (inherited from UUPSUpgradeable) ============
    function proxiableUUID() external view returns (bytes32);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;

    // ============ ERC165 ============
    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    // ============ Total Supply Cap ============
    function _totalSupplyCap() external view returns (uint256);
}

// Type alias for backwards compatibility
interface USDOExpressV2API is IUSDOExpressV2 { }
