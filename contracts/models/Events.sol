// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;
import "./Schema.sol";

abstract contract Events is Schema {
    // PoolRegistry.sol
    event PoolRegistryContractDeployed();
    event PoolCreated(uint256 indexed poolId, address indexed creator);
    event LoanCreated(
        uint256 indexed loanId,
        uint256 indexed poolId,
        address indexed borrower,
        uint256 principal
    );
    event LoanRepaid(
        uint256 indexed loanRepaymentId,
        uint256 indexed loanId,
        uint256 amount,
        LoanRepaymentType
    );
    event PoolFunded(uint256 indexed poolId, uint256 amount);
    event PoolClosed(uint256 indexed poolId, uint256 amountWithdrawn);

    // Qredos.sol

    event QredosContractDeployed(
        address lendingPoolAddress
    );
    event LendingPoolAddressUpdated(address oldValue, address newValue);
    event PurchaseCreated(
        address indexed userAddress,
        uint256 indexed purchaseId,
        uint256 downPayment,
        uint16 downPaymentPercentage
    );
    event PurchaseCompleted(uint256 indexed purchaseId);
    event NFTClaimed(uint256 indexed purchaseId, address claimer);
    event StartLiquidation(
        uint256 indexed purchaseId,
        uint256 discountAmount,
        uint256 indexed liquidationId
    );
    event CompleteLiquidation(
        uint256 indexed purchaseId,
        uint256 indexed liquidationId,
        address newOwner
    );

    event RefundBorrower(
        uint256 indexed purchaseId,
        address borrowerAddress,
        uint256 refundAmount
    );
}
