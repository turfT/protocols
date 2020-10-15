// SPDX-License-Identifier: Apache-2.0
// Copyright 2017 Loopring Technology Limited.
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "../../lib/ERC20.sol";
import "../../lib/MathUint.sol";
import "./AmmData.sol";
import "./AmmPoolToken.sol";
import "./AmmStatus.sol";
import "./AmmUtil.sol";


/// @title AmmWithdrawal
library AmmWithdrawal
{
    using AmmPoolToken      for AmmData.State;
    using AmmStatus         for AmmData.State;
    using MathUint          for uint;

    function withdrawFromApprovedWithdrawals(
        AmmData.State storage S
        )
        internal
    {
        uint size = S.tokens.length;
        address[] memory owners = new address[](size);
        address[] memory tokens = new address[](size);

        for (uint i = 0; i < size; i++) {
            owners[i] = address(this);
            tokens[i] = S.tokens[i].addr;
        }
        S.exchange.withdrawFromApprovedWithdrawals(owners, tokens);
    }

    // This is to claim other people depositing into this AMM pool.
    function withdrawFromDepositRequests(
        AmmData.State storage  S,
        address[]     calldata tokens
        )
        internal
    {
        require(tokens.length > 0, "INVALID_TOKENS");

        address recipient = S.exchange.owner();

        for (uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            S.exchange.withdrawFromDepositRequest(address(this), token);
            if (token != address(this)) {
                uint balance = token == address(0) ?
                    address(this).balance :
                    ERC20(token).balanceOf(address(this));

                AmmUtil.transferOut(token, balance, recipient);
            }
        }
    }

    function withdrawWhenOffline(
        AmmData.State storage S
        )
        internal
    {
        _checkWithdrawalConditionInShutdown(S);

        // Burn the full balance
        uint poolAmount = S.balanceOf[msg.sender];
        if (poolAmount > 0) {
            S.transfer(address(this), poolAmount);
        }

        // Burn any additional pool tokens stuck in forced exits
        AmmData.PoolExit storage exit = S.forcedExit[msg.sender];
        if (exit.burnAmount > 0) {
            poolAmount = poolAmount.add(exit.burnAmount);
            delete S.forcedExit[msg.sender];
        }

        require(poolAmount > 0, "ZERO_POOL_AMOUNT");

        // Withdraw the part owned of the pool
        uint totalSupply = S.totalSupply();
        for (uint i = 0; i < S.tokens.length; i++) {
            address token = S.tokens[i].addr;
            uint balance = token == address(0) ?
                address(this).balance :
                ERC20(token).balanceOf(address(this));

            uint amount = balance.mul(poolAmount) / totalSupply;
            AmmUtil.transferOut(token, amount, msg.sender);
        }

        S._totalSupply = S._totalSupply.sub(poolAmount);
    }

    function canDrain(
        AmmData.State storage S,
        address               drainer,
        address               token
        )
        internal
        view
        returns (bool)
    {
        // Never allow draining the pool token, these can be stored in this contract for forced exits at all times
        if (token == address(this) || drainer != S.exchange.owner()) {
            return false;
        }

        // When online, owner can claim all tokens, as we do not allow layer-1 joins.
        if (S.isOnline()) {
            return true;
        }

        // When offline those tokens can be stored in this contract for use in withdrawWhenOffline
        for (uint i = 0; i < S.tokens.length; i++) {
            if (token == S.tokens[i].addr) {
                return false;
            }
        }

        return true;
    }

    function _checkWithdrawalConditionInShutdown(
        AmmData.State storage S
        )
        private
        view
    {
        IExchangeV3 exchange = S.exchange;
        bool withdrawalMode = exchange.isInWithdrawalMode();

        for (uint i = 0; i < S.tokens.length; i++) {
            address token = S.tokens[i].addr;

            require(
                withdrawalMode && exchange.isWithdrawnInWithdrawalMode(S.accountID, token) ||
                !withdrawalMode && !exchange.isForcedWithdrawalPending(S.accountID, token),
                "PENDING_WITHDRAWAL"
            );

            // Check that nothing is withdrawable anymore.
            require(
                exchange.getAmountWithdrawable(address(this), token) == 0,
                "MORE_TO_WITHDRAW"
            );
        }
    }
}