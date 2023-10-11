// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title SoulBound NFT
/// @dev SoulBound token is a non-trasferrable token
abstract contract SoulBoundERC721 is ERC721 {
  /// @notice Error is thrown when trying to transfer a soulbound nft
  error SoulBound();

  /// --- Disabling Transfer Of Soulbound NFT --- ///

  /// @notice Function disabled as cannot transfer a soulbound nft
  function safeTransferFrom(
    address,
    address,
    uint256,
    bytes memory
  ) public pure override {
    revert SoulBound();
  }

  /// @notice Function disabled as cannot transfer a soulbound nft
  function transferFrom(
    address,
    address,
    uint256
  ) public pure override {
    revert SoulBound();
  }

  /// @notice Function disabled as cannot transfer a soulbound nft
  function approve(
    address,
    uint256
  ) public pure override {
    revert SoulBound();
  }

  /// @notice Function disabled as cannot transfer a soulbound nft
  function setApprovalForAll(
    address,
    bool
  ) public pure override {
    revert SoulBound();
  }

  /// @notice Function disabled as cannot transfer a soulbound nft
  function getApproved(
    uint256
  ) public pure override returns (address) {
    revert SoulBound();
  }

  /// @notice Function disabled as cannot transfer a soulbound nft
  function isApprovedForAll(
    address,
    address
  ) public pure override returns (bool) {
    revert SoulBound();
  }

}
