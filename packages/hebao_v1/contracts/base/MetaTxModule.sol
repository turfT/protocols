/*

  Copyright 2017 Loopring Project Ltd (Loopring Foundation).

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/
pragma solidity ^0.5.11;

import "../lib/AddressUtil.sol";
import "../lib/MathUint.sol";
import "../lib/SignatureUtil.sol";

import "../thirdparty/BytesUtil.sol";
import "../thirdparty/ERC1271.sol";

import "../iface/Wallet.sol";

import "./BaseModule.sol";


/// @title MetaTxModule
/// @dev This is the base module for supporting meta-transactions.
///      A MetaTxModule will only relay transactions on itself, and the methods
///      relayed must as the target wallet address as its first argument, unless
///      the `extractWalletAddress` is overridden.
///
/// @author Daniel Wang - <daniel@loopring.org>
///
/// The design of this contract is inspired by Argent's contract codebase:
/// https://github.com/argentlabs/argent-contracts

contract MetaTxModule is BaseModule
{
    using MathUint      for uint;
    using AddressUtil   for address;
    using SignatureUtil for bytes32;
    using BytesUtil     for bytes;

    uint   constant public   BLOCK_BOUND = 100;
    uint   constant public   GAS_OVERHEAD = 30000;

    struct WalletState
    {
        uint nonce;
        mapping (bytes32 => bool) metaTxHash;
    }

    mapping (address => WalletState) public wallets;

    event ExecutedMetaTx(
        address indexed transactor,
        address indexed wallet,
        uint    nonce,
        bytes32 metaTxHash,
        bool    success
    );

    modifier onlyFromMetaTx
    {
        require(msg.sender == address(this), "NOT_FROM_THIS_MODULE");
        _;
    }

    /// @dev Execute a signed meta transaction.
    ///      This method can be called by any relayer without restriction. The relayer
    ///      will pay for transaction gas in Ether and charge the wallet Ether or other
    ///      ERC20 tokens as fee. If gasPrice is set to 0, then the relayer won't charge
    ///      the wallet any fee.
    ///
    ///      Important! This function needs to be safe against re-entrancy by using
    ///      the 'Checks Effects Interactions' pattern! We do not use `nonReentrant`
    ///      because this function is used to call into the same contract.
    /// @param data The raw transaction to be performed on arbitrary contract.
    /// @param nonce The nonce of this meta transaction. When nonce is 0, this module will
    ///              make sure the transaction's metaTxHash is unique; otherwise, the module
    ///              requires the nonce is greater than the last nonce used by the same
    ///              wallet, but not by more than `BLOCK_BOUND * 2^128`.
    /// @param gasToken The token to pay the relayer as fees. Use address(0) for Ether.
    /// @param gasPrice The amount of `gasToken` to pay per gas. 0 is a valid value.
    /// @param gasLimit The max amount of gas that can be used by this meta transaction,
    ///                excluding an extra `GAS_OVERHEAD` for paying the relayer fees.
    /// @param signatures Signatures.
    function executeMetaTx(
        bytes   calldata data,
        uint    nonce,
        address gasToken,
        uint    gasPrice,
        uint    gasLimit,
        bytes   calldata signatures
        )
        external
        payable
    {
        uint startGas = gasleft();
        require(startGas >= gasLimit, "OUT_OF_GAS");

        address wallet = extractWalletAddress(data);
        bytes32 metaTxHash = getSignHash(
            wallet, // from
            address(this),  // to. Note the relayer can only call its own methods.
            0, // value
            data,
            nonce,
            gasPrice,
            gasLimit,
            gasToken
        );

        bytes4 method = extractMethod(data);
        address[] memory signers = extractMetaTxSigners(wallet, method, data);
        metaTxHash.verifySignatures(signers, signatures);

        // Mark the transaction as used before doing the call to guard against re-entrancy
        // (the only exploit possible here is that the transaction can be executed multiple times).
        saveExecutedMetaTx(wallet, nonce, metaTxHash);

        // solium-disable-next-line security/no-call-value
        (bool success,) = address(this).call.value(msg.value)(data);

        reimburseGasFee(wallet, gasToken, gasPrice, gasLimit, startGas - gasleft());

        emit ExecutedMetaTx(msg.sender, wallet, nonce, metaTxHash, success);
    }

    function reimburseGasFee(
        address wallet,
        address gasToken,
        uint    gasPrice,
        uint    gasLimit,
        uint    gasSpent
        )
        private
    {
        if (gasPrice == 0) return;

        uint gasAmount = gasSpent + GAS_OVERHEAD;
        require(gasAmount <= gasLimit, "EXCEED_GAS_LIMIT");
        require(GAS_OVERHEAD <= gasleft(), "OUT_OF_GAS");

        gasAmount = gasAmount.mul(gasPrice);
        if (gasToken == address(0)) {
            Wallet(wallet).transact(msg.sender, gasSpent, "");
        } else {
            bytes memory data = abi.encodeWithSelector(ERC20_TRANSFER, msg.sender, gasSpent);
            Wallet(wallet).transact(gasToken, 0, data);
        }
    }

    /// @dev Extracts and returns a list of signers for the given meta transaction.
    ///      Additional validation of the signers can also be done inside this function.
    /// @param wallet The wallet address.
    /// @param method The method selector.
    /// @param data The call data.
    /// @return signers A list of signers that should have signed this meta transaction.
    ///                  The list can be empty.
    function extractMetaTxSigners(
        address wallet,
        bytes4  method,
        bytes   memory data
        )
        internal
        view
        returns (address[] memory signers);

    /// @dev Returns the last nonce used by a wallet.
    /// @param wallet The wallet's address.
    /// @return Last nonce used.
    function lastNonce(address wallet)
        public
        view
        returns (uint)
    {
        return wallets[wallet].nonce;
    }

    /// @dev For all relayed method, the first parameter must be the wallet address.
    function extractWalletAddress(bytes memory data)
        internal
        pure
        returns (address wallet)
    {
        require(data.length >= 36, "INVALID_DATA");
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            // data layout: {length:32}{sig:4}{_wallet:32}{...}
            wallet := mload(add(data, 36))
        }
    }

    /// @dev calculate the hash that all signatures will sign against.
    ///      See https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1077.md
    function getSignHash(
        address from,
        address to,
        uint256 value,
        bytes   memory data,
        uint256 nonce,
        uint256 gasPrice,
        uint256 gasLimit,
        address gasToken
        )
        public
        pure
        returns (bytes32)
    {
        bytes32 hash = keccak256(
            abi.encodePacked(
                byte(0x19),
                byte(0),
                from,
                to,
                value,
                keccak256(data),
                nonce,
                gasPrice,
                gasLimit,
                gasToken
            )
        );

        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function extractMethod(bytes memory data)
        internal
        pure
        returns (bytes4 method)
    {
        require(data.length >= 4, "INVALID_DATA");
        assembly {
            // data layout: {length:32}{sig:4}{...}
            method := mload(add(data, 32))
        }
    }

    /// @dev Save the meta-transaction to history.
    ///      This method must throw if the transaction is not unique or the nonce is invalid.
    /// @param wallet The target wallet.
    /// @param nonce The nonce
    /// @param metaTxHash The signed hash of the transaction
    function saveExecutedMetaTx(
        address wallet,
        uint    nonce,
        bytes32 metaTxHash
        )
        private
    {
        if (nonce == 0) {
            require(!wallets[wallet].metaTxHash[metaTxHash], "DUPLICIATE_SIGN_HASH");
            wallets[wallet].metaTxHash[metaTxHash] = true;
        } else {
            require(nonce > wallets[wallet].nonce, "NONCE_TOO_SMALL");
            require((nonce >> 128) <= (block.number + BLOCK_BOUND), "NONCE_TOO_LARGE");
            wallets[wallet].nonce = nonce;
        }
    }
}