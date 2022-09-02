// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;
import "./models/Schema.sol";
import "./models/Events.sol";

import "./interfaces/IPoolRegistry.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./PoolRegistry.sol";
import "./Escrow.sol";
import "./store/PoolRegistryStore.sol";

abstract contract Qredos is Ownable, Schema, PoolRegistry {
    using SafeERC20 for IERC20;

    address public paymentTokenAddress;
    address public lendingPoolAddress;
    address public poolRegistryStoreAddress;

    uint32 public duration = 7776000; // APPROX. 90 days (3 months)
    uint16 public APR = 30; //  10% * 3 months
    uint16 public constant downPaymentPercentage = 50; // borrowers will pay 50%

    // (borrowerAddress => PurchaseId[] => Details)
    mapping(address => mapping(uint256 => PurchaseDetails)) public Purchase;
    uint256 public totalPurchases = 0;
    // (borrower => purchaseId)
    mapping(address => uint256) countPurchaseForBorrower;
    // (id => Details)
    mapping(uint256 => LiquidationDetails) public Liquidation;
    uint256 public countLiquidation = 0;

    bool public isPaused;

    modifier whenNotPaused() {
        require(!isPaused, "Qredos: currently paused!");
        _;
    }

    constructor(
        address _paymentTokenAddress,
        address _lendingPoolAddress,
        address _PoolRegistryStoreAddress
    ) {
        paymentTokenAddress = _paymentTokenAddress;
        lendingPoolAddress = _lendingPoolAddress;
        poolRegistryStoreAddress = _PoolRegistryStoreAddress;
        emit QredosContractDeployed(
            _paymentTokenAddress,
            _lendingPoolAddress,
            _PoolRegistryStoreAddress
        );
    }

    /*
        make sure escrow is owned by oracle before transferring nft to it. 
    */
    function purchaseNFT(
        address tokenAddress,
        uint256 tokenId,
        uint256 downPaymentAmount,
        uint256 principal,
        uint256 poolId
    ) external whenNotPaused {
        require(
            tokenAddress != address(0x0),
            "Qredos: address is zero address!"
        );
        PoolRegistryStore _poolRegistryStore = PoolRegistryStore(
            poolRegistryStoreAddress
        );
        PoolDetails memory Pool = _poolRegistryStore.getPoolByID(poolId);
        require(Pool.isExists, "Qredos: Invalid pool!");
        require(
            _calcDownPayment(downPaymentAmount, principal),
            "Qredos: Invalid principal!"
        );
        require(
            PoolRegistry(lendingPoolAddress)._getPoolBalance(poolId) >
                principal,
            "Qredos: Pool can't fund purchase!"
        );
        uint256 loanId = IPoolRegistry(lendingPoolAddress).requestLoan(
            principal,
            poolId,
            msg.sender
        );
        require(
            IERC20(paymentTokenAddress).balanceOf(address(this)) >
                (principal + downPaymentAmount),
            "Qredos: Qredos can't fund purchase!"
        );
        IERC20(paymentTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            downPaymentAmount
        );

        require(
            IERC20(paymentTokenAddress).balanceOf(address(this)) <
                (downPaymentAmount + principal),
            "Qredos: Insufficient funds!"
        );
        uint256 purchaseId = _createPurchase(
            msg.sender,
            loanId,
            poolId,
            address(0x0),
            tokenAddress,
            tokenId
        );

        emit PurchaseCreated(
            msg.sender,
            poolId,
            loanId,
            purchaseId,
            tokenId,
            tokenAddress,
            downPaymentAmount,
            principal,
            APR,
            duration,
            downPaymentPercentage
        );
    }

    function completeNFTPurchase(uint256 purchaseId, address borrowerAddress)
        external
        whenNotPaused
    {
        require(
            Purchase[borrowerAddress][purchaseId].isExists,
            "Qredos: Invalid purchase ID!"
        );
        PurchaseDetails memory purchase = Purchase[borrowerAddress][purchaseId];
        require(
            ERC721(purchase.tokenAddress).ownerOf(purchase.tokenId) ==
                address(this),
            "Qredos: Purchase Incomplete!"
        );

        // update to proxy pattern to make deployment cheaper
        address escrowAddress = address(
            new Escrow(borrowerAddress, purchase.tokenId, purchase.tokenAddress)
        );
        require(
            Escrow(escrowAddress).owner() == address(this),
            "Qredos: Invalid escrow owner!"
        );
        ERC721(purchase.tokenAddress).approve(escrowAddress, purchase.tokenId);
        Escrow(escrowAddress).deposit(purchase.tokenId, purchase.tokenAddress);

        _updatePurchase(
            borrowerAddress,
            purchaseId,
            purchase.loanId,
            purchase.poolId,
            purchase.escrowAddress,
            purchase.tokenAddress,
            purchase.tokenId,
            PurchaseStatus.COMPLETED
        );
        emit PurchaseCompleted(purchaseId);
    }

    function repayLoan(
        uint256 purchaseId,
        LoanRepaymentType repaymentType,
        uint256 poolId
    ) external whenNotPaused returns (bool) {
        require(
            Purchase[msg.sender][purchaseId].isExists,
            "Qredos: Invalid purchase ID!"
        );
        PurchaseDetails memory purchase = Purchase[msg.sender][purchaseId];
        LoanDetails memory loan = PoolRegistryStore(poolRegistryStoreAddress)
            .getLoanByPoolID(poolId, purchase.loanId);
        if (repaymentType == LoanRepaymentType.FULL) {
            lendingToken.safeTransferFrom(
                msg.sender,
                address(this),
                loan.principal
            );
            IPoolRegistry(lendingPoolAddress).repayLoanFull(
                purchase.loanId,
                loan.principal,
                poolId
            );
        } else if (repaymentType == LoanRepaymentType.PART) {
            uint256 partPayment = _calcLoanPartPayment(purchase.loanId, poolId);
            lendingToken.safeTransferFrom(
                msg.sender,
                address(this),
                partPayment
            );
            IPoolRegistry(lendingPoolAddress).repayLoanPart(
                purchase.loanId,
                partPayment,
                poolId
            );
        }
        return true;
    }

    function claimNft(uint256 purchaseId, uint256 poolId)
        external
        whenNotPaused
    {
        require(
            Purchase[msg.sender][purchaseId].isExists,
            "Qredos: Invalid purchase ID!"
        );
        PurchaseDetails memory purchase = Purchase[msg.sender][purchaseId];
        LoanDetails memory loan = PoolRegistryStore(poolRegistryStoreAddress)
            .getLoanByPoolID(poolId, purchase.loanId);
        require(
            loan.status == LoanStatus.CLOSED,
            "Qredos: loanRepayment incomplete!"
        );
        require(
            Escrow(purchase.escrowAddress).claim(msg.sender),
            "Qredos: claim reverted!"
        );
        emit NFTClaimed(purchaseId, msg.sender);
    }

    function startLiquidation(uint256 purchaseId, uint256 discountAmount)
        external
        onlyOwner
    {
        require(
            Purchase[msg.sender][purchaseId].isExists,
            "Qredos: Invalid purchase ID!"
        );
        PurchaseDetails memory purchase = Purchase[msg.sender][purchaseId];
        require(
            PoolRegistry(lendingPoolAddress)._isLoanInDefault(
                purchase.loanId,
                purchase.poolId
            ) != false,
            "Qredos.startLiquidation: loan is not defaulted!"
        );
        uint256 liquidationId = _createLiquidation(purchaseId, discountAmount);
        emit StartLiquidation(purchaseId, discountAmount, liquidationId);
    }

    function completeLiquidation(uint256 liquidationId) external {
        require(
            Liquidation[liquidationId].isExists,
            "Qredos: Invalid liquidation ID!"
        );
        LiquidationDetails memory liquidation = Liquidation[liquidationId];
        PurchaseDetails memory purchase = Purchase[msg.sender][
            liquidation.purchaseId
        ];
        lendingToken.safeTransferFrom(
            msg.sender,
            address(this),
            liquidation.discountAmount
        );
        require(
            Escrow(purchase.escrowAddress).claim(msg.sender),
            "Qredos: liquidation reverted!"
        );
        _updateLiquidation(
            liquidation.purchaseId,
            liquidation.discountAmount,
            liquidationId,
            LiquidationStatus.COMPLETED
        );
        emit CompleteLiquidation(
            liquidation.purchaseId,
            liquidationId,
            msg.sender
        );
    }

    function createPool(
        uint256 _amount,
        uint16 _paymentCycle,
        uint16 _APR,
        uint256 _durationInSecs,
        uint16 _durationInMonths,
        address _creator
    ) external override {
        PoolRegistry(lendingPoolAddress).createPool(
            _amount,
            _paymentCycle,
            _APR,
            _durationInSecs,
            _durationInMonths,
            _creator
        );
    }

    function fundPool(uint256 poolId, uint256 amount) external override {
        PoolRegistry(lendingPoolAddress).fundPool(poolId, amount);
    }

    function closePool(uint256 poolId, address reciever) external override {
        PoolRegistry(lendingPoolAddress).closePool(poolId, reciever);
    }

    /////////////////////////
    ///   Admin Actions   ///
    /////////////////////////

    /**
     * @notice Toggling the pause flag
     * @dev Only owner
     */
    function toggleIsPaused() external onlyOwner {
        isPaused = !isPaused;
    }

    /// @dev set duration of loan requests.
    /// @param _duration - duration in seconds
    function setDuration(uint32 _duration) external onlyOwner {
        require(_duration != 0, "Qredos: duration can't be zero");
        uint32 old = duration;
        duration = _duration;
        emit DurationUpdated(old, _duration);
    }

    function setAPR(uint16 _APR) external onlyOwner {
        require(_APR != 0, "Qredos: APY can't be zero");
        uint16 old = APR;
        APR = _APR;
        emit APRUpdated(old, _APR);
    }

    function forwardAllFunds() external onlyOwner {
        IERC20(paymentTokenAddress).transfer(
            owner(),
            IERC20(paymentTokenAddress).balanceOf(address(this))
        );
    }

    /////////////////////////
    ///   Internal   ////////
    /////////////////////////

    function _createPurchase(
        address borrowerAddress,
        uint256 loanId,
        uint256 poolId,
        address escrowAddress,
        address tokenAddress,
        uint256 tokenId
    ) internal returns (uint256) {
        uint256 purchases = totalPurchases;
        Purchase[borrowerAddress][purchases++] = PurchaseDetails(
            loanId,
            poolId,
            escrowAddress,
            tokenAddress,
            tokenId,
            PurchaseStatus.OPEN,
            true
        );
        ++totalPurchases;
        countPurchaseForBorrower[borrowerAddress] = countPurchaseForBorrower[
            borrowerAddress
        ]++;
        return purchases++;
    }

    function _updatePurchase(
        address borrowerAddress,
        uint256 purchaseId,
        uint256 loanId,
        uint256 poolId,
        address escrowAddress,
        address tokenAddress,
        uint256 tokenId,
        PurchaseStatus status
    ) internal {
        Purchase[borrowerAddress][purchaseId] = PurchaseDetails(
            loanId,
            poolId,
            escrowAddress,
            tokenAddress,
            tokenId,
            status,
            true
        );
    }

    function _createLiquidation(uint256 purchaseId, uint256 discountAmount)
        internal
        returns (uint256)
    {
        uint256 liquidations = countLiquidation;
        Liquidation[liquidations++] = LiquidationDetails(
            purchaseId,
            discountAmount,
            LiquidationStatus.OPEN,
            true
        );
        ++countLiquidation;
        return liquidations++;
    }

    function _updateLiquidation(
        uint256 purchaseId,
        uint256 discountAmount,
        uint256 liquidationId,
        LiquidationStatus status
    ) internal {
        Liquidation[liquidationId] = LiquidationDetails(
            purchaseId,
            discountAmount,
            status,
            true
        );
    }

    function _calcDownPayment(uint256 downPayment, uint256 principal)
        internal
        pure
        returns (bool)
    {
        uint16 rate = 100 / downPaymentPercentage;
        if (downPayment * rate == downPayment + principal) {
            return true;
        } else {
            return false;
        }
    }
}
