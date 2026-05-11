// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.29 <0.9.0;

import { OriginVaultBase } from "./OriginVaultBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { SuperEarnV2Protocol } from "../../messaging/SuperEarnV2Protocol.sol";
import { RunespearProtocol } from "../../messaging/runespear/RunespearProtocol.sol";
import { OraklAssetPriceConverter } from "../../periphery/OraklAssetPriceConverter.sol";
import { ICrosschainVault } from "../../interfaces/ICrosschainVault.sol";
import { IOriginVault } from "../../interfaces/IOriginVault.sol";
import { IRunespearAgent } from "../../interfaces/IRunespearAgent.sol";
import { SuperEarnAccessControl } from "../../base/SuperEarnAccessControl.sol";

/**
 * @title OriginVault
 * @notice ERC-7540 vault on Kaia (origin chain) that acts as an external yield source connected to a
 *         Yearn V2 vault via StrategyOriginVault strategy, hence the name "OriginVault".
 *
 * @dev Architecture Flow:
 *      Users → Yearn V2 Vault (Kaia)
 *                ↓ (strategy)
 *              StrategyOriginVault
 *                ↓ (deposits into)
 *              OriginVault (this contract)
 *                ↓ (crosschain messaging + bridge)
 *              RemoteVault (Ethereum)
 *                ↓ (yield generation)
 *              Yearn V2 Vaults (Ethereum)
 *
 *      - Implements asynchronous two-step redemption (request → fulfill → claim) in ERC-7540 form
 *      - Local USDT is coordinated with the Ethereum RemoteVault through the CrosschainAdapter/Agent
 *      - Only whitelisted shareholders may interact; this is an intentional guard against timing abuse to minimize
 *       attack surface
 */
contract OriginVault is
    Initializable,
    OriginVaultBase,
    IOriginVault,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    SuperEarnAccessControl
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============================================
    // Constants & Immutables
    // ============================================

    // Note: KEEPER_ROLE, GOVERNANCE_ROLE, MANAGEMENT_ROLE, and SYSTEM_CONTRACT_ROLE
    // are inherited from SuperEarnAccessControl

    /// @dev Legacy role name for backward compatibility in interfaces
    ///      Mapped to SYSTEM_CONTRACT_ROLE for actual access control
    ///      Used by IOriginVault interface and external contracts
    bytes32 public constant AGENT_ROLE = keccak256("SYSTEM_CONTRACT_ROLE");

    uint256 private constant BASIS_POINTS = 10_000;

    // ============================================
    // Events
    // ============================================

    event RemoteWithdrawalRequested(uint256 amount);
    event AssetsReceived(uint256 amount, bytes32 bridgeId, uint256 timestamp);
    event RedemptionFulfilled(address indexed controller, uint256 shares, uint256 assets);
    event RedemptionQueueProcessed(uint256 totalShares, uint256 estimatedAssets, uint256 requestCount);
    event BatchRedemptionsFulfilled(uint256 totalShares, uint256 totalAssets, uint256 fulfilledCount);
    event RedemptionQueueRemoteRequested(uint256 fromIndex, uint256 toIndex);
    event RedemptionQueueFulfilled(uint256 fromIndex, uint256 toIndex);
    event PriceFeedsUpdated(address feedProxy);
    event PriceConverterUpdated(address indexed priceConverter);
    event AgentUpdated(address indexed oldAgent, address indexed newAgent);
    event ShareholderWhitelisted(address indexed shareholder);
    event ShareholderRemovedFromWhitelist(address indexed shareholder);

    // ============================================
    // Role Reporting
    // ============================================

    function vaultRole() external pure override returns (VaultRole) {
        return VaultRole.Origin;
    }

    // ============================================
    // Errors
    // ============================================

    error InvalidAgent();
    error InsufficientIdleAssets();
    error SlippageExceeded(uint256 expected, uint256 actual);
    error InvalidInterval();
    error AgentNotConfigured();
    error Unauthorized();
    error ZeroMaxAmount();
    error NoRedemptionsToRequest();
    error NoRedemptionsFulfilled();
    error UnknownPredicate();
    error InsufficientBalance();
    error ZeroShares();
    error InvalidShares();
    error NoSupply();
    error InsufficientIdleAssetsForFulfillment();
    error InvalidCaller();
    error ZeroAssets();
    error ExceedsLockedAssets();
    error ExceedsLockedShares();
    error CannotRecoverVaultAsset();
    error CannotRecoverVaultShares();
    error InvalidRequestId();
    error AlreadyRedeemed();
    error InvalidRecipient();
    error InvalidController();
    error InsufficientETHBalance();
    error ETHTransferFailed();
    error MaxLossToleranceTooHigh();
    error InvalidToken();
    error InvalidFeedProxy();
    error InvalidPriceConverter();
    error AssetTypeMismatch();
    error InvalidSourceChain();
    error InvalidChainId();
    error PendingOperations(uint256 assetsInTransit);
    error ReservedRedemptionAccountingUnderflow(uint256 expected, uint256 available);
    error NotWhitelistedShareholder();

    // ============================================
    // State Variables
    // ============================================

    // Access Control - Whitelisted Shareholders
    /// @dev SECURITY: Only whitelisted addresses can deposit/mint shares
    ///      This prevents fulfillment timing arbitrage attacks
    ///      Typically contains StrategyOriginVault address(es)
    mapping(address => bool) public whitelistedShareholders;

    // Crosschain Communication
    /// @dev Agent abstracts chain-specific routing to the remote vault.
    IRunespearAgent public agent;

    // Price Feeds
    /// @dev Used to convert remote vault's asset reports to origin's USDT denomination
    address public feedProxy;
    /// @dev Price converter contract for Orakl price feeds
    OraklAssetPriceConverter public priceConverter;

    // ERC-7540 Async Redemption State
    /// @dev Two-phase redemption with rate locking at fulfillment (request → fulfill → claim).

    /// @notice Assets reserved for queued redemptions pending fulfillment
    /// @dev Only assets are tracked pre-fulfillment; share totals remain in queue/controller state
    uint256 public totalReservedRedemptionAssets;

    /// @notice Shares locked at fulfillment and awaiting claim
    /// @dev After fulfillment we track both shares (for proportional burn checks) and assets (for payout)
    uint256 public totalFulfilledRedemptionShares;

    /// @notice Assets locked during fulfillment and awaiting claim
    uint256 public totalFulfilledRedemptionAssets;

    uint256 private _nextRequestId;
    mapping(address => RedemptionRequest) public redemptionRequests;
    mapping(uint256 => uint256) public requestIdToQueueIndex;
    RedemptionQueueItem[] public redemptionQueue;

    /// @dev Queue processing indices track redemption lifecycle stages
    uint256 public queueRemoteRequestedIndex; // Items before this have been requested to remote vault
    uint256 public queueFulfilledIndex; // Items before this have assets locked and are claimable

    // ============================================
    // Structs
    // ============================================

    struct RedemptionRequest {
        uint256 pendingShares;
        uint256 lockedShares;
        uint256 lockedAssets; // Locked at fulfillment to prevent exchange rate changes
    }

    struct RedemptionQueueItem {
        uint256 requestId;
        address controller; // ERC-7540 controller (original requester)
        uint256 shares;
        uint256 requestedAssets;
        uint256 fulfilledAssets;
        uint256 timestamp;
        bool redeemed; // Flag to prevent double redemption
    }

    // ============================================
    // Constructor
    // ============================================

    /**
     * @notice Initialize the OriginVault
     * @param _usdt Address of the USDT token
     * @param _name Name of the vault token
     * @param _symbol Symbol of the vault token
     * @param _owner Owner address for OwnableUpgradeable and GOVERNANCE_ROLE
     */
    function initialize(address _usdt, string memory _name, string memory _symbol, address _owner) public initializer {
        __OriginVaultBase_init(_usdt, _name, _symbol, _owner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __SuperEarnAccessControl_init();

        // Grant GOVERNANCE_ROLE to owner
        _grantRole(GOVERNANCE_ROLE, _owner);

        _pause();
    }

    // ============================================
    // Configuration
    // ============================================

    /**
     * @notice Set the Runespear agent address
     * @param _agent New agent address
     * @dev Checks for pending bridge operations before allowing replacement
     *      Revokes approvals from old agent and grants to new agent
     */
    function setAgent(address _agent) external onlyGovernance {
        if (_agent == address(0)) revert InvalidAgent();

        // Store old agent for event and cleanup
        address oldAgent = address(agent);

        // Check for pending operations if old agent exists
        if (oldAgent != address(0)) {
            uint256 assetsInTransit = agent.getAssetsInTransit();
            if (assetsInTransit > 0) {
                revert PendingOperations(assetsInTransit);
            }

            // Revoke approvals from old agent
            IERC20(asset).forceApprove(oldAgent, 0);
        }

        // Set new agent
        agent = IRunespearAgent(_agent);

        // Grant approvals to new agent
        IERC20(asset).forceApprove(_agent, type(uint256).max);

        emit AgentUpdated(oldAgent, _agent);
    }

    function setFeedProxy(address _feedProxy) external onlyGovernance {
        if (_feedProxy == address(0)) revert InvalidFeedProxy();
        feedProxy = _feedProxy;
        emit PriceFeedsUpdated(_feedProxy);
    }

    function setPriceConverter(address _priceConverter) external onlyGovernance {
        if (_priceConverter == address(0)) revert InvalidPriceConverter();
        priceConverter = OraklAssetPriceConverter(_priceConverter);
        emit PriceConverterUpdated(_priceConverter);
    }

    function unpause() external onlyGovernance {
        if (address(agent) == address(0)) revert AgentNotConfigured();
        if (feedProxy == address(0)) revert InvalidFeedProxy();
        if (address(priceConverter) == address(0)) revert InvalidPriceConverter();
        _unpause();
    }

    function pause() external onlyGovernance {
        _pause();
    }

    /**
     * @notice Add address to shareholder whitelist
     * @param shareholder Address to whitelist (typically StrategyOriginVault)
     * @dev Only whitelisted shareholders can deposit/mint shares
     *      This prevents fulfillment timing arbitrage attacks
     */
    function whitelistShareholder(address shareholder) external onlyGovernance {
        if (shareholder == address(0)) revert InvalidOwner();
        whitelistedShareholders[shareholder] = true;
        emit ShareholderWhitelisted(shareholder);
    }

    /**
     * @notice Remove address from shareholder whitelist
     * @param shareholder Address to remove from whitelist
     */
    function removeShareholderFromWhitelist(address shareholder) external onlyGovernance {
        whitelistedShareholders[shareholder] = false;
        emit ShareholderRemovedFromWhitelist(shareholder);
    }

    // ============================================
    // View Functions - Asset Accounting
    // ============================================

    function totalAssets() public view override(OriginVaultBase, IOriginVault) returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 remoteVaultAssets = remoteAssets();
        uint256 pending = assetsInTransitToRemote();
        return balance + remoteVaultAssets + pending;
    }

    function availableIdleAssets() public view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 reserved = reservedAssets();
        uint256 localReserved = reserved > balance ? balance : reserved;
        return balance > localReserved ? balance - localReserved : 0;
    }

    /// @dev All accounting is in USDT; reserved assets stay in TVL because shares still exist.
    function reservedAssets() public view returns (uint256) {
        return totalReservedRedemptionAssets + totalFulfilledRedemptionAssets;
    }

    /**
     * @notice Returns the amount of assets that can be used to fulfill queued redemptions
     * @dev Excludes only already locked assets; pending remote requests remain available once bridge arrives
     */
    function fulfillmentEligibleAssets() public view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 locked = totalFulfilledRedemptionAssets;
        return balance > locked ? balance - locked : 0;
    }

    /// @dev Agent handles overlap prevention between outbound assets and the remote reports.
    function remoteAssets() public view returns (uint256) {
        if (address(agent) == address(0)) return 0;
        (uint256 remoteReportedAssets, uint8 remoteAssetDecimals) = agent.getTruePeerAssets();
        if (remoteReportedAssets == 0) return 0;
        return convertAssetToUsdt(remoteReportedAssets, remoteAssetDecimals);
    }

    function assetsInTransitToRemote() public view returns (uint256) {
        if (address(agent) == address(0)) return 0;
        return agent.getAssetsInTransit();
    }

    /// @dev "Asset" = remote asset; feed proxy and price converter must refer to the same asset kind
    function convertAssetToUsdt(uint256 assetAmount, uint8 assetDecimals) public view returns (uint256) {
        if (assetAmount == 0) return 0;
        if (feedProxy == address(0)) revert InvalidFeedProxy();
        if (address(priceConverter) == address(0)) revert InvalidPriceConverter();

        uint8 localAssetDecimals = IERC20Metadata(asset).decimals();
        uint256 normalizedAmount = assetDecimals == localAssetDecimals
            ? assetAmount
            : Math.mulDiv(assetAmount, 10 ** localAssetDecimals, 10 ** assetDecimals);

        (uint256 price, uint8 decimals) = priceConverter.getLatestData(feedProxy);
        return normalizedAmount * price / (10 ** decimals);
    }

    // ============================================
    // View Functions - Redemption Queue
    // ============================================

    function getRedemptionQueueLength() public view returns (uint256) {
        return redemptionQueue.length;
    }

    function getPendingRedemptionAmount() public view returns (uint256 totalShares, uint256 estimatedAssets) {
        // All items from queueRemoteRequestedIndex onwards are pending (not yet requested)
        for (uint256 i = queueRemoteRequestedIndex; i < redemptionQueue.length; i++) {
            RedemptionQueueItem storage item = redemptionQueue[i];
            totalShares += item.shares;
            estimatedAssets += item.requestedAssets;
        }
    }

    function getPendingFulfillmentAmount() public view returns (uint256 totalShares, uint256 estimatedAssets) {
        // Items between queueFulfilledIndex and queueRemoteRequestedIndex are requested but not fulfilled
        // Items from queueRemoteRequestedIndex onwards are not yet requested
        uint256 endIndex =
            queueRemoteRequestedIndex < redemptionQueue.length ? queueRemoteRequestedIndex : redemptionQueue.length;
        // All items between queueFulfilledIndex and endIndex are not fulfilled (sequential processing)
        for (uint256 i = queueFulfilledIndex; i < endIndex; i++) {
            RedemptionQueueItem storage item = redemptionQueue[i];
            totalShares += item.shares;
            estimatedAssets += item.requestedAssets;
        }
    }

    /**
     * @notice Preview next batch of redemptions to be processed from queue
     * @param maxAmountUsdt Maximum USDT amount to process
     * @return totalShares Total shares that would be requested
     * @return totalEstimatedAssets Total estimated USDT value
     * @return count Number of queue items that would be processed
     */
    function previewRedemptionQueue(uint256 maxAmountUsdt)
        public
        view
        returns (uint256 totalShares, uint256 totalEstimatedAssets, uint256 count)
    {
        // Process items sequentially from queueRemoteRequestedIndex onwards
        for (uint256 i = queueRemoteRequestedIndex; i < redemptionQueue.length; i++) {
            RedemptionQueueItem storage item = redemptionQueue[i];

            uint256 assetAmount = item.requestedAssets > 0 ? item.requestedAssets : convertToAssets(item.shares);

            if (totalEstimatedAssets + assetAmount > maxAmountUsdt) {
                break;
            }

            totalShares += item.shares;
            totalEstimatedAssets += assetAmount;
            ++count;
        }
    }

    /**
     * @notice Preview next batch of redemptions for fulfillment
     * @param maxAmountUsdt Maximum USDT amount to fulfill
     * @return totalShares Total shares that would be fulfilled
     * @return totalEstimatedAssets Total estimated USDT value
     * @return count Number of queue items that would be fulfilled
     */
    function previewFulfillRedemptions(uint256 maxAmountUsdt)
        public
        view
        returns (uint256 totalShares, uint256 totalEstimatedAssets, uint256 count)
    {
        uint256 vaultBalance = IERC20(asset).balanceOf(address(this));
        uint256 lockedAssets = totalFulfilledRedemptionAssets;
        uint256 availableAssets = vaultBalance > lockedAssets ? vaultBalance - lockedAssets : 0;
        uint256 maxToFulfill = maxAmountUsdt > availableAssets ? availableAssets : maxAmountUsdt;

        // Items between queueFulfilledIndex and queueRemoteRequestedIndex are requested but not fulfilled
        uint256 endIndex =
            queueRemoteRequestedIndex < redemptionQueue.length ? queueRemoteRequestedIndex : redemptionQueue.length;
        // Process items sequentially from queueFulfilledIndex onwards (no skipping)
        for (uint256 i = queueFulfilledIndex; i < endIndex; ++i) {
            RedemptionQueueItem storage item = redemptionQueue[i];

            uint256 assetAmount = item.requestedAssets;

            if (totalEstimatedAssets + assetAmount > maxToFulfill) {
                break;
            }

            totalShares += item.shares;
            totalEstimatedAssets += assetAmount;
            ++count;
        }
    }

    // ============================================
    // Peer Operations
    // ============================================

    function depositToRemote(uint256 amount) external whenNotPaused onlyOperators {
        uint256 available = availableIdleAssets();
        if (amount > available) revert InsufficientIdleAssets();

        agent.prepareAndSendAssets(asset, amount);
    }

    function withdrawFromRemote(uint256 usdtAmount) external whenNotPaused onlyOperators {
        if (address(agent) != address(0)) {
            agent.sendMessage(SuperEarnV2Protocol.WITHDRAW, abi.encode(usdtAmount));
            emit RemoteWithdrawalRequested(usdtAmount);
        }
    }

    // ============================================
    // Redemption Queue Processing
    // ============================================

    /// @dev Batches redemptions using amounts locked at request time and only requests the shortfall after using idle
    /// funds.
    /**
     * @notice Request remote assets for the next batch of queued redemptions
     * @dev Uses locked requestedAssets, consumes local idle balance first, and processes sequentially.
     * @param maxAmountUsdt Maximum total assets (including buffer) to consider in this batch
     * @param maxCount Maximum request counts to process
     */
    function processRedemptionQueue(
        uint256 maxAmountUsdt,
        uint256 maxCount
    )
        external
        whenNotPaused
        onlyOperators
        returns (uint256)
    {
        if (maxAmountUsdt == 0) revert ZeroMaxAmount();

        uint256 totalShares = 0;
        uint256 totalRequestedAssets = 0;
        uint256 requestCount = 0;
        uint256 startIndex = queueRemoteRequestedIndex;
        uint256 endIndex = redemptionQueue.length;
        endIndex = endIndex - startIndex < maxCount ? endIndex : startIndex + maxCount;

        uint256 initialAvailableIdle = availableIdleAssets();

        // Process items sequentially from queueRemoteRequestedIndex onwards (no skipping)
        for (uint256 i = startIndex; i < endIndex; i++) {
            RedemptionQueueItem storage item = redemptionQueue[i];

            uint256 assetAmount = item.requestedAssets;

            if (totalRequestedAssets + assetAmount > maxAmountUsdt) break;

            totalShares += item.shares;
            totalRequestedAssets += assetAmount;
            ++requestCount;
            totalReservedRedemptionAssets += assetAmount;
            queueRemoteRequestedIndex = i + 1;
        }

        if (totalShares == 0) revert NoRedemptionsToRequest();

        uint256 totalNeeded = totalRequestedAssets;
        uint256 amountToRequestFromRemote = totalNeeded > initialAvailableIdle ? totalNeeded - initialAvailableIdle : 0;

        if (amountToRequestFromRemote > 0) {
            if (address(agent) != address(0)) {
                agent.sendMessage(SuperEarnV2Protocol.WITHDRAW, abi.encode(amountToRequestFromRemote));
                emit RemoteWithdrawalRequested(amountToRequestFromRemote);
            }
        }

        emit RedemptionQueueProcessed(totalShares, totalNeeded, requestCount);
        emit RedemptionQueueRemoteRequested(startIndex, queueRemoteRequestedIndex);
        return amountToRequestFromRemote;
    }

    /**
     * @notice Fulfill requested redemptions and lock assets for claim.
     * @dev Fixed-rate fulfillment using reserved amounts when present; sequential and reverts on accounting gaps.
     */
    function batchFulfillRedemptions(uint256 maxAmountUsdt, uint256 maxCount) external whenNotPaused onlyOperators {
        if (maxAmountUsdt == 0) revert ZeroMaxAmount();

        uint256 totalShares = 0;
        uint256 totalAssetsUsed = 0;
        uint256 fulfilledCount = 0;
        uint256 startIndex = queueFulfilledIndex;
        uint256 endIndex =
            queueRemoteRequestedIndex < redemptionQueue.length ? queueRemoteRequestedIndex : redemptionQueue.length;
        endIndex = endIndex - startIndex < maxCount ? endIndex : startIndex + maxCount;

        uint256 availableAssets = fulfillmentEligibleAssets();
        uint256 maxToFulfill = maxAmountUsdt > availableAssets ? availableAssets : maxAmountUsdt;

        // Process items sequentially from queueFulfilledIndex up to queueRemoteRequestedIndex
        // Items before queueRemoteRequestedIndex have been requested, items after haven't
        // Each item must be processed atomically, with no partial fulfillment
        for (uint256 i = startIndex; i < endIndex; i++) {
            RedemptionQueueItem storage item = redemptionQueue[i];

            uint256 reservedAmount = item.requestedAssets;

            if (totalAssetsUsed + reservedAmount > maxToFulfill) break;

            item.fulfilledAssets = reservedAmount;
            totalShares += item.shares;
            totalAssetsUsed += reservedAmount;
            fulfilledCount++;

            if (reservedAmount > 0) {
                if (totalReservedRedemptionAssets < reservedAmount) {
                    revert ReservedRedemptionAccountingUnderflow(reservedAmount, totalReservedRedemptionAssets);
                }
                totalReservedRedemptionAssets -= reservedAmount;
                item.requestedAssets = 0;
            }

            RedemptionRequest storage request = redemptionRequests[item.controller];
            request.pendingShares -= item.shares;
            request.lockedShares += item.shares;
            request.lockedAssets += reservedAmount;
            totalFulfilledRedemptionShares += item.shares;
            totalFulfilledRedemptionAssets += reservedAmount;
            queueFulfilledIndex = i + 1;
        }

        if (totalShares == 0) revert NoRedemptionsFulfilled();
        emit BatchRedemptionsFulfilled(totalShares, totalAssetsUsed, fulfilledCount);
        emit RedemptionQueueFulfilled(startIndex, queueFulfilledIndex);
    }

    // ============================================
    // ERC-7540 Async Redemption
    // ============================================
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    )
        external
        override
        whenNotPaused
        returns (uint256 requestId)
    {
        if (controller == address(0)) revert InvalidController();
        if (owner != msg.sender && !isOperator[owner][msg.sender]) revert InvalidOwner();
        if (balanceOf(owner) < shares) revert InsufficientBalance();
        if (shares == 0) revert ZeroShares();

        // Lock the expected asset amount at request time to avoid NAV drift between request and processing.
        uint256 requestedAssets = convertToAssets(shares);

        if (requestedAssets == 0) revert ZeroAssets();

        _transfer(owner, address(this), shares);
        requestId = _nextRequestId++;

        RedemptionRequest storage request = redemptionRequests[controller];
        request.pendingShares += shares;

        uint256 queueIndex = redemptionQueue.length;
        requestIdToQueueIndex[requestId] = queueIndex;

        redemptionQueue.push(
            RedemptionQueueItem({
                requestId: requestId,
                controller: controller,
                shares: shares,
                requestedAssets: requestedAssets,
                fulfilledAssets: 0,
                timestamp: block.timestamp,
                redeemed: false
            })
        );

        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
        return requestId;
    }

    function pendingRedeemRequest(uint256 requestId, address controller) public view returns (uint256 pendingShares) {
        uint256 queueIndex = requestIdToQueueIndex[requestId];
        if (queueIndex >= redemptionQueue.length) return 0;

        RedemptionQueueItem storage item = redemptionQueue[queueIndex];
        // Verify the requestId matches and controller matches
        if (item.requestId != requestId || item.controller != controller) return 0;
        if (item.redeemed) return 0;

        // Return shares only if not yet fulfilled
        // queueIndex < queueFulfilledIndex means fulfilled
        return queueIndex < queueFulfilledIndex ? 0 : item.shares;
    }

    /**
     * @notice Get claimable redemption amount for a specific request
     * @param requestId The unique request identifier
     * @param controller The controller address (for compatibility, not used in lookup)
     * @return claimableShares Amount of shares ready to claim for this request
     */
    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    )
        public
        view
        override
        returns (uint256 claimableShares)
    {
        uint256 queueIndex = requestIdToQueueIndex[requestId];
        if (queueIndex >= redemptionQueue.length) return 0;

        RedemptionQueueItem storage item = redemptionQueue[queueIndex];
        // Verify the requestId matches and controller matches
        if (item.requestId != requestId || item.controller != controller) return 0;
        if (item.redeemed) return 0;

        // Return shares only if fulfilled
        // queueIndex < queueFulfilledIndex means fulfilled
        return queueIndex < queueFulfilledIndex ? item.shares : 0;
    }

    /**
     * @notice Get total locked asset amount across all controllers
     * @return Total assets locked for redemptions
     */
    function getTotalLockedAssets() external view returns (uint256) {
        return totalFulfilledRedemptionAssets;
    }

    /**
     * @notice Get redemption request details by requestId
     * @param requestId The unique request identifier
     * @return item The queue item containing request details
     */
    function getRedemptionRequest(uint256 requestId) external view returns (RedemptionQueueItem memory item) {
        uint256 queueIndex = requestIdToQueueIndex[requestId];
        require(queueIndex < redemptionQueue.length, "Invalid requestId");

        item = redemptionQueue[queueIndex];
        require(item.requestId == requestId, "RequestId mismatch");

        return item;
    }

    // === ERC4626 Overrides for Async Flows ===

    /**
     * @notice Deposit assets and mint shares.
     * @dev Synchronous deposit gated to whitelisted shareholders (or governance) to prevent fulfillment timing
     * arbitrage.
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive the shares
     * @return shares Amount of shares minted
     */
    function deposit(
        uint256 assets,
        address receiver
    )
        public
        override
        whenNotPaused
        nonReentrant
        onlyWhitelistedShareholder
        returns (uint256 shares)
    {
        return super.deposit(assets, receiver);
    }

    /**
     * @notice Mint shares by depositing assets.
     * @dev Same whitelist gate as deposit() to block fulfillment timing arbitrage.
     * @param shares Amount of shares to mint
     * @param receiver Address to receive the shares
     * @return assets Amount of assets deposited
     */
    function mint(
        uint256 shares,
        address receiver
    )
        public
        override
        whenNotPaused
        nonReentrant
        onlyWhitelistedShareholder
        returns (uint256 assets)
    {
        return super.mint(shares, receiver);
    }

    /**
     * @notice Get maximum withdrawable assets for a controller
     * @param controller Address to check
     * @return Maximum assets that can be withdrawn (locked from fulfilled redemptions)
     */
    function maxWithdraw(address controller) public view returns (uint256) {
        // Fulfillment already locked the exchange rate; report the exact asset amount owed
        return redemptionRequests[controller].lockedAssets;
    }

    /**
     * @notice Get maximum redeemable shares for a controller
     * @param controller Address to check
     * @return Maximum shares that can be redeemed (locked from fulfilled redemptions)
     */
    function maxRedeem(address controller) public view returns (uint256) {
        return redemptionRequests[controller].lockedShares;
    }

    /**
     * @notice Redeem shares by claiming fulfilled redemption
     * @dev Returns exactly the fulfilledAssets for the given requestId to ensure
     *      claimedAmount == predepositDebt and prevent remainingPredepositDebt issues.
     * @param requestId The specific redemption request ID to redeem
     * @param receiver Address to receive the assets
     * @param controller Controller of the redemption request (must match item.controller)
     * @return assets Amount of assets received (exactly fulfilledAssets)
     */
    function redeem(
        uint256 requestId,
        address receiver,
        address controller
    )
        public
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (controller != msg.sender && !isOperator[controller][msg.sender]) revert InvalidCaller();

        uint256 queueIndex = requestIdToQueueIndex[requestId];
        RedemptionQueueItem storage item = redemptionQueue[queueIndex];

        // Verify this is a valid request
        if (item.requestId != requestId) revert InvalidRequestId();
        if (item.controller != controller) revert InvalidCaller();
        if (item.fulfilledAssets == 0) revert ZeroAssets();
        if (item.redeemed) revert AlreadyRedeemed();

        // Get the exact fulfilled assets for this request
        assets = item.fulfilledAssets;
        uint256 shares = item.shares;

        // Update queue item state
        item.redeemed = true;

        // Update controller's aggregate tracking
        RedemptionRequest storage request = redemptionRequests[controller];
        request.lockedShares -= shares;
        request.lockedAssets -= assets;

        // Update global tracking
        totalFulfilledRedemptionShares -= shares;
        totalFulfilledRedemptionAssets -= assets;

        // Burn the shares and transfer assets
        _burn(address(this), shares);
        IERC20(asset).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, controller, assets, shares);
        return assets;
    }

    // === Access Control ===

    /**
     * @notice Get management address (for Yearn compatibility)
     * @return Management address (defaults to owner)
     */
    function management() public view returns (address) {
        return owner();
    }

    /**
     * @notice Modifier to restrict deposits to whitelisted shareholders only
     * @dev Prevents fulfillment timing arbitrage; governance bypasses for emergencies.
     */
    modifier onlyWhitelistedShareholder() {
        if (!hasRole(GOVERNANCE_ROLE, msg.sender) && !whitelistedShareholders[msg.sender]) {
            revert NotWhitelistedShareholder();
        }
        _;
    }

    // === Emergency Functions ===

    /**
     * @notice Emergency function to recover stuck tokens
     * @param token Address of the token to recover
     * @param to Address to send the tokens to
     * @param amount Amount of tokens to recover
     */
    function emergencyRecoverToken(address token, address to, uint256 amount) external onlyGovernance {
        if (token == asset) revert CannotRecoverVaultAsset();
        if (token == address(this)) revert CannotRecoverVaultShares();
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     *
     * Storage usage: 13 slots (OriginVault itself)
     *   - whitelistedShareholders (mapping pointer): 1 slot
     *   - agent: 1 slot
     *   - feedProxy: 1 slot
     *   - priceConverter: 1 slot
     *   - totalReservedRedemptionAssets: 1 slot
     *   - totalFulfilledRedemptionShares: 1 slot
     *   - totalFulfilledRedemptionAssets: 1 slot
     *   - _nextRequestId: 1 slot
     *   - redemptionRequests (mapping pointer): 1 slot
     *   - requestIdToQueueIndex (mapping pointer): 1 slot
     *   - redemptionQueue (dynamic array pointer): 1 slot
     *   - queueRemoteRequestedIndex: 1 slot
     *   - queueFulfilledIndex: 1 slot
     *
     * Parents:
     *   - OriginVaultBase includes its own storage gap to cover asset/share/decimalsOffset
     *   - PausableUpgradeable: _paused (1 slot)
     *   - ReentrancyGuardUpgradeable: _status (1 slot)
     *
     * OriginVault additional state = 13 slots
     * Gap = 50 - 13 = 37
     */
    uint256[37] private __gap;
}
