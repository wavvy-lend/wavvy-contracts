// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../models/Schema.sol";

contract PoolRegistryStore is Schema {
    using SafeERC20 for IERC20;

    IERC20 internal lendingToken;

    mapping(uint256 => PoolDetails) public Pools;
    uint256 public totalPools = 0;

    /// @notice (poolId => mapping(loanId => [])
    mapping(uint256 => mapping(uint256 => LoanDetails)) public Loans;
    uint256 public totalLoans = 0;
    /// @notice (pool => noOfLoans)
    mapping(uint256 => uint256) public countLoansInPool;
    
    /// @notice (loanId => mapping(loanRepaymentiD => [])
    mapping(uint256 => mapping(uint256 => LoanRepaymentDetails))
        public LoanRepayment;
    uint256 public totalLoanRepayments = 0;
    /// @notice (loanId => noOfLoanRepayments)
    mapping(uint256 => uint256) public countLoanRepaymentsForLoan;

    function getLoanByPoolID(uint256 poolId, uint256 loanId)
        external
        view
        returns (LoanDetails memory)
    {
        require(Loans[poolId][loanId].isExists, "No such record");
        return Loans[poolId][loanId];
    }

    function getPoolByID(uint256 poolId)
        external
        view
        returns (PoolDetails memory)
    {
        require(Pools[poolId].isExists, "No such record");
        return Pools[poolId];
    }

    // POOL
    function _createPool(
        uint256 _amount,
        uint16 _paymentCycle,
        uint16 _APR,
        uint256 _durationInSecs,
        uint16 _durationInMonths,
        address _creator
    ) internal returns (uint256) {
        uint256 poolId = totalPools;
        Pools[poolId++] = PoolDetails(
            _amount,
            _paymentCycle,
            _APR,
            _durationInSecs,
            _durationInMonths,
            _creator,
            PoolStatus.OPEN,
            true
        );
        ++totalPools;
        return poolId++;
    }

    function _updatePool(
        uint256 poolId,
        uint256 _amount,
        uint16 _paymentCycle,
        uint16 _APR,
        uint256 _durationInSecs,
        uint16 _durationInMonths,
        address _creator,
        PoolStatus status
    ) internal {
        Pools[poolId] = PoolDetails(
            _amount,
            _paymentCycle,
            _APR,
            _durationInSecs,
            _durationInMonths,
            _creator,
            status,
            true
        );
    }

    function _isOpenLoansInPool(uint256 poolId) internal view returns (bool) {
        for (uint256 i = 0; i < countLoansInPool[poolId]; i++) {
            if (
                Loans[poolId][i].poolId == poolId &&
                Loans[poolId][i].status == LoanStatus.OPEN
            ) {
                return true;
            }
        }
        return false;
    }

    // LOAN
    function _createLoan(
        uint256 poolId,
        address borrowerAddress,
        uint256 principal
    ) internal returns (uint256) {
        uint256 loanId = totalLoans;
        Loans[poolId][loanId++] = LoanDetails(
            poolId,
            borrowerAddress,
            principal,
            LoanStatus.OPEN,
            true
        );
        ++totalLoans;
        countLoansInPool[poolId] = countLoansInPool[poolId]++;
        return loanId++;
    }

    function _createLoanRepayment(uint256 loanId, uint256 amount)
        internal
        returns (uint256)
    {
        uint256 loanRepayment = totalLoanRepayments;
        LoanRepayment[loanId][loanRepayment++] = LoanRepaymentDetails(
            loanId,
            amount,
            true
        );
        ++totalLoanRepayments;
        countLoanRepaymentsForLoan[loanId] = countLoanRepaymentsForLoan[
            loanId
        ]++;
        return loanRepayment++;
    }

    function _hasPendingLoanRepayment(uint256 poolId)
        internal
        view
        returns (bool)
    {
        require(Pools[poolId].isExists, "Pool: Invalid pool Id!");
        // loan [i] - loanId
        for (uint256 i = 0; i < countLoansInPool[poolId]; i++) {
            uint256 totalAmountRepaid;
            // loan repayments [j] - loanRepaymentID
            for (uint256 j = 0; j < countLoanRepaymentsForLoan[i]; j++) {
                totalAmountRepaid += LoanRepayment[i][j].amount;
                if (totalAmountRepaid < Loans[poolId][i].principal) {
                    return true;
                }
            }
        }
        return false;
    }
}
