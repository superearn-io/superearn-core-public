// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

interface ISuperEarnRouter {
    // ============================================
    // STRUCTS
    // ============================================

    struct VaultLockup {
        bool depositBlocked;
        uint64 depositDeadline;
        bool redeemBlocked;
        uint64 redeemDeadline;
    }

    // ============================================
    // EVENTS
    // ============================================

    /**
     * @notice Emitted when underlying tokens are deposited through the router
     * @param sender Address that initiated the deposit
     * @param receiver Address that received the yVault shares
     * @param yVault Address of the Yearn vault
     * @param underlyingAmount Amount of underlying tokens deposited
     * @param yShares Amount of yVault shares minted
     */
    event Deposited(
        address indexed sender,
        address indexed receiver,
        address indexed yVault,
        uint256 underlyingAmount,
        uint256 yShares
    );

    /**
     * @notice Emitted when underlying tokens are deposited through the router with referral
     * @param sender Address that initiated the deposit
     * @param receiver Address that received the yVault shares
     * @param yVault Address of the Yearn vault
     * @param underlyingAmount Amount of underlying tokens deposited
     * @param yShares Amount of yVault shares minted
     * @param referralCode Referral code for tracking
     */
    event DepositedWithReferral(
        address sender,
        address indexed receiver,
        address indexed yVault,
        uint256 underlyingAmount,
        uint256 yShares,
        bytes32 indexed referralCode
    );

    /**
     * @notice Emitted when yVault shares are redeemed through the router
     * @param sender Address that initiated the redemption
     * @param receiver Address that will receive the underlying assets after cooldown
     * @param yVault Address of the Yearn vault
     * @param yShares Amount of yVault shares redeemed
     * @param requestId ID of the cooldown redemption request
     * @param underlyingAmount Amount of underlying tokens to be received after cooldown
     */
    event Redeemed(
        address indexed sender,
        address indexed receiver,
        address indexed yVault,
        uint256 yShares,
        uint256 ySharesFilled,
        uint256 requestId,
        uint256 underlyingAmount
    );

    event RemoteVaultSet(address indexed remoteVault);

    /**
     * @notice Emitted when a yVault whitelist status is changed
     * @param yVault Address of the yVault
     * @param whitelisted True if whitelisted, false if removed
     */
    event VaultWhitelisted(address indexed yVault, bool whitelisted);

    event DepositLockupSet(address indexed yVault, bool blocked, uint64 deadline);
    event RedeemLockupSet(address indexed yVault, bool blocked, uint64 deadline);

    // ============================================
    // FUNCTIONS
    // ============================================

    function registry() external view returns (address);

    function remoteVault() external view returns (address);

    // Deposit functions (overloaded)
    function deposit(address yVault, uint256 amount, uint256 minSharesOut) external returns (uint256);

    function deposit(
        address yVault,
        uint256 amount,
        address receiver,
        uint256 minSharesOut
    )
        external
        returns (uint256);

    function depositWithPermit(
        address yVault,
        uint256 amount,
        address receiver,
        uint256 minSharesOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        returns (uint256);

    function depositWithReferral(
        address yVault,
        uint256 amount,
        uint256 minSharesOut,
        bytes32 referralCode
    )
        external
        returns (uint256);

    function depositWithPermitAndReferral(
        address yVault,
        uint256 amount,
        address receiver,
        uint256 minSharesOut,
        bytes32 referralCode,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    )
        external
        returns (uint256);

    // Redeem functions (overloaded)
    function previewDeposit(address yVault, uint256 amount) external view returns (uint256);

    function previewMint(address yVault, uint256 yShares) external view returns (uint256 underlyingAssets);

    function previewRedeem(address yVault, uint256 yShares) external view returns (uint256);

    function previewWithdraw(address yVault, uint256 assets) external view returns (uint256 ySharesNeeded);

    function redeem(address yVault, uint256 yShares, uint256 minAssetsOut) external returns (uint256 requestId);

    function redeem(
        address yVault,
        uint256 yShares,
        address receiver,
        uint256 minAssetsOut
    )
        external
        returns (uint256 requestId);

    function endorsedVault(address token) external view returns (address);

    function setRemoteVault(address _remoteVault) external;

    function whitelistedVaults(address yVault) external view returns (bool);

    function addWhitelistedVault(address yVault) external;

    function removeWhitelistedVault(address yVault) external;

    function vaultLockups(address yVault)
        external
        view
        returns (bool depositBlocked, uint64 depositDeadline, bool redeemBlocked, uint64 redeemDeadline);

    function setDepositLockup(address yVault, bool blocked, uint64 deadline) external;

    function setRedeemLockup(address yVault, bool blocked, uint64 deadline) external;
}
