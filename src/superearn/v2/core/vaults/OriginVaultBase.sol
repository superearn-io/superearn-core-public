// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IERC20MetadataUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title OriginVaultBase
 * @notice Base implementation for OriginVault with async redemption support
 * @dev This contract provides the base functionality for async vaults with operator support.
 *      Note: This is NOT ERC-7540 compliant as redeem() uses requestId instead of shares.
 *      The async redemption flow (requestRedeem -> fulfill -> claim) is custom.
 */
abstract contract OriginVaultBase is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using Math for uint256;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // === Errors ===
    error CannotSetSelfAsOperator();
    error DepositMoreThanMax();
    error ZeroSharesMinted();
    error InvalidOwner();

    /// @dev Assume requests are non-fungible and all have ID = 0
    uint256 internal constant REQUEST_ID = 0;

    /// @notice The underlying asset of the vault
    address public asset;

    /// @notice Share token address (always this contract for simplicity)
    address public share;

    /// @notice Decimals offset for share/asset conversion
    uint8 internal _decimalsOffset;

    /// @notice Mapping of controller to operator approval status
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice Mapping for signature-based authorizations
    mapping(address controller => mapping(bytes32 nonce => bool used)) public authorizations;

    // === Events ===

    /**
     * @dev Emitted when an operator is set or removed
     */
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /**
     * @dev Emitted when assets are deposited
     */
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);

    /**
     * @dev Emitted when assets are withdrawn
     */
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    /**
     * @dev Emitted when a redeem request is made
     */
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );

    /**
     * @notice Initialize the OriginVaultBase
     * @param _asset Address of the underlying asset
     * @param _name Name of the vault token
     * @param _symbol Symbol of the vault token
     * @param _owner Owner address for OwnableUpgradeable
     */
    function __OriginVaultBase_init(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _owner
    )
        internal
        onlyInitializing
    {
        __ERC20_init(_name, _symbol);
        __Ownable_init();
        __OriginVaultBase_init_unchained(_asset, _owner);
    }

    function __OriginVaultBase_init_unchained(address _asset, address _owner) internal onlyInitializing {
        if (_owner == address(0)) revert InvalidOwner();
        asset = _asset;
        share = address(this);

        uint8 assetDecimals = IERC20MetadataUpgradeable(_asset).decimals();
        _decimalsOffset = 18 > assetDecimals ? 18 - assetDecimals : 0;

        _transferOwnership(_owner);
    }

    /**
     * @notice Returns the decimals of the vault shares
     */
    function decimals() public view virtual override returns (uint8) {
        return IERC20MetadataUpgradeable(asset).decimals() + _decimalsOffset;
    }

    /**
     * @notice Returns the total amount of underlying assets held by the vault
     * @dev Must be overridden by implementing contracts
     */
    function totalAssets() public view virtual returns (uint256);

    /**
     * @notice Convert a given amount of assets to shares
     * @param assets Amount of assets to convert
     * @return shares Amount of shares
     */
    function convertToShares(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @notice Convert a given amount of shares to assets
     * @param shares Amount of shares to convert
     * @return assets Amount of assets
     */
    function convertToAssets(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @notice Maximum amount of assets that can be deposited
     * @return maxAssets Maximum deposit amount
     */
    function maxDeposit(address /* receiver */ ) public view virtual returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Preview the amount of shares for a deposit
     * @param assets Amount of assets to deposit
     * @return shares Amount of shares to be minted
     */
    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @notice Deposit assets and mint shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) public virtual returns (uint256 shares) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert DepositMoreThanMax();
        }

        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroSharesMinted();
        _deposit(msg.sender, receiver, assets, shares);

        return shares;
    }

    /**
     * @notice Preview the amount of assets for a mint
     * @param shares Amount of shares to mint
     * @return assets Amount of assets required
     */
    function previewMint(uint256 shares) public view virtual returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    /**
     * @notice Mint shares by depositing assets
     * @param shares Amount of shares to mint
     * @param receiver Address to receive the shares
     * @return assets Amount of assets deposited
     */
    function mint(uint256 shares, address receiver) public virtual returns (uint256 assets) {
        assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);

        return assets;
    }

    // === Operator Logic ===

    /**
     * @notice Set or remove an operator for the caller
     * @param operator Address of the operator
     * @param approved Approval status
     * @return success Whether the operation was successful
     */
    function setOperator(address operator, bool approved) public virtual returns (bool success) {
        if (msg.sender == operator) revert CannotSetSelfAsOperator();
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // === Async Redemption Interface (Abstract) ===

    /**
     * @notice Request redemption of shares
     * @dev Must be implemented by inheriting contracts
     */
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    )
        external
        virtual
        returns (uint256 requestId);

    /**
     * @notice Get claimable redeem request amount
     * @dev Must be implemented by inheriting contracts
     */
    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    )
        external
        view
        virtual
        returns (uint256 claimableShares);

    // === Internal Functions ===

    /**
     * @dev Internal conversion from assets to shares with rounding
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset, totalAssets() + 1, rounding);
    }

    /**
     * @dev Internal conversion from shares to assets with rounding
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** _decimalsOffset, rounding);
    }

    /**
     * @dev Internal deposit logic
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual {
        IERC20Upgradeable(asset).safeTransferFrom(caller, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Storage usage: 5 slots
     *   - asset: 1 slot (address)
     *   - share: 1 slot (address)
     *   - _decimalsOffset: 1 slot (uint8, padded to 1 slot)
     *   - isOperator (mapping pointer): 1 slot
     *   - authorizations (mapping pointer): 1 slot
     * Gap = 50 - 5 = 45
     */
    uint256[45] private __gap;
}
